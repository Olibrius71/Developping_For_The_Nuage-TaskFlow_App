# REPORT PARTIE 4A — HELM

## Contexte et demarche

L'objectif est de packager toute la stack TaskFlow (api-gateway, user-service, task-service, notification-service, frontend, postgres, redis, ingress) dans un chart Helm reutilisable, parametrable par environnement, et de comprendre les apports de Helm par rapport aux manifests YAML "bruts" de la partie 3.

### Outils utilises

- **Helm v4.1.4** : installe via `brew install helm`
- **Bitnami Redis chart 18.19.4** : sous-chart officiel pour deleguer le deploiement de Redis
- **helm-diff** (plugin) : pour previsualiser les changements avant `helm upgrade`
- **kind** : cluster Kubernetes local toujours actif

### Structure du chart cree

```
helm/taskflow/
├── Chart.yaml                          # Metadonnees + dependance Bitnami Redis
├── Chart.lock                          # Lockfile genere par dependency update
├── values.yaml                         # Valeurs par defaut (dev/staging)
├── values.production.yaml              # Overrides pour la prod
├── charts/                             # Sous-charts telecharges (gitignore)
│   └── redis-18.19.4.tgz
└── templates/
    ├── postgres.yaml                   # Secret + ConfigMap initdb + StatefulSet + Service
    ├── user-service.yaml               # Deployment + Service
    ├── task-service.yaml               # Deployment + Service
    ├── notification-service.yaml       # Deployment + Service
    ├── api-gateway.yaml                # Deployment + Service
    ├── frontend.yaml                   # Deployment + Service
    └── ingress.yaml                    # Ingress nginx (route / vers frontend, /api vers api-gateway)
```

---

## Reflexion theorique — Helm vs YAML brut

### 1. Comment Helm resout-il le probleme de repetition ? Quel fichier joue le role central ?

Helm resout la repetition par le **templating** : au lieu de dupliquer la meme valeur dans 20 fichiers YAML, on l'ecrit une seule fois dans `values.yaml` et on la reference partout via `{{ .Values.cle }}`. Pour changer un namespace, un tag d'image ou un nom de service, il suffit de modifier `values.yaml` et tous les manifests sont regeneres avec la nouvelle valeur.

Le fichier central est **`values.yaml`**. C'est la source unique de verite des valeurs configurables. Les templates sont generiques (un Deployment "abstrait") et les valeurs concretes viennent uniquement du values.yaml — ce qui permet aussi de surcharger par environnement (`values.production.yaml`, `values.staging.yaml`).

### 2. A partir de quel niveau de complexite Helm devient-il indispensable ?

Helm devient **indispensable** (plus que simplement utile) a partir de :
- **3+ services** ET **2+ environnements** (dev/staging/prod par exemple), soit ~6 deploiements distincts
- Ou **1 service** mais **5+ environnements** (multi-tenancy, multi-region)
- Ou des manifests qui depassent **15-20 fichiers YAML** dupliques

Justification : a partir de ce seuil, le cout de maintenance des duplications (oublier une mise a jour dans 1 fichier sur 20 = bug en prod) depasse le cout d'apprentissage de Helm. Pour un seul service en un seul environnement (ex: un POC), Helm est de l'overhead inutile.

Pour TaskFlow : **6 services + 2 environnements** = 12 contextes potentiels. Helm est indispensable.

---

## Etape 1 — Creation du chart

### Manipulations effectuees

1. **Completion du `values.yaml`** : ajout des sections `frontend`, `taskService`, `notificationService`, `apiGateway`, `ingress` (replicaCount, tag, resources).

2. **Creation des templates** dans `helm/taskflow/templates/` pour les 4 services manquants + ingress, en suivant le pattern de `user-service.yaml` :
   - `task-service.yaml` (Deployment + Service, port 3002, REDIS_URL pointant vers `redis-master:6379`)
   - `notification-service.yaml` (Deployment + Service, port 3003)
   - `api-gateway.yaml` (Deployment + Service, port 3000, JWT_SECRET, URLs des services)
   - `frontend.yaml` (Deployment + Service, port 80)
   - `ingress.yaml` (active conditionnellement via `{{- if .Values.ingress.enabled }}`)

