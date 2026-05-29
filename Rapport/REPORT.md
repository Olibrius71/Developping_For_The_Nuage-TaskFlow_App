# REPORT — TaskFlow Observabilite

## Partie 1 — Observer l'application dans Grafana

---

### A. Instrumentation et configuration

#### Instrumentation OpenTelemetry

Chaque service (api-gateway, user-service, task-service, notification-service) dispose d'un fichier `tracing.js` charge en tout premier dans `index.js` via `require("./tracing")`. Ce fichier :

1. **Initialise le SDK OpenTelemetry** avec `NodeSDK`
2. **Declare la ressource** avec `service.name` pour identifier chaque service dans les traces
3. **Configure l'export des traces** vers le OTel Collector en OTLP HTTP (`http://otel-collector:4318/v1/traces`)
4. **Active les auto-instrumentations** (Express, PostgreSQL, HTTP, Redis) via `getNodeAutoInstrumentations()`
5. **Gere le shutdown** proprement via `process.on('SIGTERM')` pour s'assurer que les traces en attente sont bien exportees

#### Pipeline OTel Collector

Le fichier `infra/otel/config.yml` configure :
- **Receivers** : OTLP en gRPC (port 4317) et HTTP (port 4318)
- **Processors** : `batch` pour regrouper les donnees avant export
- **Exporters** : `otlp/tempo` (gRPC vers Tempo:4317, plus performant) + `debug` (console pour le debogage)
- **Metriques internes** exposees sur le port 8888 pour Prometheus
- **Pipelines** : un pipeline `traces` et un pipeline `metrics`

#### Configuration Tempo

- API et UI exposees sur le port **3200** (utilise par Grafana pour interroger les traces)
- Ecoute gRPC sur le port **4317** pour recevoir les traces du Collector
- Stockage **local** (`/tmp/tempo/blocks`)
- **Write-Ahead Log** (WAL) configure dans `/tmp/tempo/wal` pour ne pas perdre les traces en cas de crash

#### Configuration Prometheus

- `scrape_interval` et `evaluation_interval` a 15s
- Scrape configs pour chaque service :
  - `prometheus` (localhost:9090)
  - `api-gateway` (api-gateway:3000)
  - `user-service` (user-service:3001)
  - `task-service` (task-service:3002)
  - `notification-service` (notification-service:3003)
  - `otel-collector` (otel-collector:8888) — metriques internes du Collector

#### Configuration Grafana

- Datasources auto-provisionnees : Prometheus, Tempo, Loki
- Dashboards auto-charges depuis `/var/lib/grafana/dashboards/`
- Variables d'environnement : `GF_SECURITY_ADMIN_PASSWORD=admin`, `GF_USERS_ALLOW_SIGN_UP=false`

---

### B. Visualisation

#### Metriques ajoutees

| Service | Metrique | Type | Labels |
|---|---|---|---|
| task-service | `tasks_created_total` | Counter | priority (low/medium/high) |
| task-service | `tasks_status_changes_total` | Counter | from_status, to_status |
| task-service | `tasks_gauge` | Gauge | status (todo/in_progress/done) |
| user-service | `user_registrations_total` | Counter | - |
| user-service | `user_login_attempts_total` | Counter | success (true/false) |
| api-gateway | `upstream_errors_total` | Counter | service (user-service, task-service, notification-service) |
| notification-service | `notifications_sent_total` | Counter | event_type (task.created, task.status_changed) |

#### Dashboards Grafana

**Dashboard 1 — Vue d'ensemble des services** (`services-overview.json`)
- Taux de requetes par service : `sum by(job) (rate(http_requests_total{route!="/metrics"}[5m]))`
- Latence p50/p95/p99 : `histogram_quantile(0.50|0.95|0.99, sum by(job, le) (rate(http_request_duration_ms_bucket[5m])))`
- Taux d'erreurs 5xx : `sum by(job) (rate(http_requests_total{status=~"5.."}[5m]))`
- Statut des services : metrique `up`

**Dashboard 2 — Metriques metier TaskFlow** (`business-metrics.json`)
- Taches creees par minute : `sum(rate(tasks_created_total[5m])) * 60`
- Repartition par priorite (pie chart) : `sum by(priority) (tasks_created_total)`
- Transitions de statut/min : `sum by(from_status, to_status) (rate(tasks_status_changes_total[5m])) * 60`
- Connexions reussies vs echouees : `sum by(success) (rate(user_login_attempts_total[5m])) * 60`

#### Traces

##### Scenario : POST /api/tasks depuis le frontend

En faisant une requete POST `/api/tasks` depuis le frontend, on peut retrouver la trace dans **Grafana > Explore > Tempo**.

