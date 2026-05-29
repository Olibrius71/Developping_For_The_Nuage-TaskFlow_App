# REPORT PARTIE 4B — Helm : Stack d'observabilite

## Contexte et demarche

L'objectif est de deployer toute la stack d'observabilite (Prometheus, Grafana, Alertmanager) via le chart officiel **kube-prometheus-stack**, de la personnaliser sans toucher a son code (dashboards, ServiceMonitors, alertes), puis de mettre en place l'alerting par email, l'autoscaling (HPA) et de tester la haute disponibilite.

### Etat realise (preuves)

Toute la stack a ete deployee sur le cluster kind et validee :

- `monitoring` (Helm) : `deployed`, tous les pods Running (Prometheus 2/2, Grafana 3/3, Alertmanager 2/2, operator, kube-state-metrics, 3 node-exporters)
- `taskflow` (Helm) : `deployed`, 10 pods `1/1 Running`
- Les **4 services TaskFlow scrappes** par Prometheus (`up`) via ServiceMonitors
- Les **2 dashboards customs** charges dans Grafana
- L'**alerte HighP95Latency** declenchee et **email envoye via Brevo** (`Notify success`)
- Le **HPA** a scale task-service de **2 a 5 replicas** sous charge
- Test HA : suppression d'1 pod sur 2 = **0.16% d'erreurs**

---

## Etape 1 — Stack via chart officiel

### Reflexion theorique — Dependances et composition

**1. Helm peut-il garantir que si l'installation de Grafana echoue, Prometheus est aussi annule ?**

**Non, pas par defaut.** Par defaut, `helm install`/`helm upgrade` applique les ressources et si une partie echoue, ce qui a deja ete cree **reste en place** (etat partiel). Helm ne fait pas de rollback automatique.

Pour garantir atomic, il faut le flag `--atomic` : si l'installation/mise a jour echoue, helm fait automatiquement un rollback vers l'etat precedent. `--atomic` implique `--wait` : helm attend que toutes les ressources soient prêtes avant de declarer le succes.

**2. Comment adapter les commandes `helm upgrade --install` / `helm install` pour garantir ce comportement ?**

En ajoutant `--atomic --wait --timeout` :

```bash
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --atomic \
  --wait \
  --timeout 10m \
  --set grafana.adminPassword=admin
```

- `--wait` : attend que tous les pods/PVC/... soient Ready
- `--atomic` : rollback automatique en cas d'echec 
- `--timeout 10m` : laisser le temps aux pods de demarrer comme kube-prometheus-stack est lourd

### Installation effectuee (etape 1, install directe)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin
```

### Reflexion theorique — Pourquoi port-forward pour Grafana ?

**1. Combien de fichiers pour installer cette stack complete ? Comparaison avec la partie 1.**

**Zero fichier** pour l'install directe de l'etape 1 : une seule commande `helm` deploie Prometheus, Grafana, Alertmanager, kube-state-metrics et node-exporter.

En **Partie 1**, la meme stack d'observabilite demandait **8 fichiers ecrits a la main** :

- `infra/otel/config.yml`
- `infra/tempo/tempo.yml`
- `infra/prometheus/prometheus.yml`
- `infra/loki/loki-config.yml`
- `infra/promtail/promtail-config.yml`
- `infra/grafana/provisioning/datasources/datasources.yml`
- `infra/grafana/provisioning/dashboards/dashboards.yml`
- `docker-compose.infra.yml`

Le chart officiel encapsule des centaines de lignes de config, des dashboards Kubernetes prets a l'emploi et le cablage Prometheus<->Grafana, le tout maintenu par la communaute.

**2. Quel mecanisme permet a TaskFlow d'etre accessible sur le port 80 sans port-forward ?**

La combinaison de deux elements :

- `**kind-config.yaml`** : `extraPortMappings` mappe le port 80 du conteneur kind vers le port 8080 de la machine hote. C'est un tunnel reseau de la machine vers le cluster.
- `**k8s/base/ingress.yaml`  : un Ingress route le trafic HTTP entrant (`/` -> frontend, `/api` -> api-gateway). L'**Ingress Controller nginx**, force sur le control-plane via le label `ingress-ready=true`, ecoute sur ce port 80.

**3. Pourquoi ce mecanisme ne marche pas pour Grafana dans le namespace `monitoring` ?**

Parce que **aucun Ingress n'a ete cree pour Grafana**. Le Service `monitoring-grafana` est de type **ClusterIP** : il n'est accessible que depuis l'interieur du cluster. Sans Ingress qui le route, le tunnel `extraPortMappings` qui pointe vers l'Ingress Controller n'a aucune regle pour l'atteindre. D'ou la necessite du `port-forward` qui cree un tunnel direct ponctuel vers le Service.

**4. Quelle modification pour rendre Grafana accessible via `http://localhost/grafana` (sans toucher au code de kube-prometheus-stack) ?**

