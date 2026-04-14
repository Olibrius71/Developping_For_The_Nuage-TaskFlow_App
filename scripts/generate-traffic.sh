#!/bin/bash

BASE_URL="${1:-http://localhost:3000}"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "========================================="
echo "  TaskFlow - Generateur de trafic"
echo "  Target: $BASE_URL"
echo "========================================="
echo ""

# --- Health check ---
echo -e "${YELLOW}[1/10] Health check${NC}"
curl -s "$BASE_URL/health" | python3 -m json.tool
echo ""

# --- Inscription reussie ---
EMAIL="traffic-$(date +%s)@test.com"
echo -e "${GREEN}[2/10] Inscription reussie ($EMAIL)${NC}"
curl -s -X POST "$BASE_URL/api/users/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"test123\",\"name\":\"Traffic User\"}"
echo -e "\n"

# --- Inscription en erreur (champs manquants) ---
echo -e "${RED}[3/10] Inscription en erreur - champs manquants (400)${NC}"
curl -s -X POST "$BASE_URL/api/users/register" \
  -H "Content-Type: application/json" \
  -d '{"email":"incomplete@test.com"}'
echo -e "\n"

# --- Inscription en erreur (email duplique) ---
echo -e "${RED}[4/10] Inscription en erreur - email duplique (409)${NC}"
curl -s -X POST "$BASE_URL/api/users/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"test123\",\"name\":\"Duplicate\"}"
echo -e "\n"

# --- Login reussi ---
echo -e "${GREEN}[5/10] Login reussi${NC}"
LOGIN_RESPONSE=$(curl -s -X POST "$BASE_URL/api/users/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"test123\"}")
TOKEN=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null)
echo "$LOGIN_RESPONSE" | python3 -m json.tool 2>/dev/null
echo ""

if [ -z "$TOKEN" ]; then
  echo -e "${RED}Impossible de recuperer le token. Arret.${NC}"
  exit 1
fi

# --- Login en erreur (mauvais password) ---
echo -e "${RED}[6/10] Login en erreur - mauvais password (401)${NC}"
curl -s -X POST "$BASE_URL/api/users/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"wrong\"}"
echo -e "\n"

# --- Requete sans token ---
echo -e "${RED}[7/10] Requete sans token (401)${NC}"
curl -s "$BASE_URL/api/tasks"
echo -e "\n"

# --- Creation de taches (differentes priorites) ---
echo -e "${GREEN}[8/10] Creation de taches (high, medium, low)${NC}"
for PRIO in high medium low; do
  RESPONSE=$(curl -s -X POST "$BASE_URL/api/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"title\":\"Tache $PRIO - $(date +%H:%M:%S)\",\"priority\":\"$PRIO\",\"description\":\"Tache de test generee automatiquement\"}")
  TASK_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
  echo "  $PRIO -> id: $TASK_ID"
done
echo ""

# --- Creation en erreur (sans title) ---
echo -e "${RED}[8b/10] Creation tache sans title (400)${NC}"
curl -s -X POST "$BASE_URL/api/tasks" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"description":"no title"}'
echo -e "\n"

# --- Creation en erreur (priority invalide -> 500) ---
echo -e "${RED}[8c/10] Creation tache priority invalide (500)${NC}"
curl -s -X POST "$BASE_URL/api/tasks" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"title":"Bad priority","priority":"urgent"}'
echo -e "\n"

# --- Changements de statut ---
echo -e "${GREEN}[9/10] Changements de statut (todo -> in_progress -> done)${NC}"
TASK_RESPONSE=$(curl -s -X POST "$BASE_URL/api/tasks" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"title":"Tache lifecycle","priority":"high"}')
LIFECYCLE_ID=$(echo "$TASK_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
echo "  Tache creee: $LIFECYCLE_ID"

curl -s -X PATCH "$BASE_URL/api/tasks/$LIFECYCLE_ID" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"status":"in_progress"}' > /dev/null
echo "  todo -> in_progress"

curl -s -X PATCH "$BASE_URL/api/tasks/$LIFECYCLE_ID" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"status":"done"}' > /dev/null
echo "  in_progress -> done"
echo ""

# --- Lecture tache inexistante (404) ---
echo -e "${RED}[9b/10] Tache inexistante (404)${NC}"
curl -s "$BASE_URL/api/tasks/00000000-0000-0000-0000-000000000000" \
  -H "Authorization: Bearer $TOKEN"
echo -e "\n"

# --- Lecture des notifications ---
echo -e "${GREEN}[10/10] Lecture des notifications${NC}"
curl -s "$BASE_URL/api/notifications" \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool 2>/dev/null | head -30
echo ""

# --- Rafale de requetes pour generer du volume ---
echo -e "${YELLOW}[Bonus] Rafale de 20 requetes GET /api/tasks${NC}"
for i in $(seq 1 20); do
  curl -s "$BASE_URL/api/tasks" -H "Authorization: Bearer $TOKEN" > /dev/null
done
echo "  20 requetes envoyees"
echo ""

echo "========================================="
echo -e "${GREEN}  Trafic genere avec succes !${NC}"
echo "  Attendez ~15s puis verifiez Grafana"
echo "========================================="
