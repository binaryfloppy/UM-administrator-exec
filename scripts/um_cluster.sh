#!/usr/bin/env bash
# ==============================================================================
# Script autonome d'administration et de gestion du cluster Universal Messaging
#
# Genere automatiquement le : 2026-11-23 10:23:03
# Projet : Universal Messaging 12.1
#
# Ce script est completement autonome et ne depend que de :
#   - bash (>= 4.0 recommande)
#   - docker & docker compose
#   - curl
#   - coreutils (tar, sed, awk, grep)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Couleurs et journalisation
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
head()  { echo -e "${CYAN}${BOLD}=== $* ===${NC}"; }

# ------------------------------------------------------------------------------
# Configuration embarquee (surchargeable via variables d'environnement)
# ------------------------------------------------------------------------------
export CLUSTER_NAME="${CLUSTER_NAME:-umcluster}"
export JMS_CONNECTION_FACTORY="${JMS_CONNECTION_FACTORY:-local_um}"
export UM_IMAGE="${UM_IMAGE:-ibmwebmethods.azurecr.io/universalmessaging-server:12.1}"
export DOCKER_NETWORK="${DOCKER_NETWORK:-um_default}"
export COMPOSE_PROJECT="${COMPOSE_PROJECT:-um}"
export COMPOSE_FILE="${COMPOSE_FILE:-/Users/julien/.bob/playground/UM/docker-compose.yml}"
export VOLUME_PATTERN="${VOLUME_PATTERN:-{project}_{node}-{vol}}"
export BACKED_VOLUMES="${BACKED_VOLUMES:-data,conf}"
export BACKUP_DIR="${BACKUP_DIR:-/Users/julien/.bob/playground/UM/backups}"
export RUNNER="${RUNNER:-/opt/webmethods/UniversalMessaging/tools/runner/runUMTool.sh}"
export REALM_DIR="${REALM_DIR:-/opt/webmethods/UniversalMessaging/server/umserver}"
export UM_USERNAME="${UM_USERNAME:-}"
export UM_ADMIN_UM_PASSWORD="${UM_ADMIN_UM_PASSWORD:-}"

# Noeuds du cluster
NODE_NAMES=( "um1" "um2" "um3" )
NODE_CONTAINERS=( "um1" "um2" "um3" )
NODE_RNAMES=( "nsp://um1:9000" "nsp://um2:9000" "nsp://um3:9000" )
NODE_METRICS_URLS=( "http://um1:9200/metrics" "http://um2:9200/metrics" "http://um3:9200/metrics" )

# ------------------------------------------------------------------------------
# Fonctions utilitaires
# ------------------------------------------------------------------------------
check_docker() {
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
}

compose_cmd() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        err "Fichier docker-compose introuvable : $COMPOSE_FILE"
        exit 1
    fi
    local compose_dir
    compose_dir="$(dirname "$COMPOSE_FILE")"
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"
}

get_volume_name() {
    local node="$1"
    local vol="$2"
    local name="$VOLUME_PATTERN"
    name="${name//\{project\}/$COMPOSE_PROJECT}"
    name="${name//\{node\}/$node}"
    name="${name//\{vol\}/$vol}"
    echo "$name"
}

um_tool_cmd() {
    local container="$1"
    local rname="$2"
    local tool="$3"
    shift 3
    local cmd=(docker exec "$container" "$RUNNER" "$tool")
    if [ -n "$rname" ]; then
        cmd+=("-rname=$rname")
    fi
    if [ -n "$UM_USERNAME" ]; then
        cmd+=("-username=$UM_USERNAME" "-password=$UM_ADMIN_UM_PASSWORD")
    fi
    cmd+=("$@")
    "${cmd[@]}"
}

ensure_network() {
    if [ -z "$DOCKER_NETWORK" ]; then
        return 0
    fi
    if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        info "Creation du reseau Docker '$DOCKER_NETWORK'..."
        docker network create "$DOCKER_NETWORK"
        ok "Reseau Docker '$DOCKER_NETWORK' cree."
    fi
    for container in "${NODE_CONTAINERS[@]}"; do
        local st
        st="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "absent")"
        if [ "$st" = "running" ]; then
            if ! docker network inspect "$DOCKER_NETWORK" -f '{{range $k, $v := .Containers}}{{if eq $v.Name "'"$container"'"}}found{{end}}{{end}}' 2>/dev/null | grep -q "found"; then
                info "Connexion du conteneur '$container' au reseau '$DOCKER_NETWORK'..."
                docker network connect "$DOCKER_NETWORK" "$container" || true
            fi
        fi
    done
}

