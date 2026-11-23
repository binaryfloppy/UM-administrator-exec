#!/usr/bin/env bash
# ==============================================================================
# Script de deploiement pour le projet Universal Messaging (UM) 12.1
#
# Usage :
#   ./deploy.sh [fichier_de_conf]
#
# Exemple :
#   ./deploy.sh deploy.conf
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

CONF_FILE="${1:-deploy.conf}"

echo -e "${BLUE}===================================================================${NC}"
echo -e "${BLUE}  Deploiement du Cluster Universal Messaging 12.1 & um_admin      ${NC}"
echo -e "${BLUE}===================================================================${NC}"

# 1. Chargement de la configuration
if [ -f "$CONF_FILE" ]; then
    info "Chargement de la configuration depuis : $CONF_FILE"
    # shellcheck source=/dev/null
    source "$CONF_FILE"
else
    warn "Fichier de configuration '$CONF_FILE' introuvable, utilisation des valeurs par defaut."
fi

# Valeurs par defaut si non definies
export UM_ADMIN_IMAGE="${UM_ADMIN_IMAGE:-um_admin:latest}"
export UM_IMAGE="${UM_IMAGE:-ibmwebmethods.azurecr.io/universalmessaging-server:12.1}"
export CLUSTER_NAME="${CLUSTER_NAME:-umcluster}"
export DOCKER_NETWORK="${DOCKER_NETWORK:-um_default}"
export UM1_PORT="${UM1_PORT:-2001}"
export UM2_PORT="${UM2_PORT:-2002}"
export UM3_PORT="${UM3_PORT:-2003}"
export UM_ADMIN_PORT="${UM_ADMIN_PORT:-8088}"
export PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
export UM_ADMIN_UM_PASSWORD="${UM_ADMIN_UM_PASSWORD:-}"
export UM_HOST_DIR="$SCRIPT_DIR"

# 2. Verification des prerequis
info "Verification des prerequis Docker..."
if ! command -v docker >/dev/null 2>&1; then
    err "La commande 'docker' est introuvable. Veuillez installer Docker."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    err "Le daemon Docker n'est pas accessible. Verifiez que Docker est demarre."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    err "Le plugin 'docker compose' est introuvable."
    exit 1
fi
ok "Prerequis Docker valides."

# 3. Creation du reseau Docker si absent
info "Verification du reseau Docker : $DOCKER_NETWORK"
if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    info "Creation du reseau Docker '$DOCKER_NETWORK'..."
    docker network create "$DOCKER_NETWORK"
    ok "Reseau Docker '$DOCKER_NETWORK' cree."
else
    ok "Reseau Docker '$DOCKER_NETWORK' present."
fi

# 4. Lancement des conteneurs UM (um1, um2, um3)
info "Demarrage des 3 noeuds Universal Messaging (um1, um2, um3)..."
docker compose -p um -f docker-compose.yml up -d
ok "Conteneurs UM lances."

# 5. Attente de la disponibilite des noeuds UM
info "Attente de la disponibilite des noeuds UM sur les ports $UM1_PORT, $UM2_PORT, $UM3_PORT..."
for node_info in "um1:$UM1_PORT" "um2:$UM2_PORT" "um3:$UM3_PORT"; do
    node="${node_info%%:*}"
    port="${node_info##*:}"
    printf "  Attente de %s (port %s)... " "$node" "$port"
    ready=0
    for _ in $(seq 1 40); do
        if curl -s -f -m 2 "http://127.0.0.1:$port/health/" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 2
    done
    if [ "$ready" -eq 1 ]; then
        echo -e "${GREEN}pret${NC}"
    else
        echo -e "${YELLOW}en cours de demarrage (timeout d'attente)${NC}"
    fi
done

# 6. Lancement du conteneur d'administration (um_admin)
if [ -f "um_admin/Dockerfile" ]; then
    info "Dockerfile detecte : construction de l'image $UM_ADMIN_IMAGE..."
    docker build -t "$UM_ADMIN_IMAGE" -f um_admin/Dockerfile .
    ok "Image $UM_ADMIN_IMAGE construite."
elif docker image inspect "$UM_ADMIN_IMAGE" >/dev/null 2>&1; then
    ok "Image $UM_ADMIN_IMAGE disponible localement."
elif [ -f "um_admin.tar" ]; then
    info "Archive 'um_admin.tar' detectee : chargement de l'image $UM_ADMIN_IMAGE..."
    docker load -i um_admin.tar
    ok "Image $UM_ADMIN_IMAGE chargee depuis l'archive."
else
    info "Tentative de telechargement de l'image $UM_ADMIN_IMAGE..."
    docker pull "$UM_ADMIN_IMAGE" || warn "Impossible de telecharger $UM_ADMIN_IMAGE (tentative via docker compose)."
fi

info "Demarrage du conteneur um_admin ($UM_ADMIN_IMAGE)..."
docker compose -p um_admin -f docker-compose.um_admin.yml up -d
ok "Conteneur um_admin demarre."

# 7. Attente de l'IHM
info "Attente de l'interface d'administration sur http://127.0.0.1:$UM_ADMIN_PORT..."
ui_ready=0
for _ in $(seq 1 20); do
    if curl -s -f -m 2 "http://127.0.0.1:$UM_ADMIN_PORT/api/status" >/dev/null 2>&1; then
        ui_ready=1
        break
    fi
    sleep 2
done

if [ "$ui_ready" -eq 1 ]; then
    ok "Interface d'administration prete."
else
    warn "L'IHM est encore en cours d'initialisation."
fi

# 8. Resume
echo ""
echo -e "${GREEN}===================================================================${NC}"
echo -e "${GREEN}  Deploiement termine avec succes !                                ${NC}"
echo -e "${GREEN}===================================================================${NC}"
echo -e "  - IHM Administration : ${BLUE}http://localhost:${UM_ADMIN_PORT}${NC}"
echo -e "  - Prometheus         : ${BLUE}http://localhost:${PROMETHEUS_PORT}${NC}"
echo -e "  - Noeuds UM (nhp)    : um1: ${BLUE}localhost:${UM1_PORT}${NC} | um2: ${BLUE}localhost:${UM2_PORT}${NC} | um3: ${BLUE}localhost:${UM3_PORT}${NC}"
echo -e "  - Reseau Docker      : ${BLUE}${DOCKER_NETWORK}${NC}"
echo -e "${GREEN}===================================================================${NC}"
echo -e "Pour initialiser le cluster vierge, ouvrez ${BLUE}http://localhost:${UM_ADMIN_PORT}${NC} et cliquez sur ${YELLOW}« Creer le cluster »${NC}."
echo ""