3. **Ajout de la dependance Bitnami Redis** dans `Chart.yaml` :
   ```yaml
   dependencies:
     - name: redis
       version: 18.19.4
       repository: https://charts.bitnami.com/bitnami
       condition: redis.enabled
   ```

4. **Telechargement du sous-chart** :
   ```
   helm dependency update ./helm/taskflow
   ```
   Resultat : creation de `Chart.lock` et telechargement de `redis-18.19.4.tgz` dans `charts/`.

5. **Verification du nom du Service Redis** :
   ```
   helm template taskflow ./helm/taskflow \
     --values ./helm/taskflow/values.yaml \
     --show-only charts/redis/templates/master/service.yaml
   ```
   Le Service genere s'appelle bien **`redis-master`** (avec le suffixe `-master` impose par le chart Bitnami 18.x, meme avec `fullnameOverride: redis`).

6. **Mise a jour de `REDIS_URL`** dans les templates `task-service.yaml` et `notification-service.yaml` :
   ```yaml
   - name: REDIS_URL
     value: redis://redis-master:6379
   ```

### Reflexion theorique — Redis chart officiel vs Postgres template maison

**1. Pourquoi Redis se prete a un chart officiel ?**

Le critere vu en cours est : **"un service est-il un produit standardise dont la config est largement la meme partout ?"**. Redis coche toutes les cases :
- C'est un service **stateless en utilisation Pub/Sub** (notre cas) avec une config tres standard
- Aucune logique metier specifique, aucun init script custom
- La config par defaut du chart Bitnami (port 6379, authentification optionnelle, persistance optionnelle) couvre 95% des cas d'usage
- Beneficie de la maintenance et des best practices de Bitnami (security updates, probes, resources defaults)

Le seul parametre custom est `auth.enabled: false` (pas d'auth en dev), tout le reste est gere par le chart.

**2. Pourquoi Postgres reste en template maison ?**

Deux elements de notre config rendraient la migration vers `bitnami/postgresql` couteuse :

1. **Initialisation custom via `init.sql`** : on monte un ConfigMap avec notre schema (`users`, `tasks`, `notifications`) dans `/docker-entrypoint-initdb.d/`. Le chart Bitnami a son propre mecanisme (`primary.initdb.scripts` ou `initdbScriptsConfigMap`) qui demande une reorganisation du ConfigMap actuel pour s'integrer correctement.

2. **Schema des tables couple a l'application** : nos tables (`users`, `tasks`, `notifications`) avec leurs FKs, contraintes CHECK et donnees de seed (alice, bob) sont specifiques a TaskFlow. Migrer vers Bitnami obligerait a maintenir ce schema dans un format compatible avec leurs scripts d'init, et a tester que la sequence (creation tables -> seed -> demarrage app) fonctionne avec leur cycle de vie (jobs/initContainers).

Pour un service "produit" standard comme Redis, le chart officiel est un win evident. Pour Postgres avec un schema applicatif specifique, le template maison reste plus simple et plus controle.

---

## Etape 2 — Values par environnement

### Reflexion theorique — Secrets et values

**1. Comment deployer avec des valeurs sensibles sans les commiter ?**

J'ai retire `postgres.password: REMPLACER_PAR_MOT_DE_PASSE_FORT` de `values.production.yaml` et tous les autres secrets. La solution est d'utiliser **`--set` au moment du deploiement** avec des variables d'environnement :

```bash
helm upgrade --install taskflow ./helm/taskflow \
  --namespace staging \
  --values values.yaml \
  --values values.production.yaml \
  --set postgres.password=$POSTGRES_PASSWORD \
  --set jwt.secret=$JWT_SECRET
```

Alternative : un fichier `values-secrets.yaml` non commite (ajoute au `.gitignore`), passe via `--values values-secrets.yaml`. Pratique pour le local mais dangereux car le fichier existe en clair sur le disque.

**2. Pourquoi cette solution est plus sure que `values.production.yaml` meme en repo prive ?**

Plusieurs raisons :
- **Surface d'exposition** : un repo "prive" reste accessible a tous les developpeurs ayant un acces lecture, aux integrations CI/CD, aux clones locaux. Un secret dans Git fuite a tout le monde qui clone, meme apres suppression (l'historique Git le conserve).
- **Rotation impossible sans recommit** : changer un mdp = nouveau commit, nouvelle propagation, et l'ancien reste pour toujours dans l'historique.
- **Pas d'audit** : impossible de tracer qui a lu le secret, alors que des outils dedies (Vault, AWS Secrets Manager, GitHub Secrets) loggent les acces.
- **Fuites accidentelles** : un repo prive peut devenir public par erreur (config GitHub mal cliquee), etre forke, ou un dev peut pousser le fichier sur son fork public.