La chaine de spans observee :
1. **api-gateway** : `POST /api/tasks` — le gateway recoit la requete et la proxie vers le task-service
2. **task-service** : `POST /tasks` — le service traite la requete
3. **task-service > postgres** : `INSERT INTO tasks ...` — requete SQL d'insertion
4. **task-service** : `publish.task.created` — span custom autour de la publication Redis

**Attributs observes :**
- `http.method` : methode HTTP (POST)
- `http.route` : route matchee (/tasks)
- `http.status_code` : code de reponse (201)
- `db.statement` : requete SQL executee (INSERT INTO tasks ...)
- `db.system` : systeme de base de donnees (postgresql)
- `net.peer.name` : hote de la base de donnees

##### Span custom

Un span manuel `publish.task.created` a ete ajoute dans `task-service/src/routes.js` autour de la publication Redis lors de la creation d'une tache. De meme, `publish.task.status_changed` est ajoute lors du changement de statut.

Ce span est visible dans la vue distribuee de la trace dans Grafana, permettant de mesurer le temps de publication Redis.

---

### C. Logs

#### Configuration Promtail + Loki

**Promtail** (`infra/promtail/promtail-config.yml`) :
- URL de Loki : `http://loki:3100/loki/api/v1/push`
- Parsing JSON Pino pour extraire `level` et `msg`
- Conversion des niveaux numeriques Pino en strings : 30=info, 40=warn, 50=error

**Loki** (`infra/loki/loki-config.yml`) :
- `path_prefix: /loki`
- `chunks_directory: /loki/chunks`, `rules_directory: /loki/rules`
- Store: `tsdb` (moteur d'index le plus recent recommande par Loki)
- Object store: `filesystem`
- Schema: `v13`

#### Visualisation des logs

**Filtrer les logs du task-service :**
```logql
{container=~".*task-service.*"}
```

La syntaxe LogQL utilise des label matchers `{label="value"}` comme Prometheus, mais la difference est que LogQL filtre des lignes de logs (flux de texte) tandis que PromQL interroge des series temporelles numeriques.

**Retrouver une erreur (ex: tache sans title) :**
```logql
{container=~".*task-service.*"} | json | level="error"
```
ou plus specifiquement :
```logql
{container=~".*task-service.*"} |= "title is required"
```

**Logs de niveau error sur tous les services :**
```logql
{container=~".+"} | json | level="error"
```

**Requetes ayant retourne un 500 :**
```logql
{container=~".+"} | json | statusCode >= 500
```

#### Comparaison Prometheus vs Loki pour les erreurs 500

- **Prometheus** : `http_requests_total{status="500"}` — donne le nombre exact d'erreurs, optimise pour les alertes et les graphiques temporels. Plus adapte pour le monitoring en temps reel et les alertes.
- **Loki** : `{container=~".+"} | json | statusCode >= 500` — donne le detail de chaque requete en erreur (message, stack trace, contexte). Plus adapte pour le diagnostic et l'investigation.

**Laquelle est la plus adaptee ?** Prometheus est plus adapte pour la **detection** (alerting, dashboards). Loki est plus adapte pour l'**investigation** (comprendre pourquoi une erreur s'est produite). Les deux sont complementaires : Prometheus pour detecter, Loki pour diagnostiquer.

#### Correlation trace/logs

**Peut-on retrouver un traceId dans les logs Loki ?**
Par defaut, les traceIds ne sont pas automatiquement injectes dans les logs Pino. Pour que ce soit automatique, il faudrait configurer la **log correlation** en ajoutant un hook Pino qui extrait le traceId du contexte OpenTelemetry actif et l'ajoute a chaque ligne de log. Cela permettrait ensuite dans Grafana de passer directement d'un log a la trace correspondante.

#### Demarche d'investigation lors d'un pic d'erreurs

1. **METRIQUES (Prometheus)** : Observer le dashboard "Vue d'ensemble des services" pour identifier quel service presente un pic d'erreurs 5xx et a quel moment.
2. **LOGS (Loki)** : Filtrer les logs d'erreur sur le service et la periode identifiee :
   ```logql
   {container=~".*<service>.*"} | json | level="error"
   ```
   Lire les messages d'erreur pour comprendre la cause (ex: "Cannot connect to database", "timeout", etc.)
3. **TRACES (Tempo)** : Rechercher les traces en erreur sur ce service :
   ```traceql
   { resource.service.name = "<service>" && status = error }
   ```
   La vue waterfall permet de localiser exactement quel appel dans la chaine a echoue (ex: service-a -> service-b -> database timeout 5s).