ensure_connection_factory() {
    if [ -z "$JMS_CONNECTION_FACTORY" ]; then
        info "Connection factory JMS : vide dans la configuration, non creee."
        return 0
    fi
    local first_container="${NODE_CONTAINERS[0]}"
    local first_rname="${NODE_RNAMES[0]}"
    local all_rnames
    all_rnames="$(IFS=,; echo "${NODE_RNAMES[*]}")"

    info "Verification de la connection factory JMS '$JMS_CONNECTION_FACTORY'..."
    if um_tool_cmd "$first_container" "$first_rname" ViewConnectionFactory "-factoryname=$JMS_CONNECTION_FACTORY" >/dev/null 2>&1; then
        ok "Connection factory JMS '$JMS_CONNECTION_FACTORY' deja presente."
        return 0
    fi

    info "Creation de la connection factory JMS '$JMS_CONNECTION_FACTORY' ($all_rnames)..."
    if um_tool_cmd "$first_container" "$first_rname" CreateConnectionFactory "-factoryname=$JMS_CONNECTION_FACTORY" "-connectionurl=$all_rnames"; then
        ok "Connection factory JMS '$JMS_CONNECTION_FACTORY' creee avec succes."
    else
        warn "Echec lors de la creation de la connection factory JMS (peut deja exister ou JNDI non pret)."
    fi
}

wait_healthy() {
    local timeout="${1:-240}"
    local end=$((SECONDS + timeout))
    info "Attente du demarrage des conteneurs..."
    while [ $SECONDS -lt $end ]; do
        local all_ready=1
        for container in "${NODE_CONTAINERS[@]}"; do
            local st
            st="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "absent")"
            if [ "$st" != "running" ]; then
                all_ready=0
                break
            fi
        done
        if [ $all_ready -eq 1 ]; then
            ok "Tous les conteneurs sont en marche."
            return 0
        fi
        sleep 3
    done
    err "Delai depasse : les conteneurs ne sont pas tous en marche."
    return 1
}