Les secrets sortent du repo et vivent dans un coffre dedie (CI vault, Vault HashiCorp, AWS Secrets Manager, etc.).

**3. helm-secrets : quel probleme resout-il que `--set` ne resout pas ?**

`--set` resout l'injection au moment du deploiement, mais ne resout pas le **partage de la config sensible entre developpeurs** ni la **versioning des changements de secrets**.

`helm-secrets` chiffre les fichiers de values (avec GPG ou AWS KMS) avant de les commiter. Le fichier chiffre est dans Git (versionne, audite), mais seuls les utilisateurs ayant la cle privee peuvent le dechiffrer. Helm le dechiffre a la volee au `helm upgrade`.

Il devient necessaire dans les contextes :
- **Multi-tenants/multi-clients** : chaque client a ses propres secrets, qu'on veut versionner separement
- **GitOps avec ArgoCD/Flux** : ces outils tirent depuis Git, donc les secrets doivent y etre stockes (chiffres)
- **Equipes distribuees** sans Vault/AWS : helm-secrets est un middle-ground entre "tout en clair" et "gestionnaire de secrets centralise"
- **Audit reglementaire** : versioning des changements de secrets exige par le SOC2, ISO27001, etc.

**4. Passer `$POSTGRES_PASSWORD` a `helm upgrade` dans GitHub Actions sans qu'il apparaisse en clair**

Dans GitHub Actions, on stocke le secret dans **GitHub Secrets** (Settings > Secrets and variables > Actions), puis on le reference dans le workflow comme variable d'environnement :

```yaml
- name: Deploy with Helm
  env:
    POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
    JWT_SECRET: ${{ secrets.JWT_SECRET }}
  run: |
    helm upgrade --install taskflow ./helm/taskflow \
      --namespace staging \
      --values ./helm/taskflow/values.yaml \
      --values ./helm/taskflow/values.production.yaml \
      --set postgres.password=$POSTGRES_PASSWORD \
      --set jwt.secret=$JWT_SECRET
```

GitHub masque automatiquement les valeurs declarees dans `secrets.*` dans les logs (elles apparaissent comme `***`). Important : ne **jamais** faire `echo $POSTGRES_PASSWORD` ou le passer dans `--set` apres un `set -x`, car bash echappe parfois ce masking. La regle : ne jamais afficher le secret, juste le passer comme env var puis dans la commande.

---

## Etape 3 — Installation du chart

### Reflexion theorique — Variables manquantes et comparaison

**1. Que se passe-t-il si une variable referencee n'a pas de valeur dans values.yaml ?**

Helm rend **silencieusement une chaine vide** (`""`) au lieu d'echouer. Test effectue :

```bash
helm template taskflow ./helm/taskflow \
  --values values.yaml \
  --show-only templates/task-service.yaml \
  --set "taskService.tag=null"
```

Sortie observee :
```yaml
image: "bruce1000/taskflow-task-service:"
```

Le tag est vide. Le manifest est syntaxiquement valide, mais Kubernetes refusera de pull cette image et le pod restera en `ImagePullBackOff`. C'est un bug silencieux qui ne se voit qu'a l'execution.

Pour eviter ca, on peut utiliser la fonction `required` dans les templates :
```yaml
image: "{{ .Values.image.prefix }}-task-service:{{ required "taskService.tag is required" .Values.taskService.tag }}"
```
Helm refuse alors de rendre le template et echoue avec un message clair au lieu de generer un manifest casse.

**2. Comparaison `helm template task-service` vs `k8s/base/task-service/deployment.yaml`**

Differences structurelles observees :