Surcharger les values du chart pour :

1. Creer un **Ingress Grafana** avec le path `/grafana`
2. Configurer le **root_url** et **serve_from_sub_path** de Grafana pour qu'il serve ses assets sous le sous-chemin

```yaml
kube-prometheus-stack:
  grafana:
    ingress:
      enabled: true
      ingressClassName: nginx
      path: /grafana
      pathType: Prefix
    grafana.ini:
      server:
        root_url: "http://localhost:8080/grafana"
        serve_from_sub_path: true
```

`serve_from_sub_path: true` est essentiel : sans lui, Grafana genere ses liens/assets a la racine `/` et casse derriere un sous-chemin.

---

## Etape 2 — Integrer ses dashboards customs

### Reflexion theorique — Surcharger les valeurs d'un chart tiers

**1. Pourquoi separer les valeurs sensibles dans un fichier a part ? Comment passer les deux fichiers a Helm ?**

On separe pour pouvoir **versionner `values.monitoring.yaml`** (config non sensible : retention, dashboards, ServiceMonitor selector) dans Git, tout en **gardant les secrets hors du depot** (`values.monitoring.secret.yaml` est dans le `.gitignore`). Ainsi la config est partagee et auditee, mais les credentials (mot de passe Grafana, SMTP Brevo) ne fuitent jamais.