wait_formed() {
    local timeout="${1:-300}"
    local end=$((SECONDS + timeout))
    info "Attente de la formation du cluster '$CLUSTER_NAME' (1 Master + $((${#NODE_NAMES[@]} - 1)) Slave)..."
    while [ $SECONDS -lt $end ]; do
        local masters=0
        local slaves=0
        local status_str=""
        for i in "${!NODE_NAMES[@]}"; do
            local name="${NODE_NAMES[$i]}"
            local container="${NODE_CONTAINERS[$i]}"
            local role="Inconnu"
            local state_line
            state_line="$(docker exec "$container" curl -s -f -m 3 "http://localhost:9200/metrics" 2>/dev/null | grep -E '^sag_um_cluster_currentstate\{' || true)"
            if [[ "$state_line" =~ state=\"([^\"]+)\" ]]; then
                role="${BASH_REMATCH[1]}"
            fi
            if [ "$role" = "Master" ]; then
                masters=$((masters + 1))
            elif [ "$role" = "Slave" ]; then
                slaves=$((slaves + 1))
            fi
            status_str+="$name=$role "
        done
        printf "\r  Progression : %s" "$status_str"
        if [ "$masters" -eq 1 ] && [ "$slaves" -eq "$((${#NODE_NAMES[@]} - 1))" ]; then
            echo ""
            ok "Cluster forme avec succes : $status_str"
            return 0
        fi
        sleep 4
    done
    echo ""
    err "Le cluster ne s'est pas forme dans le delai imparti ($timeout s)."
    return 1
}

# ------------------------------------------------------------------------------
# Commande : STATUS
# ------------------------------------------------------------------------------
cmd_status() {
    head "Etat du cluster Universal Messaging"
    check_docker
    echo ""
    printf "%-10s %-12s %-10s %-22s %-20s\n" "NOEUD" "CONTENEUR" "ROLE" "RNAME" "METRIQUES"
    echo "--------------------------------------------------------------------------------"
    local masters=0
    local slaves=0
    for i in "${!NODE_NAMES[@]}"; do
        local name="${NODE_NAMES[$i]}"
        local container="${NODE_CONTAINERS[$i]}"
        local rname="${NODE_RNAMES[$i]}"
        local murl="${NODE_METRICS_URLS[$i]}"
        local c_status
        c_status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "absent")"
        local role="-"
        if [ "$c_status" = "running" ]; then
            local state_line
            state_line="$(docker exec "$container" curl -s -f -m 3 "http://localhost:9200/metrics" 2>/dev/null | grep -E '^sag_um_cluster_currentstate\{' || true)"
            if [[ "$state_line" =~ state=\"([^\"]+)\" ]]; then
                role="${BASH_REMATCH[1]}"
            fi
            if [ "$role" = "Master" ]; then masters=$((masters + 1)); fi
            if [ "$role" = "Slave" ]; then slaves=$((slaves + 1)); fi
        fi
        printf "%-10s %-12s %-10s %-22s %-20s\n" "$name" "$c_status" "$role" "$rname" "$murl"
    done
    echo "--------------------------------------------------------------------------------"
    if [ "$masters" -eq 1 ] && [ "$slaves" -eq "$((${#NODE_NAMES[@]} - 1))" ]; then
        ok "Etat du cluster : Forme (1 Master, $slaves Slave(s))"
    elif [ "$masters" -gt 0 ] || [ "$slaves" -gt 0 ]; then
        warn "Etat du cluster : Degrade ($masters Master, $slaves Slave)"
    else
        info "Etat du cluster : Aucun cluster forme"
    fi
}

# ------------------------------------------------------------------------------
# Commande : CREATE (Creer un nouveau cluster vierge)
# ------------------------------------------------------------------------------
cmd_create() {
    head "Creation du cluster Universal Messaging : $CLUSTER_NAME"
    check_docker

    local running_count=0
    local absent_count=0
    for container in "${NODE_CONTAINERS[@]}"; do
        local st
        st="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "absent")"
        if [ "$st" = "running" ]; then
            running_count=$((running_count + 1))
        else
            absent_count=$((absent_count + 1))
        fi
    done

    if [ "$running_count" -eq 0 ]; then
        info "Aucun conteneur en marche : recreation a neuf des conteneurs et des volumes..."
        compose_cmd down -v || true
        compose_cmd up -d
        ensure_network
        wait_healthy 240
    elif [ "$absent_count" -gt 0 ]; then
        err "Certains conteneurs sont arretes et d'autres tournent. Veuillez demarrer tous les conteneurs ou les arreter tous pour repartir a neuf."
        exit 1
    fi

    ensure_network

    local first_container="${NODE_CONTAINERS[0]}"
    local all_rnames
    all_rnames="$(IFS=,; echo "${NODE_RNAMES[*]}")"

    info "Execution de CreateCluster pour '$CLUSTER_NAME' sur $all_rnames..."
    um_tool_cmd "$first_container" "" CreateCluster "-clustername=$CLUSTER_NAME" "-convertlocal=true" "-rnames=$all_rnames"

    wait_formed 300
    ensure_connection_factory

    echo ""
    ok "Cluster '$CLUSTER_NAME' initialise et pret !"
}

# ------------------------------------------------------------------------------
# Commande : REBUILD (Reconstruire a partir d'une sauvegarde)
# ------------------------------------------------------------------------------
cmd_rebuild() {
    local backup_id="${1:-}"
    head "Reconstruction du cluster depuis une sauvegarde"
    check_docker

    if [ -z "$backup_id" ]; then
        info "Recherche des sauvegardes disponibles dans : $BACKUP_DIR"
        if [ ! -d "$BACKUP_DIR" ]; then
            err "Repertoire de sauvegarde introuvable : $BACKUP_DIR"
            exit 1
        fi
        local available_backups=( $(find "$BACKUP_DIR" -maxdepth 2 -name "manifest.json" | sort -r | awk -F/ '{print $(NF-1)}') )
        if [ ${#available_backups[@]} -eq 0 ]; then
            err "Aucune sauvegarde disponible dans $BACKUP_DIR"
            exit 1
        fi
        backup_id="${available_backups[0]}"
        info "Aucune sauvegarde specifiee en parametre, utilisation de la plus recente : $backup_id"
    fi

    local target_dir="$BACKUP_DIR/$backup_id"
    local manifest_file="$target_dir/manifest.json"

    if [ ! -f "$manifest_file" ]; then
        err "Manifest de sauvegarde introuvable : $manifest_file"
        exit 1
    fi

    info "Validation de la sauvegarde : $backup_id"
    info "Contenu du dossier de sauvegarde : $target_dir"

    IFS=',' read -r -a vols_to_restore <<< "$BACKED_VOLUMES"
    for name in "${NODE_NAMES[@]}"; do
        for vol in "${vols_to_restore[@]}"; do
            local tar_file="$target_dir/$name-$vol.tar"
            if [ ! -f "$tar_file" ]; then
                err "Archive manquante pour le noeud $name volume $vol : $tar_file"
                exit 1
            fi
        done
    done
    ok "Toutes les archives de sauvegarde sont presentes."

    info "Etape 1/4 : Suppression des conteneurs et volumes actuels..."
    compose_cmd down -v

    info "Etape 2/4 : Recreation des conteneurs et volumes (sans demarrage)..."
    compose_cmd up --no-start

    info "Etape 3/4 : Restauration des archives tar dans les volumes Docker..."
    for name in "${NODE_NAMES[@]}"; do
        for vol in "${vols_to_restore[@]}"; do
            local vol_name
            vol_name="$(get_volume_name "$name" "$vol")"
            local tar_name="$name-$vol.tar"
            info "  Restauration de $tar_name -> volume $vol_name..."
            docker run --rm --user 0 --entrypoint sh \
                -v "$vol_name:/v" -v "$target_dir:/b:ro" "$UM_IMAGE" \
                -c "find /v -mindepth 1 -delete && tar xpf /b/$tar_name --numeric-owner -C /v"
        done
    done
    ok "Restauration des volumes terminee."

    info "Etape 4/4 : Demarrage des conteneurs..."
    compose_cmd up -d
    ensure_network

    wait_formed 360
    ensure_connection_factory

    echo ""
    ok "Reconstruction terminee avec succes a partir de la sauvegarde $backup_id !"
}

# ------------------------------------------------------------------------------
# Commande : BACKUP (Sauvegarde a froid ou a chaud)
# ------------------------------------------------------------------------------
cmd_backup() {
    local mode="${1:-froid}"
    head "Sauvegarde du cluster Universal Messaging (mode : $mode)"
    check_docker

    mkdir -p "$BACKUP_DIR"
    local bid
    bid="$(date +%Y%m%d-%H%M%S)"
    local target_dir="$BACKUP_DIR/$bid"
    mkdir -p "$target_dir"

    IFS=',' read -r -a vols_to_backup <<< "$BACKED_VOLUMES"

    if [ "$mode" = "chaud" ]; then
        info "Sauvegarde a chaud (roulante, noeud par noeud)..."
        for name in "${NODE_NAMES[@]}"; do
            info "  Arret temporaire du noeud $name..."
            docker stop "$name"
            for vol in "${vols_to_backup[@]}"; do
                local vol_name
                vol_name="$(get_volume_name "$name" "$vol")"
                local tar_name="$name-$vol.tar"
                info "    Archivage volume $vol_name -> $tar_name..."
                docker run --rm --user 0 --entrypoint tar \
                    -v "$vol_name:/v:ro" -v "$target_dir:/b" "$UM_IMAGE" \
                    cpf "/b/$tar_name" --numeric-owner -C /v .
            done
            info "  Redemarrage du noeud $name..."
            docker start "$name"
            wait_formed 120
        done
    else
        info "Sauvegarde a froid (arret des conteneurs pour coherence)..."
        compose_cmd stop
        for name in "${NODE_NAMES[@]}"; do
            for vol in "${vols_to_backup[@]}"; do
                local vol_name
                vol_name="$(get_volume_name "$name" "$vol")"
                local tar_name="$name-$vol.tar"
                info "  Archivage volume $vol_name -> $tar_name..."
                docker run --rm --user 0 --entrypoint tar \
                    -v "$vol_name:/v:ro" -v "$target_dir:/b" "$UM_IMAGE" \
                    cpf "/b/$tar_name" --numeric-owner -C /v .
            done
        done
        info "Redemarrage des conteneurs..."
        compose_cmd start
        wait_formed 180
    fi

    # Creation du manifest
    cat <<EOF > "$target_dir/manifest.json"
{
  "id": "$bid",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "mode": "$mode",
  "cluster_name": "$CLUSTER_NAME"
}
EOF

    ok "Sauvegarde $bid enregistree dans : $target_dir"
}

# ------------------------------------------------------------------------------
# Commande : HELP
# ------------------------------------------------------------------------------
cmd_help() {
    echo -e "${BOLD}USAGE${NC}"
    echo -e "  $0 <commande> [options]"
    echo ""
    echo -e "${BOLD}DESCRIPTION${NC}"
    echo -e "  Script autonome pour gerer, creer, sauvegarder et reconstruire le cluster"
    echo -e "  webMethods Universal Messaging (UM) 12.1."
    echo ""
    echo -e "${BOLD}COMMANDES DISPONIBLES${NC}"
    echo -e "  ${GREEN}create${NC}"
    echo -e "      Cree un nouveau cluster vierge '$CLUSTER_NAME'."
    echo -e "      Si tous les conteneurs sont arretes, supprime et recree a neuf les conteneurs"
    echo -e "      et leurs volumes (docker compose down -v / up -d), puis lance CreateCluster"
    echo -e "      et configure la connection factory JMS '$JMS_CONNECTION_FACTORY'."
    echo ""
    echo -e "  ${GREEN}rebuild${NC} [ID_SAUVEGARDE]"
    echo -e "      Reconstruit le cluster a partir d'une sauvegarde tar existante."
    echo -e "      Si aucun ID n'est specifie, la sauvegarde la plus recente dans '$BACKUP_DIR' est utilisee."
    echo -e "      Supprime conteneurs et volumes, restaure les archives data et conf, puis redemarre."
    echo ""
    echo -e "  ${GREEN}status${NC}"
    echo -e "      Affiche l'etat courant des conteneurs, le role de chaque noeud (Master/Slave),"
    echo -e "      l'URL des metriques et l'etat global du cluster."
    echo ""
    echo -e "  ${GREEN}backup${NC} [froid|chaud]"
    echo -e "      Cree une sauvegarde tar de chaque volume configure ($BACKED_VOLUMES)."
    echo -e "      - froid (defaut) : arrete tous les noeuds pendant l'archivage (service interrompu)."
    echo -e "      - chaud : procede noeud par noeud en maintenant le quorum du cluster."
    echo ""
    echo -e "  ${GREEN}help${NC}, ${GREEN}--help${NC}, ${GREEN}-h${NC}"
    echo -e "      Affiche cette aide detaillee."
    echo ""
    echo -e "${BOLD}VARIABLES D'ENVIRONNEMENT (SURCHARGE)${NC}"
    echo -e "  Toutes les proprietes peuvent etre surchargees lors de l'appel du script :"
    echo -e "  - CLUSTER_NAME             Nom du cluster (defaut : $CLUSTER_NAME)"
    echo -e "  - JMS_CONNECTION_FACTORY   Nom de la factory JMS JNDI (defaut : $JMS_CONNECTION_FACTORY)"
    echo -e "  - COMPOSE_FILE             Chemin du docker-compose.yml (defaut : $COMPOSE_FILE)"
    echo -e "  - COMPOSE_PROJECT          Nom du projet Compose (defaut : $COMPOSE_PROJECT)"
    echo -e "  - BACKUP_DIR               Dossier des sauvegardes (defaut : $BACKUP_DIR)"
    echo -e "  - DOCKER_NETWORK           Nom du reseau Docker (defaut : $DOCKER_NETWORK)"
    echo -e "  - UM_IMAGE                 Image Docker UM (defaut : $UM_IMAGE)"
    echo -e "  - UM_ADMIN_UM_PASSWORD     Mot de passe administrateur UM si configure"
    echo ""
    echo -e "${BOLD}EXEMPLES${NC}"
    echo -e "  # Afficher l'etat du cluster"
    echo -e "  $0 status"
    echo ""
    echo -e "  # Creer un nouveau cluster"
    echo -e "  $0 create"
    echo ""
    echo -e "  # Reconstruire a partir d'une sauvegarde specifique"
    echo -e "  $0 rebuild 20261118-104005"
    echo ""
    echo -e "  # Reconstruire avec la derniere sauvegarde disponible"
    echo -e "  $0 rebuild"
    echo ""
    echo -e "  # Effectuer une sauvegarde a froid"
    echo -e "  $0 backup froid"
    echo ""
    echo -e "  # Surcharger le nom du cluster a la volee"
    echo -e "  CLUSTER_NAME=mon_cluster $0 create"
}

# ------------------------------------------------------------------------------
# Point d'entree principal
# ------------------------------------------------------------------------------
action="${1:-help}"
case "$action" in
    create|create-cluster|--create)
        cmd_create
        ;;
    rebuild|--rebuild)
        shift || true
        cmd_rebuild "${1:-}"
        ;;
    status|--status)
        cmd_status
        ;;
    backup|--backup)
        shift || true
        cmd_backup "${1:-froid}"
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        err "Commande inconnue : $action"
        echo ""
        cmd_help
        exit 1
        ;;
esac