| Aspect | k8s/base/ | helm template |
|---|---|---|
| Namespace | hardcode `staging` | `{{ .Release.Namespace }}` (dynamique) |
| Replicas | hardcode `2` | depend de `--values` (peut etre 2, 3, ou autre) |
| Tag d'image | hardcode `v1.0.0` | parametrable par environnement |
| Labels | minimaux | + `app.kubernetes.io/instance: taskflow`, `helm.sh/chart: taskflow-0.1.0`, `app.kubernetes.io/managed-by: Helm` |
| Variables d'env | viennent d'un ConfigMap (`envFrom`) | injectees directement (`env`) avec valeurs interpolees |
| ConfigMap/Secret | fichiers separes | inclus dans le meme template (pour postgres) ou pas necessaires |

**Pourquoi ces differences ?**

- Les **labels Helm** sont ajoutes automatiquement et permettent a Helm de tracker quelles ressources lui appartiennent (essentiel pour `helm uninstall` et le rollback).
- La **parametrisation** est tout l'interet de Helm : un meme template, plusieurs deploiements possibles avec des configs differentes.
- Le **namespace dynamique** evite de hardcoder une valeur qui changera selon l'environnement (staging, production, dev).

### Installation effectuee

```bash
kubectl delete namespace staging
kubectl create namespace staging

helm upgrade --install taskflow ./helm/taskflow \
  --namespace staging \
  --values ./helm/taskflow/values.yaml \
  --set postgres.password=taskflow \
  --set jwt.secret=dev-secret-change-in-production
```

Verification :
```bash
helm list -n staging
# NAME       NAMESPACE  REVISION  STATUS    CHART          APP VERSION
# taskflow   staging    1         deployed  taskflow-0.1.0 1.0.0

kubectl get all -n staging
# Tous les pods en 1/1 Running (api-gateway, frontend, notification-service,
# task-service, user-service, postgres-0, redis-master-0)
```

---

## Etape 4 — Mise a jour et rollback

### Plugin de previsualisation : helm-diff

Plugin trouve : **`helm-diff`** (https://github.com/databus23/helm-diff). Installation :

```bash
helm plugin install https://github.com/databus23/helm-diff
```

### Modification effectuee

Augmentation des replicas du `notification-service` dans `values.yaml` :

```diff
 notificationService:
-  replicaCount: 1
+  replicaCount: 2
   tag: v1.0.0
```

### Previsualisation

```bash
helm diff upgrade taskflow ./helm/taskflow \
  --namespace staging \
  --values ./helm/taskflow/values.yaml \
  --set postgres.password=taskflow \
  --set jwt.secret=dev-secret-change-in-production
```

Sortie reelle observee :
```diff
staging, notification-service, Deployment (apps) has changed:
  # Source: taskflow/templates/notification-service.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: notification-service
    namespace: staging
  spec:
-   replicas: 1
+   replicas: 2
    selector:
      matchLabels:
        app: notification-service
    template:
      [...rest unchanged...]
```

Seule la ligne `replicas: 1 -> 2` change, le reste est identique. On voit clairement et unitairement l'impact avant d'appliquer.

### Reflexion theorique — Outil critique : replicaCount vs image.tag

**Cet outil est particulierement critique pour un changement de `image.tag`.** Justification :

- Un changement de `replicaCount` est **purement quantitatif** : Kubernetes scale up/down sans toucher au code applicatif. Le risque est limite (verifier qu'on a assez de ressources cluster).
- Un changement de `image.tag` declenche un **rolling update** qui remplace les pods un par un. Si la nouvelle image est cassee (bug, mauvaise config, image manquante), les nouveaux pods ne passent pas en Ready, le rolling update se bloque a moitie, et selon `maxUnavailable` une partie du trafic est perdue.

Sans `helm diff`, on ne sait pas si le `helm upgrade` va juste changer un nombre, ou rouler un nouveau code en production. Avec `helm diff`, on voit clairement :
- `replicas: 1 -> 2` = changement benin
- `image: v1.0.0 -> v1.0.1` = rolling update complet, a tester avant

Sur une stack avec 6 services, un `helm upgrade` peut declencher 6 rolling updates simultanes si on n'a pas verifie les diffs au prealable. C'est la qu'`helm-diff` devient critique pour eviter une mise en prod hasardeuse.

### Application et observation du rolling update

```bash
helm upgrade taskflow ./helm/taskflow \
  --namespace staging \
  --values ./helm/taskflow/values.yaml \
  --set postgres.password=taskflow \
  --set jwt.secret=dev-secret-change-in-production
```

Dans une fenetre `watch kubectl get pods -n staging -o wide`, j'observe :
- Le pod `notification-service-xxx-yyy` existant reste en `1/1 Running`
- Un nouveau pod `notification-service-xxx-zzz` apparait en `Pending` puis `ContainerCreating`
- Apres ~5 secondes, il passe en `1/1 Running`
- Resultat : 2 pods notification-service en `1/1 Running`

### Rollback

```bash
helm rollback taskflow 1 -n staging
helm history taskflow -n staging
```

Sortie reelle de `helm history` :
```
REVISION  UPDATED                   STATUS      CHART          APP VERSION  DESCRIPTION
1         Tue May  5 14:53:24 2026  superseded  taskflow-0.1.0 1.0.0        Install complete
2         Tue May  5 15:00:21 2026  superseded  taskflow-0.1.0 1.0.0        Upgrade complete
3         Tue May  5 15:00:29 2026  deployed    taskflow-0.1.0 1.0.0        Rollback to 1
```

Apres rollback, le notification-service repasse a 1 replica, et l'historique cree une **revision 3** (le rollback est un upgrade vers l'etat d'une ancienne revision, pas une "annulation" de l'historique).

### Reflexion theorique — Historique des deploiements

**1. Ce que j'ai vu avec `watch kubectl get pods`**

Pendant l'upgrade : creation d'un 2eme pod notification-service en parallele du premier, sans interruption. Les deux ont coexiste en Running. Pas de Terminating sur l'ancien (puisqu'on ne le remplace pas — on en ajoute un).

