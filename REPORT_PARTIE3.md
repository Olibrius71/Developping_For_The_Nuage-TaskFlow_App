# REPORT PARTIE 3 — Kubernetes

## Contexte

Objectif de cette partie: déployer la stack TaskFlow sur un cluster `kind` local via des manifests Kubernetes écrits manuellement, vérifier son comportement en conditions réelles, puis analyser les mécanismes clés (Services, Ingress, probes, StatefulSet, rolling update).

---

## Partie 1 — Monter la stack avec Kubernetes

### Etape 1 — Creation du cluster kind multi-noeuds

Commande utilisee:

`kind create cluster --name taskflow --config k8s/kind-config.yaml`

Premiere erreur rencontree:

`ERROR: failed to create cluster: unknown kind for apiVersion: kind.x-k8s.io/v1alpha4`

Cause identifiee: le champ `kind: Cluster` etait absent/incomplet dans `k8s/kind-config.yaml`.

![](z_doc-images-partie-3/img.png)  =====>   ![](z_doc-images-partie-3/img_1.png)

Correction:
- Ajout du type de ressource `kind: Cluster`

Deuxieme probleme rencontre au demarrage:
- Conflit de ports exposes par kind vers la machine hote

![](z_doc-images-partie-3/img3.png)

- Resolution: changement des `hostPort` (80 -> 8080 et 443 -> 8443)

![](z_doc-images-partie-3/img4.png)

Verification du cluster:

`kubectl get nodes`

Resultat attendu: 3 noeuds en `Ready` (1 control-plane + 2 workers).

![](z_doc-images-partie-3/img5.png)

Creation du namespace:

`kubectl create namespace staging`

**Captures a inserer**
~~- Capture erreur initiale `unknown kind`~~
~~- Capture de la correction de `kind-config.yaml`~~
~~- Capture du conflit de ports puis correction~~
~~- Capture de `kubectl get nodes` avec les 3 noeuds `Ready`~~

### Etape 2 — Terminal d'observation

Commande de suivi en continu:

`watch kubectl get pods -n staging -o wide`

cette commande n'a pas marché psk `watch` n'était pas reconnu, j'ai donc entré ça dans un Powershell pour avoir un résultat équivalent :

`while($true) { cls; kubectl get pods -n staging -o wide; sleep 2 }`

On gardera le résultat disponible pendant tout le TP pour observer:
- la creation des pods
- les transitions `Pending -> Running`
- les recreations de pods lors des scenarios de resilience
- la repartition des pods sur les noeuds

**Capture a inserer**
- Capture du terminal de watch (au debut vide puis apres deploiement)

### Etape 3 — Deploiement du user-service

Ressources preparees:
- `ConfigMap`
- `Deployment`
- `Service`

Commande:

`kubectl apply -f k8s/base/user-service/`

![](z_doc-images-partie-3/img7.png)

Sur le terminal d'observation :

![](z_doc-images-partie-3/img8.png)

Les Pods sont en 0/1 (pas 1/1), donc pas en état de run

### Etape 4 — Deploiement de PostgreSQL (StatefulSet)

Ressources:
- `Secret`
- `Service` headless (`clusterIP: None`)
- `StatefulSet` avec `volumeClaimTemplates`

Commande:

`kubectl apply -f k8s/base/postgres/`

Observation:
- 1 pod PostgreSQL `Running`
- PVC cree automatiquement et associe au pod
- Identite reseau stable du pod (`postgres-0`)

**Captures a inserer**
- `kubectl get pods -n staging -o wide`
- `kubectl get pvc -n staging`

#### Deployment vs StatefulSet — Reponses

1. **Propriete garantissant le stockage persistant**  
   C'est le couple `StatefulSet + volumeClaimTemplates`: chaque replica obtient son propre PVC stable (ex: `postgres-data-postgres-0`), qui reste rattache a la meme identite logique du pod meme apres recreation/scheduling sur un autre noeud.

2. **Pourquoi un Deployment est inadapté pour PostgreSQL**  
   Un Deployment gere des pods interchangeables (stateless) sans identite stable. Pour une base relationnelle, il faut une identite et un volume stables par instance, sinon on risque corruption/incoherence, perte de donnees ou re-attachement incorrect de volumes.

3. **Service qui meriterait potentiellement un StatefulSet en prod**  
   Redis est le meilleur candidat (si utilise avec persistence/AOF, replication, Sentinel/Cluster). En TP, Redis sert surtout de bus ephemere donc Deployment suffit. En production, un Redis stateful peut necessiter identite stable et stockage persistant.

### Etape 5 — Deploiement task-service et notification-service

Ressources a fournir pour chaque service:
- `ConfigMap`
- `Deployment`
- `Service`

Commandes:

