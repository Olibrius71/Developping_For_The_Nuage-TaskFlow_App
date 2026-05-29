# REPORT 2 — Stress test avec k6

## Contexte et demarche

### Objectif

L'objectif de cette partie est d'observer le comportement de TaskFlow sous charge croissante, d'identifier les goulots d'etranglement et de comprendre les limites du scaling avec Docker Compose. On combine les resultats de k6 (latence end-to-end cote client) avec les dashboards Grafana (metriques internes des services en temps reel).

### Outils utilises

- **k6** : outil de test de charge open-source de Grafana
- **Grafana** : dashboards "Vue d'ensemble des services" et "Metriques metier" (partie 1)
- **Prometheus** : collecte des metriques des 4 services toutes les 15 secondes
- **Docker Compose** : orchestration locale des services et test de scaling

### Mise en place

La stack applicative et la stack d'observabilité -> Partie 1.

Pour les tests k6, deux scripts etaient fournis dans le projet :

1. **`scripts/load-test-light.js`** : scenario leger avec 5 utilisateurs virtuels (VUs) pendant 30 secondes. Chaque VU fait un `GET /api/tasks` par seconde. Permet de valider que l'application repond correctement sous faible charge.

2. **`scripts/load-test-realistic.js`** : scenario realiste simulant un vrai parcours utilisateur en 4 etapes :
   - Login (`POST /api/users/login`) -> user-service
   - Lister les taches (`GET /api/tasks`) -> task-service
   - Creer une tache (`POST /api/tasks`) -> task-service
   - Lire les notifications (`GET /api/notifications`) -> notification-service

   Ce script monte progressivement la charge (10 VUs pendant 1m30, puis spike a 50 VUs pendant 1m30, puis descente).

### Deroulement des tests

1. **Test leger** : on recupere un token JWT via login, puis on lance k6 avec 5 VUs. On verifie que tout passe a 100%.

2. **Test realiste (50 VUs)** : on lance le scenario complet avec les stages par defaut. On observe Grafana en parallele pour voir le trafic monter sur chaque service.

3. **Test sous forte charge (200 VUs)** : on relance le script realiste en forcant 200 VUs constants pendant 60 secondes (`--vus 200 --duration 60s`) pour trouver le point de rupture.

4. **Test de scaling** : on tente `docker compose up --scale task-service=3` pour voir si le scaling horizontal ameliore les performances. On observe l'erreur de port, on la contourne, puis on verifie dans Prometheus combien de targets sont detectees.

---

## Etape 1 — Test leger (5 VUs, 30s)

### Commande

```bash
k6 run -e TOKEN=<token> -e BASE_URL=http://localhost:3000 scripts/load-test-light.js
```

### Resume k6

```
checks_succeeded...: 100.00% 300 out of 300
checks_failed......: 0.00%   0 out of 300

  tasks status 200
  tasks response < 200ms

http_req_duration..: avg=19.03ms min=3.7ms med=20.39ms max=44.3ms p(90)=27.37ms p(95)=32.49ms
http_req_failed....: 0.00%  0 out of 150
http_reqs..........: 150    4.902025/s
```

### Question 1 — Quelle est la latence p95 affichee par k6 pendant ce test leger ? Est-elle dans les seuils acceptables (< 200ms) ?

La latence p95 mesuree par k6 est de **32.49ms**. C'est largement dans le seuil acceptable de 200ms. La mediane est a 20ms et le max a 44ms. Avec seulement 5 utilisateurs virtuels, l'application repond tres rapidement sans aucune degradation.

### Question 2 — Le taux `http_req_failed` est-il a 0 % ? Si non, quel code d'erreur observez-vous ?

Oui, `http_req_failed` est a **0.00%** (0 sur 150 requetes). Tous les checks passent a 100%. Aucune erreur HTTP n'est observee. L'application gere sans probleme 5 utilisateurs simultanesqui envoient ~5 req/s.

---

## Etape 2 — Test realiste (montee progressive jusqu'a 50 VUs)

### Commande

```bash
k6 run -e EMAIL=test@test.com -e PASSWORD=test123 -e BASE_URL=http://localhost:3000 scripts/load-test-realistic.js
```

### Resume k6 (scenario par defaut : 10 -> 50 VUs sur 3m30)

```
checks_succeeded...: 100.00% 12684 out of 12684
checks_failed......: 0.00%   0 out of 12684

  login 200
  tasks 200
  tasks response < 500ms
  create task 201
  notifs 200
  notifs response < 500ms

http_req_duration..: avg=21.33ms min=1.38ms med=12.5ms max=92.25ms p(90)=51.02ms p(95)=55.41ms
http_req_failed....: 0.00%  0 out of 8456
http_reqs..........: 8456   39.844069/s
```

