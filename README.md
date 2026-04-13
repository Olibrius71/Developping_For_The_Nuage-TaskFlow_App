# TaskFlow — TP Cloud & DevOps

Architecture multi-services pour apprendre Kubernetes, l'observabilite et le CI/CD.

## Architecture

```
                    ┌──────────────┐
                    │   Frontend   │ :5173
                    └──────┬───────┘
                           │
                    ┌──────┴───────┐
                    │ API Gateway  │ :3000
                    └──┬─────┬──┬──┘
                       │     │  │
          ┌────────────┘     │  └────────────┐
          │                  │               │
   ┌──────┴───────┐  ┌──────┴──────┐  ┌─────┴──────────────┐
   │ User Service  │  │ Task Service│  │Notification Service│
   │    :3001      │  │   :3002     │  │      :3003         │
   └──────┬────────┘  └──┬─────┬───┘  └─────┬──────────────┘
          │               │     │            │
     ┌────┴────┐     ┌───┴───┐ │       ┌────┴────┐
     │PostgreSQL│     │  PG   │ │       │  Redis  │
     │  :5432   │     │       │ └───────┤  :6379  │
     └─────────┘     └───────┘         └─────────┘
```

## Services applicatifs

| Service | Port | Role |
|---|---|---|
| api-gateway | 3000 | Point d'entree unique, auth JWT, proxy vers les services |
| user-service | 3001 | Gestion des utilisateurs (register, login) |
| task-service | 3002 | CRUD des taches, publication d'evenements Redis |
| notification-service | 3003 | Reception des evenements via Redis Pub/Sub |
| frontend | 5173 | Interface React (Vite) |

## Stack d'observabilite

| Outil | Port | Role |
|---|---|---|
| OTel Collector | 4317 (gRPC), 4318 (HTTP), 8888 (metrics) | Reception et routage des traces et metriques |
| Tempo | 3200 | Stockage des traces distribuees |
| Prometheus | 9090 | Collecte et stockage des metriques |
| Loki | 3100 | Agregation des logs |
| Promtail | 9080 | Collecte des logs Docker et envoi vers Loki |
| Grafana | 3050 | Visualisation (metriques, logs, traces) |

## Prerequisites

- Docker & Docker Compose
- Node.js 20+
- npm

## Installation et demarrage

### 1. Installer les dependances

```bash
npm run install:all
```

### 2. Lancer la stack applicative

```bash
docker compose up -d --build
```

Cela demarre : PostgreSQL, Redis, les 4 services backend et le frontend.

### 3. Lancer la stack d'observabilite

# TODO PROBLEME DE DROIT, IL FAUT ESSAYER DE LANCER LE TRUC EN ADMIN
```bash
docker compose -f docker-compose.infra.yml up -d
```

Cela demarre : OTel Collector, Tempo, Prometheus, Loki, Promtail et Grafana.

### 4. Verifier que tout fonctionne

- Frontend : http://localhost:5173
- API Gateway : http://localhost:3000/health
- Grafana : http://localhost:3050 (admin / admin)
- Prometheus : http://localhost:9090
- Tempo : http://localhost:3200

## Guide d'observation dans Grafana

### Consulter les metriques

1. Ouvrir Grafana (http://localhost:3050)
2. Aller dans **Dashboards**
3. Deux dashboards sont pre-configures :
   - **Vue d'ensemble des services** : taux de requetes, latence p50/p95/p99, taux d'erreurs, statut des services
   - **Metriques metier TaskFlow** : taches creees/min, repartition par priorite, transitions de statut, tentatives de connexion

### Consulter les traces

1. Aller dans **Explore** > Selectionner la datasource **Tempo**
2. Utiliser TraceQL pour chercher :
   - `{ resource.service.name = "task-service" }` : tous les spans du task-service
   - `{ span.http.method = "POST" }` : toutes les requetes POST
   - `{ status = error }` : tous les spans en erreur
3. Cliquer sur une trace pour voir la vue waterfall (chaine de spans)

### Consulter les logs

1. Aller dans **Explore** > Selectionner la datasource **Loki**
2. Exemples de requetes LogQL :
   - `{container=~".*task-service.*"}` : logs du task-service
   - `{container=~".+"}  | json | level="error"` : tous les logs d'erreur
   - `{container=~".+"}  | json | statusCode >= 500` : toutes les requetes 500

### Correlation metriques / logs / traces

1. **Metriques** (Prometheus) : detecter un pic d'erreurs via le dashboard
2. **Logs** (Loki) : filtrer les logs d'erreur sur la periode concernee pour comprendre la cause
3. **Traces** (Tempo) : retrouver la trace exacte pour voir la chaine d'appels et identifier le service defaillant

## Structure du projet

```
.
├── api-gateway/          # Service API Gateway
├── user-service/         # Service utilisateurs
├── task-service/         # Service taches
├── notification-service/ # Service notifications
├── frontend/             # Interface React
├── infra/
│   ├── otel/             # Config OTel Collector
│   ├── tempo/            # Config Tempo
│   ├── prometheus/        # Config Prometheus
│   ├── loki/             # Config Loki
│   ├── promtail/         # Config Promtail
│   └── grafana/
│       ├── provisioning/ # Datasources et dashboards auto-provisiones
│       └── dashboards/   # JSON des dashboards Grafana
├── scripts/              # Scripts SQL, tests de charge
├── docker-compose.yml          # Stack applicative
└── docker-compose.infra.yml    # Stack d'observabilite
```

## Arret des services

```bash
# Arreter la stack applicative
docker compose down

# Arreter la stack d'observabilite
docker compose -f docker-compose.infra.yml down

# Supprimer les volumes (donnees)
docker compose down -v
docker compose -f docker-compose.infra.yml down -v
```
