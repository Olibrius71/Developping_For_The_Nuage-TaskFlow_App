# Grille d'évaluation — TaskFlow TP Cloud & DevOps

**Travail en binôme**

Doit être rendu sous la forme d'un **repository GitHub** accompagné de :
- un **README** : installation, architecture, démarrage
- un **REPORT.md** : réponses théoriques, observations, captures d'écran, démarche d'investigation

La note finale est calculée sur **100 points**.

> **Périmètre d'évaluation**
> La logique métier de TaskFlow est fournie — elle n'est pas évaluée.
> Ce qui est évalué : l'observabilité (logs, métriques, instrumentation, stack OTel/Prometheus/Tempo/Grafana/Loki), le déploiement Kubernetes (manifests YAML, choix d'architecture, comportements du cluster) et le packaging Helm (chart, values, gestion des secrets, cycle de vie).

---

# 1. Fonctionnement global du projet

| Critère | Description |
|---|---|
| Stack d'observabilité opérationnelle | L'ensemble de la stack (OTel Collector, Prometheus, Tempo, Grafana, Loki) démarre et fonctionne correctement |
| Données visibles dans Grafana | Les métriques, logs et traces remontent bien jusqu'à Grafana et sont exploitables |
| Stack Kubernetes opérationnelle | Le cluster kind démarre, tous les Pods passent en `1/1 Running` dans le namespace `staging` |
| Application accessible via Ingress | Le frontend est accessible sur `http://localhost`, l'API répond sur `/api/health`, et la création de compte fonctionne |
| Infrastructure reproductible | La stack peut être lancée sur une machine externe en suivant uniquement le README |
| Stabilité | La stack fonctionne de manière reproductible sans manipulation imprévue |
| Chart Helm opérationnel | `helm upgrade --install` réussit sans erreur, tous les Pods passent en `1/1 Running` dans le namespace `staging` via Helm |

---

# 2. Implémentation technique

| Critère | Description |
|---|---|
| Qualité des logs | Les logs sont structurés, exploitables, et les niveaux sont utilisés de façon cohérente |
| Pertinence des métriques | Les métriques ajoutées permettent d'observer efficacement le comportement de l'application |
| Pipeline d'observabilité | Les données transitent correctement de l'application jusqu'à Grafana |
| Dashboards | Les dashboards Grafana sont lisibles, pertinents et versionnés dans le repo |
| Traces distribuées | Les traces couvrent plusieurs services et incluent des spans custom là où c'est justifié |
| Complétude des manifests | Tous les services sont couverts : postgres, redis, user-service, task-service, notification-service, api-gateway, frontend, ingress |
| Configuration de l'Ingress | Les routes sont correctement définies et fonctionnelles |
| Complétude du chart Helm | Tous les services sont couverts dans les templates Helm, la dépendance Redis Bitnami est correctement déclarée dans `Chart.yaml` et téléchargée |
| Gestion des valeurs et des secrets | `values.yaml` et `values.production.yaml` présents et bien structurés — aucun secret en clair dans les fichiers committés, les valeurs sensibles sont passées séparément au déploiement |

---

# 3. README et documentation

| Critère | Description |
|---|---|
| Notice d'installation | Instructions claires pour lancer l'ensemble de la stack (observabilité et Kubernetes) étape par étape |
| Guide d'observation | Étapes permettant d'observer les comportements dans Grafana — comment retrouver une trace, filtrer des logs, lire un dashboard |
| Guide de déploiement Helm | Instructions claires pour installer le chart (`helm dependency update`, `helm upgrade --install`), passer les secrets au déploiement, et vérifier l'état de la release |

---

# 4. REPORT.md — Compréhension et analyse

| Critère | Description |
|---|---|
| Réponses théoriques | Réponses structurées, argumentées, montrant une compréhension réelle des outils |
| Observations et preuves | Les conclusions sont étayées par des preuves concrètes — captures Grafana, captures terminal, chiffres précis — pas d'affirmations sans justification |
| Analyse des résultats | Les comportements observés sont interprétés, mis en perspective, et les limites des outils sont identifiées quand elles sont pertinentes |
| Justification des choix | Les décisions de configuration prises sont expliquées et cohérentes |
| Scénarios d'observation Kubernetes | Documentés avec des observations concrètes et une analyse de ce que chaque comportement révèle |

---

# 5. Qualité du code et rigueur Git

| Critère | Description |
|---|---|
| Qualité du code d'observabilité | Tout le code relevant de l'observabilité est lisible et cohérent — logs dans les routes et middlewares, `tracing.js`, `metrics.js`, endpoint `/metrics`, configs infra — sans gestion d'erreurs silencieuse |
| Qualité des manifests Kubernetes | Les manifests sont lisibles, sans duplication inutile, et organisés dans une arborescence cohérente sous `k8s/base/` |
| Organisation Git | Les commits sont atomiques et les messages clairs |
| Qualité du chart Helm | Les templates sont lisibles et cohérents, `values.yaml` est complet, l'arborescence `helm/taskflow/` est propre et versionnée |

---

# Pénalités possibles

| Situation | Pénalité |
|---|---|
| Stack d'observabilité impossible à lancer | -20 |
| Données non visibles dans Grafana | -20 |
| Stack Kubernetes impossible à lancer | -20 |
| Application inaccessible via Ingress | -10 |
| README absent ou incomplet | -15 |
| Fichiers sensibles committés (.env, tokens, secrets) | -30 |
| Chart Helm impossible à installer | -15 |

---

# Barème final

| Note | Interprétation |
|---|---|
| 90–100 | Travail excellent, compréhension solide |
| 75–89 | Travail maîtrisé |
| 60–74 | Compréhension partielle |
| <60 | Objectifs non atteints |