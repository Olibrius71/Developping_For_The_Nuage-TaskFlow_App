# TP — Helm

## Objectif

Déployer la stack d'observabilité via les charts officiels.

---

## Partie B - Stack d'observabilité

### Étape 1 — Via chart officiel

#### Comprendre les dépendances de chart

`kube-prometheus-stack` n'est pas un chart monolithique. Inspectez son `Chart.yaml` :

```bash
helm show chart prometheus-community/kube-prometheus-stack
```

Vous verrez une section `dependencies:` listant Prometheus, Alertmanager, Grafana et kube-state-metrics comme sous-charts. Helm les télécharge et les orchestre tous ensemble.

##### Réflexion théorique — Dépendances et composition

> Répondez dans votre `REPORT.md` :
>
> 1. `kube-prometheus-stack` installe Prometheus, Grafana, Alertmanager et kube-state-metrics en une seule commande. Helm peut-il garantir que si l'installation de Grafana échoue, Prometheus est également annulé ?
> Appuyez-vous la doc https://helm.sh/docs/helm/ pour répondre correctement.
> 2. Comment adapterez vous vos prochaines commandes `helm upgrade --install` et `helm install` pour garantir ce comportement ?

#### Installer

```bash

# Ajouter le repo
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo update

# Installer
helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin
```

Attendez que les Pods soient prêts :

```bash
kubectl get pods -n monitoring -w
```

Accédez à Grafana :

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3100:80
```

> Grafana est disponible sur http://localhost:3100 (admin/admin)

> **Question** : combien de fichiers avez-vous écrits pour installer cette stack complète ? Comparez avec ce que vous avez fait en partie 1.

---

##### Réflexion théorique — Pourquoi port-forward pour Grafana ?


> Répondez dans votre `REPORT.md` :
>
> 1. combien de fichiers avez-vous écrits pour installer cette stack complète ? Comparez avec ce que vous avez fait en partie 1.
>
> TaskFlow est accessible directement sur `http://localhost` sans `port-forward`. Grafana, lui, nécessite :
>
> ```bash
> kubectl port-forward -n monitoring svc/monitoring-grafana 3100:80
> ```
>
> 2. Relisez votre `k8s/kind-config.yaml` et votre `k8s/base/ingress.yaml`. Quel mécanisme permet à TaskFlow d'être accessible sur le port 80 sans `port-forward` ?
> 3. Pourquoi ce mécanisme ne fonctionne-t-il pas pour Grafana dans le namespace `monitoring` ?
> 4. Quelle modification faudrait-il apporter (sans toucher au code de kube-prometheus-stack) pour rendre Grafana accessible via une URL comme `http://localhost/grafana` ?

---

### Étape 2 — Intégrer ses dashboards customs

La force de Helm se voit ici : vous pouvez personnaliser entièrement un chart tiers sans toucher à son code.

Regardez `helm/monitoring/values.monitoring.yaml`.

##### Réflexion théorique — Surcharger les valeurs d'un chart tiers

> Répondez dans votre `REPORT.md` :
>
> `kube-prometheus-stack` expose des centaines de valeurs configurables. `values.monitoring.yaml` surcharge certaines d'entre-elles pour le faire fonctionner dans votre contexte. Vous disposez également de `values.monitoring.secret.example.yaml` afin d'écrire `values.monitoring.secret.yaml`
> 1. Pourquoi séparer les valeurs sensibles dans un fichier à part ? Comment passez-vous les deux fichiers à Helm en même temps ?
> 2. Quelle différence y a-t-il entre passer `--values mon-fichier.yaml` et `--set grafana.adminPassword=admin` ? Dans quel cas préférez-vous l'un ou l'autre ?


Réinstallez avec ces fichiers de valeurs :

```bash
helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml
```

---

**Vérifier le mécanisme avec un ConfigMap inline**

Un fichier `helm/monitoring/templates/dashboard-configmap.yaml` permet à Grafana de charger automatiquement tout ConfigMap labellisé `grafana_dashboard: "1"` dans le namespace `monitoring`.

Appliquez ce fichier avec la commande `kubectl` que vous connaissez déjà et rechargez Grafana 

##### Réflexion théorique

> Dans votre `REPORT.md`
>
> 1. Donnez la commande utilisé et montrez la précence du dashboard dans Grafana

---

**Créer un chart Helm local avec `kube-prometheus-stack` en dépendance**

La méthode précédente (`kubectl apply`) crée des ressources hors du contrôle de Helm. 