`kubectl apply -f k8s/base/task-service/`  
`kubectl apply -f k8s/base/notification-service/`

#### Analyse subscriber Redis (notification-service)

1. **Comment il consomme les evenements Redis**  
   Le service ouvre une souscription Pub/Sub Redis sur des canaux d'evenements publies par `task-service`.

2. **Impact sur le nombre de replicas**  
   Avec Redis Pub/Sub natif, chaque instance abonnee recoit le message: multiplier les replicas de `notification-service` peut dupliquer les traitements (emails/notifs).  
   En staging, un seul replica pour `notification-service` est le choix le plus sur.  
   `task-service` peut etre replique horizontalement car il est principalement stateless cote API.

3. **Justification**  
   Choix de `notification-service` en 1 replica pour eviter les doublons fonctionnels; `task-service` en plusieurs replicas pour disponibilite et repartition de charge.

**Captures a inserer**
- `kubectl get pods -n staging` avec les deux services `Running`
- Optionnel: extrait de logs de `notification-service` montrant la consommation d'evenements

### Etape 6 — Deploiement Redis (Deployment)

Ressources:
- `Deployment`
- `Service`

Point important:
- Redis n'expose pas `/health`; la readiness probe doit etre de type `tcpSocket` ou `exec` (`redis-cli ping`).

Commande:

`kubectl apply -f k8s/base/redis/`

**Capture a inserer**
- Capture du pod Redis en `Running`
- Capture de la readiness probe configuree dans le manifest

### Etape 7 — Deploiement api-gateway et frontend

Ressources a preparer pour chaque service:
- `ConfigMap`
- `Deployment`
- `Service`