### Resume k6 (200 VUs constant pendant 60s)

```
checks_succeeded...: 90.38% 17250 out of 19084
checks_failed......: 9.61%  1834 out of 19084

  login 200                       100%
  tasks 200                        93% (194 echecs)
  tasks response < 500ms           59% (1295 echecs)
  create task 201                  90% (291 echecs)
  notifs 200                      100%
  notifs response < 500ms          98% (54 echecs)

http_req_duration..: avg=363.4ms min=1.57ms med=104.89ms max=1m0s p(90)=1.1s p(95)=1.69s
http_req_failed....: 3.81%  485 out of 12726
http_reqs..........: 12726  141.395966/s
```

### Question 3 — A partir de quel stade le check `tasks response < 500ms` commence-t-il a echouer massivement ? Quelle est la p95 finale ?

A **50 VUs**, le test passe encore a 100% (p95 = 55ms). C'est en poussant a **200 VUs** que la degradation devient massive :

- Le check `tasks response < 500ms` tombe a **59%** — soit 1295 requetes depassant le seuil de 500ms.
- La **p95 finale est de 1.69s** (contre 55ms a 50 VUs, soit une multiplication par 30).
- La latence moyenne passe de 21ms a 363ms, et le max atteint **60 secondes** (timeout).
- Le taux d'echec HTTP passe de 0% a **3.81%** (485 requetes echouees).

Le point de rupture se situe entre 50 et 200 VUs. Les services tiennent bien jusqu'a 50 utilisateurs simultanesmaiscedent sous la charge au-dela.

### Question 4 — Dans Grafana, l'api-gateway recoit ~2x plus de trafic que le task-service et ~4x plus que le user-service. Pourquoi ?

En analysant le script `load-test-realistic.js`, chaque iteration d'un VU effectue **4 requetes HTTP** qui passent toutes par l'api-gateway :

1. `POST /api/users/login` -> **user-service** (1 requete)
2. `GET /api/tasks` -> **task-service** (1 requete)
3. `POST /api/tasks` -> **task-service** (1 requete)
4. `GET /api/notifications` -> **notification-service** (1 requete)

L'**api-gateway** recoit donc **4 requetes par iteration** (100% du trafic passe par lui).
Le **task-service** en recoit **2 par iteration** (GET + POST).
Le **user-service** en recoit **1 par iteration** (login seulement).
Le **notification-service** en recoit **1 par iteration** (GET notifications).

D'ou les ratios observes dans Grafana : gateway ~4x, task-service ~2x, user-service ~1x, notification-service ~1x.

### Question 5 — Pourquoi le task-service est-il plus impacte que le user-service ou le notification-service sous forte charge ?

Le task-service est plus impacte pour plusieurs raisons :

1. **Volume de requetes** : il recoit 2 requetes par iteration (le double du user-service et du notification-service).
2. **Operations couteuses en base de donnees** : chaque `POST /tasks` fait un `INSERT` en PostgreSQL, et chaque `GET /tasks` fait un `SELECT * FROM tasks ORDER BY created_at DESC` qui scanne une table qui grossit a chaque iteration. Plus le test dure, plus cette table est volumineuse.
3. **Publication Redis** : chaque creation de tache declenche un `publish()` Redis pour notifier le notification-service, ajoutant de la latence I/O.
4. **Operations en ecriture** : les INSERT sont plus couteux que les SELECT car ils doivent ecrire sur disque, mettre a jour les index, et respecter les contraintes d'integrite.

En comparaison, le user-service ne fait qu'un `SELECT` (login) et le notification-service travaille en memoire (pas de DB).

---

## Etape 3 — Docker scale

### Question 6 — Que se passe-t-il avec `docker compose up --scale task-service=3` ? Quelle erreur et pourquoi ?

L'erreur obtenue est :

```
Error response from daemon: failed to set up container networking:
driver failed programming external connectivity on endpoint [...]:
Bind for 0.0.0.0:3002 failed: port is already allocated
```

**Cause** : dans `docker-compose.yml`, le task-service declare `ports: - "3002:3002"`. Ce mapping lie le port 3002 de l'hote au port 3002 du container. Quand Docker tente de creer un 2eme replica, il essaie de binder le meme port hote 3002, ce qui echoue car il est deja utilise par le 1er replica.