- Pour gérer l'ensemble de la stack via Helm, créez un chart local `helm/monitoring/Chart.yaml` qui embarque `kube-prometheus-stack` comme dépendance.

- Supprimez d'abord la release et le namespace existants pour repartir proprement :

```bash
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring
```

- Téléchargez la dépendance, puis installez le chart local :

```bash
helm dependency update ./helm/monitoring

helm upgrade --install monitoring ./helm/monitoring \
  --namespace monitoring \
  --create-namespace \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml
```

---

**Intégrer les dashboards via un dossier**

On va maintenant rapatrier les dashboards créés en Partie 1 (`infra/grafana/dashboards`) dans le chart Helm.

##### Réflexion théorique — Limites du ConfigMap inline

> Ouvrez un de vos fichiers JSON dans `infra/grafana/dashboards/`.
>
> 1. Pourquoi serait-il problématique de coller ce JSON directement dans le champ `data` du ConfigMap avec `|` ? Pensez à la maintenabilité, à la lisibilité, et au fait que vous avez plusieurs dashboards.
> 2. Helm permet d'accéder aux fichiers du chart depuis un template via `.Files`. Consultez la documentation : https://helm.sh/docs/chart_template_guide/accessing_files/. Quelle fonction vous permettrait de charger automatiquement tous les fichiers `*.json` d'un dossier en une seule déclaration, sans modifier le template à chaque ajout ?
> 3. Proposez une implémentation du ConfigMap en utilisant cette fonction, permettant de lire vos dashboards sous le répertoire `helm/monitoring/dashboards/*.json`.

Copiez vos fichiers JSON dans `helm/monitoring/dashboards/`. 

Avant de les utiliser, il faut adapter l'UID de la datasource Prometheus référencée dans les JSONs.

`kube-prometheus-stack` provisionne automatiquement une datasource Prometheus avec un UID défini. Si vos dashboards référencent un UID différent (celui de votre ancienne installation docker-compose), ils afficheront une erreur "Datasource not found". 

Vérifiez l'UID réel via l'API Grafana :

```bash
curl http://admin:admin@localhost:3100/api/datasources | python3 -m json.tool
```

Si l'UID dans vos JSONs ne correspond pas, remplacez-le puis vérifiez le rendu du template avant d'appliquer :

```bash
helm template monitoring ./helm/monitoring \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml \
  --show-only templates/dashboard-configmap.yaml
```

Réinstallez pour prendre en compte les dashboards :

```bash
helm upgrade --install monitoring ./helm/monitoring \
  --namespace monitoring \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml
```

Rechargez Grafana — vos dashboards apparaissent avec les données Prometheus.

---

### Étape 3 — Connecter TaskFlow à Prometheus

Pour l'instant Prometheus ne scrape aucun service TaskFlow — il ne sait pas qu'ils existent. 

Il faut lui indiquer quoi scraper via des ressources `ServiceMonitor`.

**Prérequis : préparer les Services TaskFlow**

Pour qu'un `ServiceMonitor` puisse cibler un Service, deux conditions sont nécessaires :
- Le Service doit avoir un **label** dans ses `metadata` (pour que le selector du ServiceMonitor le trouve)
- Le port doit avoir un **nom** (pour que le ServiceMonitor puisse le référencer)

Dans le chart taskflow (`helm/taskflow/templates/`), mettez à jour chaque Service backend (`task-service`, `user-service`, `api-gateway`, `notification-service`). Aidez-vous du cours pour savoir quoi ajouter à chaque template.

Puis appliquez :

```bash
helm upgrade --install taskflow ./helm/taskflow \
  --namespace staging \
  -f helm/taskflow/values.staging.yaml
```

**Créer les ServiceMonitors**

Regarder le fichier `helm/monitoring/templates/api-gateway-service-monitors.yaml`.

C'est un `ServiceMonitor` pour `api-gateway`. Il faudrait répéter ce fichier pour `task-service`, `user-service` et `notification-service` soit quatre fichiers quasi-identiques.

Helm fournit une action `range` pour éviter cette répétition.