Pendant le rollback : un des deux pods passe en Terminating, l'autre reste actif. Le service ne tombe jamais en dessous de 1 pod disponible.

**2. Information dans `helm history` absente de `kubectl rollout history`**

`helm history` montre :
- Le **chart version** (`taskflow-0.1.0`) qui a ete deploye
- L'**appVersion** (`1.0.0`)
- La **description** (`Install complete`, `Upgrade complete`, `Rollback to 1`)
- Le **status** (deployed, superseded, failed)
- L'**ensemble de la release** (toutes les ressources ensemble)

`kubectl rollout history` ne montre que les revisions d'**un seul Deployment** isolement. Aucune information sur la version du chart, la cause du changement, ou les autres ressources qui ont change en meme temps.

**Pourquoi c'est critique en production** : si on deploie une nouvelle version qui change a la fois le code (image.tag) et la config (un ConfigMap), `kubectl rollout history` n'a pas de vision globale. Helm sait que les deux changements vont ensemble et permet de rollback les deux d'un coup vers un etat coherent.

**3. `helm rollback taskflow 1` vs `kubectl rollout undo deployment/task-service`**

La difference fondamentale : **la portee**.

- `kubectl rollout undo deployment/task-service` rollback **un seul Deployment** a sa revision precedente. Si on a aussi change un ConfigMap, un Secret ou un autre Deployment, ils restent dans leur etat actuel. On peut se retrouver avec un `task-service v1.0.0` qui consomme un ConfigMap version v2 (pensee pour `task-service v1.0.1`), et ca explose.

- `helm rollback taskflow 1` rollback **toute la release** (Deployments, Services, ConfigMaps, Secrets, Ingress) vers l'etat de la revision 1. Toutes les ressources reviennent ensemble dans un etat coherent.

C'est pour ca que Helm pense en "release" (un ensemble coherent de ressources) plutot qu'en ressource isolee. En production, sans Helm, il faudrait scripter manuellement le rollback de chaque ressource liee, en s'assurant de l'ordre — Helm le fait automatiquement.

---

## Livrable

- Chart Helm complet sous `helm/taskflow/` avec :
  - `Chart.yaml` (avec dependance Bitnami Redis)
  - `values.yaml` (sans secret en clair)
  - `values.production.yaml` (sans secret en clair, secrets passes via `--set`)
  - 6 templates (postgres, user-service, task-service, notification-service, api-gateway, frontend, ingress)
- `helm dependency update` execute, sous-chart Redis telecharge
- Validation reussie : `helm lint`, `helm template`, deploiement sur le cluster kind
- Reponses theoriques aux 12 questions detaillees ci-dessus