**La ligne responsable** est :
```yaml
ports:
  - "3002:3002"
```

### Contournement

On remplace `ports` par `expose` pour que les containers soient accessibles sur le reseau Docker interne sans mapper un port hote fixe :

```yaml
expose:
  - "3002"
```

Apres ce changement, `docker compose up --scale task-service=3` fonctionne : les 3 containers demarrent sans conflit de port.

### Question 7 — Le scaling a-t-il ameliore les metriques ? Les 3 replicas recoivent-ils du trafic ?

**Non, le scaling n'ameliore pas les metriques** car :

1. **L'api-gateway pointe vers `task-service:3002`** : Docker Compose utilise un DNS pour resoudre `task-service`, mais les connexions HTTP keep-alive font que le gateway reutilise la meme connexion TCP, envoyant tout le trafic au meme replica.

2. **Prometheus ne voit qu'une seule target** : sur http://localhost:9090/targets, le job `task-service` n'affiche qu'une seule target `task-service:3002`. La config Prometheus utilise `static_configs` avec une target fixe. Il ne peut pas decouvrir dynamiquement les 3 replicas car :
   - Le DNS `task-service` ne resout que vers une IP a la fois
   - Prometheus n'a pas de mecanisme de service discovery Docker configure
   - Les 3 replicas ecoutent sur le meme port interne 3002, mais Prometheus ne connait pas leurs IPs individuelles

### Question 8 — Pourquoi `docker scale` ne suffit pas pour un scaling propre en production ?

`docker scale` presente plusieurs limitations fondamentales :

1. **Pas de load balancing intelligent** : le DNS de Docker est aleatoire et ne prend pas en compte la charge reelle de chaque replica. Avec keep-alive, un seul replica peut recevoir tout le trafic.

2. **Pas de service discovery** : Prometheus et les autres outils de monitoring ne decouvrent pas automatiquement les nouveaux replicas. La configuration est statique.

3. **Pas de health checking avance** : Docker ne retire pas automatiquement un replica defaillant du pool de trafic.

4. **Pas de rolling update** : lors d'un deploiement, `docker scale` ne gere pas le remplacement progressif des containers sans downtime.

5. **Limite a une seule machine** : `docker compose` ne peut pas repartir les replicas sur plusieurs serveurs.

---

## Etape 4 — Limites de l'instrumentation

### Question 9 — Le panel Error Rate 5xx affiche "No data" alors que k6 signale des erreurs. Pourquoi ?

Le panel Error Rate 5xx filtre sur `http_requests_total{status=~"5.."}`. Sous forte charge, les erreurs mesurees par k6 ne sont pas des erreurs HTTP 500 retournees par les services. Ce sont principalement :

- Des **timeouts de connexion** : le serveur ne repond pas dans le delai imparti. La requete n'arrive jamais au service, donc aucun code HTTP n'est genere.
- Des **connexions refusees** (ECONNREFUSED/ECONNRESET) : l'OS refuse la connexion TCP car le backlog est sature. La requete n'atteint jamais Express, donc aucune metrique n'est enregistree.
- Des **erreurs au niveau du proxy** (502/504) de l'api-gateway quand le service downstream ne repond pas.

Le middleware Prometheus dans nos services ne voit que les requetes qui arrivent effectivement jusqu'a Express. Les requetes qui echouent au niveau reseau (timeout, connexion refusee) ne sont jamais comptabilisees.


### Question 10 — Le panel Latency p50/p95/p99 reste flat alors que k6 mesure une p95 bien superieure. D'ou vient cet ecart ?

Le panel Latency utilise `histogram_quantile(0.95, sum by(job, le) (rate(http_request_duration_ms_bucket[5m])))`. Cette metrique mesure le temps de traitement **interne au service** c'est-a-dire le temps entre le moment ou Express recoit la requete et le moment ou il envoie la reponse.

Ce panel **mesure** le temps de traitement applicatif une fois la requete acceptee par Node.js

Ce que ce panel **ne mesure pas** :
- Le temps d'attente dans la queue TCP avant que Node.js accepte la connexion
- Le temps de transit reseau entre k6 et le container
- Les requetes qui ne sont jamais arrivees (timeout, connexion refusee)
- Le temps de passage par l'api-gateway (proxy overhead)

k6 mesure la latence **end-to-end** (du client au client), tandis que Prometheus mesure la latence **interne au service**. Sous forte charge, l'essentiel du temps est passe a attendre dans la queue TCP, ce qui explique l'ecart.