On passe les deux fichiers avec plusieurs `-f` (ils sont fusionnes dans l'ordre, le dernier gagne) :

```bash
helm upgrade --install monitoring ./helm/monitoring \
  --namespace monitoring \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml
```

**2. Difference entre `--values fichier.yaml` et `--set grafana.adminPassword=admin` ? Quand preferer l'un ou l'autre ?**

- `**--values fichier.yaml`** : charge un fichier YAML entier. Adapte aux configurations structurees, nombreuses, ou imbriquees. Lisible, versionnable (s'il n'a pas de secret), reutilisable.
- `**--set cle=valeur`** : surcharge ponctuelle en ligne de commande. La valeur n'apparait pas dans un fichier — utile pour injecter un secret depuis une variable d'environnement CI (`--set ...=$VAR`) ou pour un override rapide one-shot.

On prefere `--values` pour la config de fond, et `--set` pour les **secrets injectes au deploiement** (CI/CD) ou un test ponctuel. Attention : `--set` apparait dans l'historique shell, donc pour un secret durable un gestionnaire dedie est preferable.

### ConfigMap inline — verification

**1. Commande utilisee et presence du dashboard dans Grafana**

Le ConfigMap inline porte le label `grafana_dashboard: "1"` que la sidecar Grafana surveille. Application :

```bash
kubectl apply -f helm/monitoring/templates/dashboard-configmap.yaml
```

Apres rechargement de Grafana, le dashboard apparait. Verification via l'API Grafana :

```bash
curl -s "http://admin:admin@localhost:3100/api/search?type=dash-db"
```

Resultat — nos 2 dashboards customs sont bien charges :

```
Vue d'ensemble des services (uid: services-overview)
```

```
Metriques metier TaskFlow (uid: business-metrics)
```

### Reflexion theorique — Limites du ConfigMap inline

**1. Pourquoi coller le JSON directement dans `data` avec `|` est-il problematique ?**

- **Lisibilite** : un dashboard JSON fait des centaines de lignes. Colle dans un ConfigMap avec `|`, il pollue le YAML et rend le fichier illisible.
- **Maintenabilite** : modifier le dashboard via l'UI Grafana puis recopier-coller le JSON en respectant l'indentation YAML est penible et source d'erreurs.
- **Plusieurs dashboards** : avec N dashboards, il faudrait N blocs `|` dans le ConfigMap, ou N ConfigMaps. Ajouter un dashboard impose de modifier le template a chaque fois.

**2. Quelle fonction charge automatiquement tous les `*.json` d'un dossier ?**

La fonction `**.Files.Glob`** , combinee a `.Files.Get` pour lire le contenu de chaque fichier.

**3. Implementation proposee**

`templates/dashboard-configmap.yaml` :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: taskflow-dashboards
  namespace: {{ .Release.Namespace }}
  labels:
    grafana_dashboard: "1"
data:
{{- range $path, $bytes := .Files.Glob "dashboards/*.json" }}
  {{ base $path }}: |-
{{ $.Files.Get $path | indent 4 }}
{{- end }}
```

Ainsi, deposer un nouveau `.json` dans `dashboards/` suffit : le template le charge automatiquement, sans aucune modification. Verification du rendu :

```bash
helm template monitoring ./helm/monitoring \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml \
  --show-only templates/dashboard-configmap.yaml
```

Sortie : les cles `business-metrics.json` et `services-overview.json` sont generees.

**UID de la datasource** : nos dashboards referencent `"uid": "prometheus"`. kube-prometheus-stack provisionne justement sa datasource Prometheus avec l'UID `prometheus` (verifie via `curl http://admin:admin@localhost:3100/api/datasources`). Donc **aucune adaptation d'UID necessaire** — les dashboards affichent directement les donnees.

---

## Etape 5 — Notifier via Alertmanager (email Brevo)

### Problemes rencontres et resolus

**Probleme 1 — `missing port in address`** : a la premiere install, l'Alertmanager restait `RECONCILED=False` avec l'erreur :

```
provision alertmanager configuration: failed to initialize from secret:
address smtp-relay.brevo.com: missing port in address
```

Le `smtp_smarthost` exige un host **avec port**. Correction : `host: "smtp-relay.brevo.com:587"`. Apres redeploiement, Alertmanager passe `2/2 Running`.

**Probleme 2 — uniquement le `resolved`, pas le `firing`** : avec la config initiale (`group_interval: 5m`, pas de `group_by`), toutes les alertes etaient dans un seul groupe. L'alerte HighP95 se declenchait puis se resolvait **avant** le flush groupe — on ne recevait que le `resolved`. C'est exactement le piege de timing decrit dans le TP.

Correction dans `route` :

```yaml
route:
  receiver: email
  group_by: ['alertname']   # chaque alerte = son propre groupe
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 1h
```

### Test de declenchement

Comme la latence **interne** du task-service reste basse meme sous charge, on a abaisse temporairement le seuil via `--set alertThresholds.p95Ms=30` pour valider la chaine de bout en bout, puis on l'a restaure a 500.

Sous charge k6 (120 VUs), l'alerte a suivi le cycle `inactive -> pending -> firing` :

```
[1] alerte=inactive | p95=135ms
[5] alerte=pending  | p95=135ms
[11] alerte=firing  | p95=160ms
```

Et l'email est parti (logs Alertmanager en mode debug) :

```
caller=notify.go:860 level=debug component=dispatcher receiver=email
integration=email[0] aggrGroup="{}:{alertname=\"HighP95Latency\"}"
alerts=[HighP95Latency[593eafd][active]] msg="Notify success" attempts=1
```

`msg="Notify success"` avec l'alerte en etat `**active**` (firing) confirme la livraison vers Brevo (verifiable dans les logs transactionnels Brevo).

### Comprendre les timings


| Parametre        | Ou                 | Role                                         | Valeur retenue |
| ---------------- | ------------------ | -------------------------------------------- | -------------- |
| `for`            | PrometheusRule     | Duree de condition vraie avant `firing`      | 30s            |
| `group_wait`     | Alertmanager route | Attente avant la 1ere notif du groupe        | 10s            |
| `group_interval` | Alertmanager route | Delai min entre 2 notifs si le groupe change | 1m             |


Total avant reception : `for` (30s) + `group_wait` (10s) ~= 40s. Il faut donc que le pic de latence dure plus de ~40s pour recevoir le `firing` (sinon seulement le `resolved`). D'ou le `group_by: alertname` + timings courts.

### Conflit de field manager

Apres le debug, le `kubectl patch ... logLevel=debug` a cree un field manager `kubectl-patch` qui possede `.spec.logLevel`. Le `helm upgrade` suivant a echoue :

```
Upgrade "monitoring" failed: conflict ... Kind=Alertmanager:
Apply failed with 1 conflict: conflict with "kubectl-patch" ... .spec.logLevel
```

Resolution : retrait du champ avant le prochain upgrade, comme indique dans le TP :

```bash
kubectl patch alertmanager monitoring-kube-prometheus-alertmanager -n monitoring \
  --type='json' -p='[{"op": "remove", "path": "/spec/logLevel"}]'
```

Puis `helm upgrade` repasse en `deployed`.

---

## Etape 6 — Auto-scaling avec le HPA

### Observation sous charge

`kubectl get hpa -n staging` au pic de charge (120 VUs k6) :

```
NAME           TARGETS        MINPODS   MAXPODS   REPLICAS
task-service   cpu: 77%/70%   2         5         4
```

Evenements du HPA :

```
SuccessfulRescale  New size: 3; reason: cpu resource utilization above target
SuccessfulRescale  New size: 4; reason: cpu resource utilization above target
SuccessfulRescale  New size: 5; reason: cpu resource utilization above target
```

Le HPA a donc scale **2 -> 3 -> 4 -> 5** (max) quand le CPU a depasse 70% de la request.

### Reflexion theorique — Observer et comprendre le scaling

**1. Quels services montrent une augmentation de latence/erreurs sous charge ? Coherent avec l'architecture ?**

Dans Grafana et k6, c'est le **task-service** qui est le plus sollicite (latence et CPU en hausse). C'est coherent avec l'architecture : le scenario k6 emet 2 requetes task-service par iteration (GET + POST), contre 1 pour user-service et notification-service. De plus chaque POST fait un INSERT PostgreSQL + un publish Redis. L'api-gateway voit aussi tout le trafic passer (proxy) mais reste leger (pas de DB).

**2. Quels services ont du sens a scaler horizontalement, lesquels non ?**


| Service              | Scalable horizontalement ? | Justification                                                                               |
| -------------------- | -------------------------- | ------------------------------------------------------------------------------------------- |
| api-gateway          | Oui                        | Stateless (proxy + JWT), repartit bien la charge                                            |
| task-service         | Oui                        | Stateless cote API (l'etat est en DB), c'est le goulot -> candidat n1                       |
| user-service         | Oui                        | Stateless (login/register), l'etat est en DB                                                |
| notification-service | **Non (rester a 1)**       | Abonne Redis Pub/Sub : chaque replica recevrait le meme message -> notifications dupliquees |
| postgres             | **Non (pas simplement)**   | Stateful : scaler en ecriture demande replication/sharding, pas un simple replicaCount      |
| redis                | **Non en l'etat**          | Bus de messages stateful ; necessiterait Sentinel/Cluster                                   |


**3. Le HPA a-t-il ameliore les resultats ? Si surprenant, expliquer.**

**Resultat surprenant : le HPA n'ameliore pas vraiment les metriques end-to-end sur kind.** En effet :

- Le k6 montre une **p95 end-to-end de ~20s** sous 120 VUs, alors que la **latence interne du task-service reste a ~110-187ms**.
- Le goulot reel n'est pas le CPU du task-service mais la **file d'attente TCP / le nombre de connexions** (cf Partie 2, Q10). Ajouter des pods task-service ne resout pas ce probleme.
- Surtout, **sur kind tous les pods partagent les memes ressources de la machine hote** : ajouter des replicas ne fait qu'augmenter la contention CPU globale, sans capacite supplementaire reelle.

Le HPA fait correctement son travail (il scale a 5 quand le CPU depasse 70%), mais l'absence de noeuds supplementaires limite le benefice. C'est une limite de l'environnement, pas du HPA.

**4. Le HPA scale les pods, mais si le noeud n'a plus de ressources ?**

Si le noeud est sature, les nouveaux pods restent en `**Pending`** (impossible a scheduler, faute de ressources allouables). Le HPA ne cree pas de capacite, il ne fait qu'augmenter le nombre de pods demandes.

Pour scaler les **noeuds eux-memes**, il faut un **Cluster Autoscaler** (ajoute/retire des noeuds d'un node pool cloud quand des pods sont Pending) ou **Karpenter** (provisionnement de noeuds just-in-time, plus rapide et plus fin, sur AWS notamment). Sur **kind, cela ne fonctionne pas** : kind tourne dans des conteneurs Docker sur une seule machine, il n'y a pas de noeuds elastiques a provisionner. Le probleme observe (contention) ne peut donc pas etre resolu sur kind.

### Cloisonnement du HPA

Comme le HPA n'a pas de sens sur kind (ressources partagees), on l'a **desactive en staging** et configure pour la **production** :

- `values.staging.yaml` : `taskService.hpa.enabled: false`
- `values.production.yaml` : `taskService.hpa.enabled: true`, min 2 / max 10 / targetCPU 70

### Reflexion theorique — Choisir la bonne metrique de scaling

**1. Le CPU est-il la metrique la plus pertinente pour un service HTTP ?**

Pas toujours. Pour un service HTTP, beaucoup de degradations ne sont **pas CPU-bound**. Exemple concret observe ici : sous 120 VUs, la **p95 end-to-end explose a 20s** alors que le **CPU du task-service reste modere** et la latence interne basse. Le service passe son temps a attendre (file TCP, I/O DB, connexions) sans bruler de CPU. Un HPA CPU ne se declencherait pas, alors que les utilisateurs subissent une forte degradation.

**2. Avec quelles autres metriques (deja exposees) combiner le HPA, et quel seuil ?**

Le HPA `autoscaling/v2` permet de combiner plusieurs metriques (il scale des que **l'une** depasse son seuil). On combinerait le CPU avec une **metrique custom applicative** deja exposee :

- `**http_request_duration_ms` (p95)** : scaler si la p95 depasse ~200-300ms. C'est le signal le plus proche de l'experience utilisateur (nos dashboards montrent une p95 normale ~50ms ; au-dela de 200-300ms on est en degradation).
- ou `**http_requests_total` (taux de requetes par pod)** : scaler si le debit par pod depasse un seuil calibre sur la capacite d'un pod (ex : ~50 req/s/pod d'apres les tests de la Partie 2 ou ca commencait a se degrader).

Concretement, via l'adaptateur prometheus-adapter, on exposerait ces metriques au HPA et on configurerait par exemple : `targetCPU: 70%` **OU** `p95 > 250ms`. Le seuil p95 se justifie par nos dashboards Grafana (latence nominale tres basse, donc 250ms = anomalie claire).

**3. Cette configuration ne fonctionnerait pas directement sur le cluster. Quel composant manque ?**

Il manque le **prometheus-adapter** (Custom/External Metrics API). Le Metrics Server ne fournit que CPU/memoire (`metrics.k8s.io`). Pour scaler sur des metriques Prometheus custom (`http_request_duration_ms`, `http_requests_total`), il faut prometheus-adapter qui expose l'API `custom.metrics.k8s.io` que le HPA `autoscaling/v2` consomme.

---

## Etape 7 — Haute disponibilite et resilience

### Test effectue

Chaque service backend a `replicaCount >= 2` en staging (sauf notification-service a 1, par design). Test de panne pendant une charge k6 (20 VUs) :

**Cas 1 — suppression d'UN SEUL pod api-gateway sur 2** (`kubectl delete pod <nom>`):

```
checks_succeeded: 98.06%
http_req_failed:  0.16%  (2 requetes sur 1204)
```

Quasiment aucune erreur : l'autre replica a absorbe le trafic pendant la recreation.

**Cas 2  — suppression des DEUX pods api-gateway** (`kubectl delete pod -l app=api-gateway`, le selecteur matche tous) :

```
checks_succeeded: 2.33%
http_req_failed:  98.41%
```

Coupure quasi totale : plus aucun pod pour servir pendant la recreation simultanee.

La comparaison demontre concretement l'apport de la redondance : tuer 1 replica sur 2 = quasi transparent, tuer tous les replicas = panne.

### Reflexion theorique — Elasticite vs haute disponibilite

**1. Difference entre elasticite et haute disponibilite ? Le HPA contribue-t-il aux deux ?**

- **Elasticite** : adapter la **capacite** a la charge (scaler up quand ça charge, down quand c'est calme). Objectif : performance + cout.
- **Haute disponibilite (HA)** : **tolerer les pannes** (un pod/noeud tombe, le service reste disponible). Objectif : fiabilite.

Le HPA contribue **surtout a l'elasticite**. Il contribue **indirectement** a la HA (en maintenant `minReplicas >= 2`, il garantit toujours plusieurs instances), mais il n'est **pas** un mecanisme de HA en soi : son role est de suivre la charge, pas de tolerer les pannes. La HA est assuree par le `replicaCount`/`minReplicas >= 2` + la reconciliation Kubernetes.

**2. Avec `replicaCount: 2` sur api-gateway, que se passe-t-il si un pod crashe ? Comparaison avec `replicaCount: 1`.**

- `**replicaCount: 2`** : si un pod crashe, l'autre continue de servir (le Service route vers le replica sain). Kubernetes recree le pod manquant en parallele. **Aucune coupure** (demontre : 0.16% d'erreurs).
- `**replicaCount: 1`** : si le seul pod crashe, **coupure totale** jusqu'a sa recreation (plusieurs secondes). Pas de tolerance aux pannes.

**3. Quel composant est responsable de la reconciliation (maintien du nombre de replicas) ?**

Le **ReplicaSet** (cree et gere par le Deployment), via le **controller-manager** de Kubernetes (boucle de reconciliation). Il compare en continu l'etat reel (pods existants) a l'etat desire (`replicas`) et recree/supprime les pods pour les aligner.

**4. Le deploiement staging garantit-il la HA ? Conditions pour la prod ?**

En staging sur kind : **partiellement**. On a la redondance des pods (replicaCount >= 2) et le self-healing, mais **tous les pods tournent sur la meme machine** (un seul hote Docker). Si la machine tombe, tout tombe. De plus postgres et redis sont a 1 replica (SPOF).

Pour une vraie HA en **production**, il faut :

- **Plusieurs noeuds** repartis sur plusieurs zones de disponibilite (multi-AZ)
- **Anti-affinity** pour que les replicas d'un service ne soient pas sur le meme noeud
- **PodDisruptionBudget** pour garantir un minimum de pods disponibles pendant les maintenances
- **Postgres en HA** (replication primaire/replica, failover automatique) et **Redis en HA** (Sentinel/Cluster)
- Un **Cluster Autoscaler** pour remplacer un noeud defaillant