> **Documentation** : [Helm Template Guide — Looping with the `range` action](https://helm.sh/docs/chart_template_guide/control_structures/#looping-with-the-range-action)

Utilisez `range` pour générer les quatre `ServiceMonitor` en un seul fichier `helm/monitoring/templates/service-monitors.yaml`.

**Autoriser Prometheus à découvrir les ServiceMonitors hors de son namespace**

Par défaut, Prometheus ne regarde que dans son propre namespace. Ajoutez dans `values.monitoring.yaml` :

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorNamespaceSelector: {}
    serviceMonitorSelector:
      matchLabels:
        release: monitoring
```

Réinstallez le chart monitoring :

```bash
helm upgrade --install monitoring ./helm/monitoring \
  --namespace monitoring \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml
```

Accédez à Prometheus :

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Vérifiez dans Prometheus que les cibles apparaissent : **http://localhost:9090/targets**

---

### Étape 4 — Configurer une alerte

Regardez votre fichier `helm/monitoring/templates/alerts.yaml`. La structure de la ressource `PrometheusRule` est fournie — complétez les champs manquants de la règle `HighP95Latency`.

**Contexte métier** : le `task-service` expose un histogramme `http_request_duration_ms` (en millisecondes, avec des buckets jusqu'à 2000ms). Vous voulez être alerté dès que la **latence P95** dépasse un seuil inacceptable sur une fenêtre glissante de 1 minute.

L'alerte doit satisfaire ces critères :
- Calcule le **95e percentile** de la durée des requêtes HTTP du `task-service`
- Se déclenche si ce P95 dépasse **500ms**
- Attend **30 secondes** en continu avant de passer en `firing`
- Porte un label de sévérité `warning`
- Affiche un message lisible résumant le problème

> **Indices** :
> - prom-client expose les histogrammes avec le suffixe `_bucket` — c'est ce suffixe qu'utilise `histogram_quantile()`
> - `rate()` est nécessaire pour calculer un taux sur une fenêtre temporelle avant d'appliquer `histogram_quantile()`
> - `histogram_quantile()` opère sur **chaque série individuellement** — si votre métrique a plusieurs labels (`route`, `method`, `status`...), vous devez agréger les buckets avant de calculer le quantile, sinon le résultat est faux. Comparez avec l'expression utilisée dans votre dashboard Grafana.
> - Aidez-vous de l'expression PromQL déjà enregistrée dans Grafana

> **Documentation** :
> - `histogram_quantile()` et `rate()` : [Prometheus — Querying functions](https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile)
> - Structure d'une règle d'alerte (`expr`, `for`, `labels`, `annotations`) : [Prometheus — Alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)

Appliquez via Helm :

```bash
helm upgrade --install monitoring ./helm/monitoring \
  --namespace monitoring \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml
```

Vérifiez que la règle est bien chargée sur **http://localhost:9090/rules** — elle doit apparaître en état `OK`. Vous la verrez passer en `firing` à l'étape k6.

---

### Étape 5 — Notifier via Alertmanager

Quand Prometheus déclenche une alerte, **Alertmanager** se charge de la router vers un ou plusieurs destinataires.  Les receivers disponibles incluent notamment : email, Slack, PagerDuty, OpsGenie, webhook HTTP, et Microsoft Teams. Un webhook permet d'appeler n'importe quelle API externe, ce qui ouvre la porte à des automatisations custom.

**Créer le Secret de configuration**

Regardez le fichier de configuration `helm/monitoring/templates/alertmanager-config.yaml`.

Dans `values.monitoring.yaml`, dites à kube-prometheus-stack d'utiliser ce Secret. Notez que les valeurs destinées à la dépendance doivent être imbriquées sous la clé `kube-prometheus-stack` :

```yaml
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      configSecret: taskflow-alertmanager-config
  grafana:
    ...
  prometheus:
    ...
```

Dans `values.monitoring.secret.yaml`, ajoutez les credentials SMTP (utilisez [Brevo](https://brevo.com) — gratuit, 300 emails/jour, credentials SMTP disponibles immédiatement) :

> **Important** : l'adresse `from` doit être l'adresse vérifiée dans votre compte Brevo (Expéditeurs & IP → Expéditeurs), sinon l'envoi sera rejeté même si Alertmanager indique `Notify success`.

> **Pourquoi ne pas passer la config via `alertmanager.config` dans les values ?**
>
> `kube-prometheus-stack` étant une dépendance de notre chart local, il gère le Secret de configuration d'Alertmanager via le Prometheus Operator. Passer `alertmanager.config` dans les values ne met pas à jour ce Secret de façon fiable — l'opérateur le régénère avec sa config par défaut.
>
> La solution propre : créer notre propre Secret Helm et référencer le via `configSecret`.

Réinstallez :

```bash
helm upgrade --install monitoring ./helm/monitoring \
  --namespace monitoring \
  -f helm/monitoring/values.monitoring.yaml \
  -f helm/monitoring/values.monitoring.secret.yaml
```

**Comprendre les timings**

Trois paramètres contrôlent le délai entre la détection et la réception de l'email — il est important de les distinguer :

| Paramètre | Où | Rôle |
|---|---|---|
| `for: 30s` | `PrometheusRule` | Prometheus attend 30s de condition vraie en continu avant de passer en `firing` |
| `group_wait: 5s` | Alertmanager `route` | Alertmanager attend 5s après réception avant d'envoyer la première notification |
| `group_interval` | Alertmanager `route` | Délai minimum entre deux notifications si le groupe change |

> Si `for` + `group_wait` dépasse la durée du pic de latence, vous recevrez uniquement le `resolved` sans jamais avoir reçu le `fired`. Calibrez ces valeurs en fonction de la durée attendue de vos incidents.

**Tester**

Déclenchez l'alerte avec le test de charge (étape suivante) :

```bash
k6 run scripts/load-test-realistic.js
```

Accédez à l'interface Alertmanager pour voir l'alerte en cours :

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

Ouvrez **http://localhost:9093** — l'alerte `HighP95Latency` doit apparaître. Vérifiez ensuite les logs transactionnels dans le dashboard Brevo pour confirmer la livraison.

Pour déboguer un envoi qui n'arrive pas, activez le mode debug sur Alertmanager :

```bash
kubectl patch alertmanager monitoring-kube-prometheus-alertmanager \
  -n monitoring \
  --type='merge' \
  -p='{"spec":{"logLevel":"debug"}}'

kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager -f
```

Cherchez `msg="Notify success"` ou `msg="Error on notify"` dans les logs. Une fois le debug terminé, supprimez le champ avant le prochain `helm upgrade` pour éviter un conflit de field manager :

```bash
kubectl patch alertmanager monitoring-kube-prometheus-alertmanager \
  -n monitoring \
  --type='json' \
  -p='[{"op": "remove", "path": "/spec/logLevel"}]'
```

> Pensez à commenter et documenter vos observations dans votre `REPORT.md`

---

### Étape 6 — Auto-scaling avec le HPA

Pour **ajuster automatiquement le nombre de replicas en fonction de la charge**, Kubernetes fournit le **HPA (Horizontal Pod Autoscaler)**.

**Prérequis : installer le Metrics Server**

Le HPA a besoin du **Metrics Server** pour lire les métriques CPU/mémoire des pods. Sur kind, il faut ajouter un flag pour contourner les certificats auto-signés :

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

**Implémenter le HPA**

Deux contraintes à respecter :

1. Quand le HPA est actif, il prend ownership du champ `spec.replicas` — Helm ne doit donc **pas** le définir simultanément sous peine de conflit. Le champ `replicas` doit être conditionnel.
2. La ressource `HorizontalPodAutoscaler` elle-même ne doit être générée **que si** le HPA est activé dans les valeurs.

Vous activerez le HPA en staging avec ces valeurs :

```yaml
# helm/taskflow/values.staging.yaml
taskService:
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPU: 70
```

> **Documentation** :
> - Conditions `{{- if }}` / `{{- end }}` en Helm : [Helm Template Guide — If/Else](https://helm.sh/docs/chart_template_guide/control_structures/#ifelse)
> - Spécification complète d'un `HorizontalPodAutoscaler` : [Kubernetes — HorizontalPodAutoscaler](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)

À partir de ces informations, adater le template `helm/taskflow/templates/task-service.yaml` pour ajouter le HPA.

Appliquez vos changements : 

```bash
helm upgrade --install taskflow ./helm/taskflow \
  --namespace staging \
  -f helm/taskflow/values.staging.yaml
```

Vérifiez que le HPA est actif :

```bash
kubectl get hpa -n staging
```

**Observer le comportement sous charge**

Reprenez votre test de charge k6 vu en partie 2 : `scripts/load-test-realistic.js`. Lancez-le tout en observant Grafana et le comportement des pods en temps réel :

##### Réflexion théorique — Observer et comprendre le scaling

> En vous appuyant sur ce que vous observez dans Grafana et les résultats du test de charge, répondez dans votre `REPORT.md` :
>
> 1. Regardez vos dashboards Grafana pendant le test. Quels services montrent une augmentation de latence ou d'erreurs sous charge ? Est-ce cohérent avec l'architecture de TaskFlow ?
> 2. TaskFlow est composé de plusieurs services : `api-gateway`, `task-service`, `user-service`, `notification-service`, `postgres`, `redis`. Lesquels ont du sens à scaler horizontalement, et lesquels ne le peuvent pas ou ne le devraient pas ? Justifiez pour chaque service en vous appuyant sur vos observations.
> 3. Le HPA a-t-il amélioré les résultats par rapport à un déploiement sans HPA ? Comparez les métriques (latence p95, taux d'erreurs). Si le résultat vous surprend, expliquez pourquoi.
> 4. Le HPA scale les pods — mais si le nœud sous-jacent n'a plus de ressources disponibles, que se passe-t-il ? Quel mécanisme Kubernetes (cherchez "Cluster Autoscaler" et "Karpenter") permet de scaler les nœuds eux-mêmes ? Pourrait-il résoudre le problème observé sur kind ?

**Cloisonner le HPA à la production**

Sur kind, les ressources du nœud sont partagées avec toute la machine — ajouter des pods ne fait qu'augmenter la contention. Le HPA n'a de sens que sur un vrai cluster cloud avec des nœuds élastiques.

Désactivez le HPA en staging et configurez-le correctement pour la production :

```yaml
# helm/taskflow/values.staging.yaml
taskService:
  hpa:
    enabled: false
```

```yaml
# helm/taskflow/values.production.yaml
taskService:
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPU: 70
```

Le HPA opère indépendamment d'Alertmanager — les deux systèmes sont complémentaires :

| | Prometheus / Alertmanager | HPA |
|---|---|---|
| **Rôle** | Observer et notifier | Agir sur le cluster |
| **Déclencheur** | Seuil d'alerte | Métrique continue |
| **Action** | Email, Slack, webhook | Scale up/down |

##### Réflexion théorique — Choisir la bonne métrique de scaling

> Répondez dans votre `REPORT.md` :
>
> 1. Nous avons configuré le HPA sur le CPU. Est-ce la métrique la plus pertinente pour un service HTTP ? Donnez un exemple de situation où le CPU est bas mais les utilisateurs subissent une dégradation.
> 2. Le HPA `autoscaling/v2` permet de combiner plusieurs métriques, il scale dès que **l'une** d'elles dépasse son seuil. Avec quelle autres métriques (que vous avez déjà exposé avec prometheus) combineriez-vous le HPA et quel serait le seuil que vous paramétrez (justifier, hint: regardez vos dashboard dans Grafana).
> 3. Cette configuration ne fonctionnerait pas directement sur votre cluster. Quel composant manque-t-il, et pourquoi ? 

---

### Étape 7 — Haute disponibilité et résilience

Le HPA gère l'élasticité — mais ce n'est pas la même chose que la haute disponibilité. Votre chart taskflow définit déjà un `replicaCount` par service, ce qui garantit plusieurs instances en permanence.

Vérifiez le nombre de replicas de chaque service en staging :

```bash
kubectl get deployments -n staging
```

Simulez une panne d'un pod pendant qu'un test de charge tourne :

```bash
kubectl delete pod -n staging -l app=api-gateway --wait=false
```

Observez dans Grafana si des erreurs apparaissent pendant le redémarrage du pod.

##### Réflexion théorique — Élasticité vs haute disponibilité

> Répondez dans votre `REPORT.md` :
>
> 1. Quelle différence faites-vous entre **élasticité** (scaling automatique en fonction de la charge) et **haute disponibilité** (tolérance aux pannes) ? Le HPA contribue-t-il aux deux ?
> 2. Avec `replicaCount: 2` sur `api-gateway`, que se passe-t-il si un pod crashe ? Comparez avec `replicaCount: 1`.
> 3. Kubernetes garantit que le nombre de replicas souhaité est toujours maintenu. Quel composant est responsable de cette réconciliation ? 
> 4. Votre déploiement actuel en staging garantit-il la haute disponibilité ? Quelles conditions doivent être réunies pour la garantir en production ?

---

## Livrable

**Stack d'observabilité**
- `helm/monitoring/values.monitoring.yaml` présent
- Dashboard custom `helm/monitoring/dashboards/taskflow.yaml` appliqué et visible dans Grafana
- Règle d'alerte `helm/monitoring/alerts/taskflow.yaml` appliquée

**Tests de charge**
- Captures Grafana et observations du terminal pendant le test puis résultats du test joint et interprétés dans le `REPORT.md`

**REPORT.md**
- Réponses à toutes les questions théoriques encadrées
- Observations et commentaires sur les manipulations