Choix d'architecture proposes:
- `api-gateway`: 2 replicas (point d'entree critique, stateless)
- `frontend` (nginx + assets statiques): 2 replicas pour disponibilite, ressources plus faibles que les services de logique metier

Justification:
- `api-gateway` execute de la logique de proxy par requete, sensible a la charge
- `frontend` sert majoritairement des fichiers statiques precompiles
- en staging, indisponibilite breve acceptable mais on conserve une redondance minimale

**Captures a inserer**
- `kubectl get pods -n staging` avec `api-gateway` et `frontend` en `Running`
- `kubectl get svc -n staging` pour verifier l'exposition interne

### Etape 8 — Verification globale

Commande:

`kubectl get all -n staging`

Resultat attendu:
- tous les pods en `1/1 Running`
- services `ClusterIP` presents
- deployment/statefulset disponibles

Logs verifies:
- `kubectl logs -n staging deployment/task-service`
- `kubectl logs -n staging deployment/user-service`
- `kubectl logs -n staging deployment/notification-service`
- `kubectl logs -n staging deployment/api-gateway`

Note:
- erreurs vers `otel-collector` possibles et non bloquantes dans ce TP (stack observabilite non deployee ici).

**Captures a inserer**
- `kubectl get all -n staging`
- extrait de logs applicatifs

---

## Partie 2 — Exposition via Ingress

Etapes realisees:
- installation du controller ingress-nginx
- attente du readiness
- verification du noeud de scheduling du controller
- patch `nodeSelector` avec `ingress-ready=true`
- verification du rollout
- application de `k8s/base/ingress.yaml`

Tests fonctionnels:
- `curl http://localhost/api/health` (ou `http://localhost:8080/api/health` selon mapping local)
- ouverture de l'UI TaskFlow dans le navigateur

### Investigation creation de compte (si erreur)

Demarche attendue:
1. verifier reponse Ingress
2. verifier logs `api-gateway`
3. verifier logs `user-service`
4. verifier acces PostgreSQL

Commande utile pour acceder a PostgreSQL depuis la machine:

`kubectl port-forward -n staging svc/postgres 5432:5432`

Puis connexion locale (ex: DBeaver/psql) sur `localhost:5432`.

Cause typique trouvee en comparant avec `docker-compose.yaml`:
- initialisation SQL automatique non reproduite dans Kubernetes (pas d'init script, job, migration ou seed applique)

Correction type:
- ajouter un mecanisme d'initialisation DB (init script, migration au startup, ou Job Kubernetes)

**Captures a inserer**
- `kubectl get pods -n ingress-nginx -o wide` avant/apres patch
- `curl /api/health` reussi
- navigateur sur TaskFlow
- preuve investigation logs (Ingress -> gateway -> user-service)
- capture port-forward + verification DB

### Service vs Ingress — Reponses

1. **Pourquoi pas de connexion directe `localhost:5432` sans commande**  
   Le service PostgreSQL est `ClusterIP`, donc accessible uniquement a l'interieur du cluster. Sans `port-forward` (ou NodePort/LoadBalancer), aucun bind direct n'existe sur la machine hote.

2. **Qui fait vraiment le routage HTTP de l'Ingress**  
   C'est le pod `ingress-nginx-controller`. L'objet `Ingress` ne route pas seul: il decrit des regles que le controller applique. Ce controller apparait car on l'a installe via le manifest officiel ingress-nginx.

3. **Qui load-balance entre replicas de `task-service`**  
   C'est le `Service` Kubernetes (via kube-proxy/iptables/ipvs) qui repartit le trafic vers les endpoints disponibles. L'Ingress route surtout du trafic HTTP entrant vers un Service, pas directement vers chaque pod.

---

## Partie 3 — Scenarios d'observation

### Scenario 1 — Self-healing

Commande:

`kubectl delete pod -n staging -l app=task-service`

Observation:
- suppression immediate du pod courant
- recreation automatique d'un nouveau pod par le ReplicaSet/Deployment
- retour en `1/1 Running` apres quelques secondes

Explication:
- l'etat desire (nombre de replicas) est defini dans le Deployment
- le control loop Kubernetes detecte l'ecart et reconcilie automatiquement

**Captures a inserer**
- avant suppression
- pendant recreation (`ContainerCreating`)
- retour a l'etat stable

### Scenario 2 — Readiness probe

Modification volontaire:
- `readinessProbe.path: /does-not-exist` sur `task-service`

Observation attendue:
- pod demarre mais reste `0/1 Ready`
- pod non ajoute aux endpoints du Service
- creation de tache echoue (service non routable), alors que d'autres composants peuvent repondre

Apres correction `path: /health`:
- pods passent en `1/1`
- flux fonctionnel retabli

#### Readiness vs Liveness

- **Readiness probe**: determine si le pod peut recevoir du trafic. En echec, pod vivant mais retire du load-balancing.
- **Liveness probe**: detecte un pod bloque. En echec, kubelet redemarre le conteneur.

Si la liveness avait ete cassee:
- redemarrages en boucle (`CrashLoopBackOff` possible)
- indisponibilite plus brutale qu'une simple non-readiness

**Captures a inserer**
- `kubectl get pods -n staging` montrant `0/1`
- test fonctionnel KO puis OK apres correction

### Scenario 3 — Rolling update frontend

Etapes:
1. build/push image frontend `v1.0.1` avec changement visible
2. mise a jour du tag dans le deployment
3. `kubectl apply -f k8s/base/frontend/deployment.yaml`
4. consultation historique rollout
5. annotation `kubernetes.io/change-cause`
6. rollback `kubectl rollout undo`

Reponses:

1. **Pods disponibles pendant update**  
   Le nombre de pods disponibles ne doit pas tomber brutalement si la strategie RollingUpdate est correcte (`maxUnavailable` limite) et si les probes sont valides.

2. **Si le nouveau pod ne passe jamais `1/1`**  
   Le rollout reste bloque, Kubernetes n'augmente pas la part de trafic vers une revision non prete. Selon la strategie, l'ancienne version continue de servir.

3. **Importance des annotations de revision**  
   En equipe, cela permet d'identifier rapidement le "pourquoi" de chaque deploiement, accelere incident review et rollback.

4. **Limites de `kubectl rollout undo` en production**  
   Utile mais insuffisant seul: il faut aussi strategie canary/blue-green, SLO, alerting, DB migration backward-compatible, tests post-deploiement et runbook.

**Captures a inserer**
- coexistence pods ancienne/nouvelle version
- `kubectl rollout history -n staging deployment/frontend`
- UI avant/apres
- preuve rollback

---

## Reflexion theorique — repetitivite YAML

Valeurs repetees dans plusieurs manifests:
- namespace (`staging`)
- tags d'images
- noms DNS des services internes (`postgres`, `redis`, `user-service`, etc.)
- ports applicatifs
- probes et ressources (requests/limits)

Impact concret d'un changement pour la production:
- risque d'oubli dans un fichier
- incoherences entre services
- regressions difficiles a diagnostiquer
- maintenance lente et sujette aux erreurs

Conclusion:
- cette repetition justifie l'usage de templates/parametrisation (Helm) pour centraliser les valeurs et fiabiliser les deploiements multi-environnements.

---

## Checklist livrable (grille d'evaluation)

- [ ] Tous les manifests requis existent sous `k8s/base/` (postgres, redis, user-service, task-service, notification-service, api-gateway, frontend, ingress)
- [ ] Tous les pods `1/1 Running` dans `staging`
- [ ] Application accessible via Ingress (`/` et `/api/health`)
- [ ] Creation de compte fonctionnelle
- [ ] Scenarios self-healing/readiness/rolling update documentes avec preuves
- [ ] Captures d'ecran inserees a chaque etape critique
- [ ] Justifications techniques explicites (StatefulSet, probes, replicas, Service vs Ingress)

