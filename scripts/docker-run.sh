#!/usr/bin/env bash
# Generate docker run commands for WeSense services
# Usage: ./scripts/docker-run.sh [persona|service]
#
# Examples:
#   ./scripts/docker-run.sh station       # Show all commands for station persona
#   ./scripts/docker-run.sh contributor   # Show commands for contributor persona
#   ./scripts/docker-run.sh emqx          # Show command for specific service
#   ./scripts/docker-run.sh               # Show usage
#
# This script is useful for:
#   - Unraid (which doesn't support docker-compose)
#   - Manual deployments
#   - Understanding what docker-compose does under the hood
#
# See Deployment_Personas.md for full persona details

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if it exists
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# Default values (matching .env.sample defaults)
TZ="${TZ:-Pacific/Auckland}"
DATA_DIR="${DATA_DIR:-./data}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Ports
PORT_MQTT="${PORT_MQTT:-1883}"
PORT_MQTT_TLS="${PORT_MQTT_TLS:-8883}"
PORT_RESPIRO="${PORT_RESPIRO:-3000}"
PORT_TTN_WEBHOOK="${PORT_TTN_WEBHOOK:-5000}"

# TLS
TLS_MQTT_ENABLED="${TLS_MQTT_ENABLED:-false}"
TLS_WS_ENABLED="${TLS_WS_ENABLED:-false}"
TLS_CERTFILE="${TLS_CERTFILE:-/opt/emqx/etc/certs/fullchain.pem}"
TLS_KEYFILE="${TLS_KEYFILE:-/opt/emqx/etc/certs/privkey.pem}"

# ClickHouse
CLICKHOUSE_DB="${CLICKHOUSE_DB:-wesense}"
CLICKHOUSE_ADMIN_PASSWORD="${CLICKHOUSE_ADMIN_PASSWORD:-}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-wesense}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_BATCH_SIZE="${CLICKHOUSE_BATCH_SIZE:-100}"
CLICKHOUSE_FLUSH_INTERVAL="${CLICKHOUSE_FLUSH_INTERVAL:-10}"

# MQTT
MQTT_HOST="${MQTT_HOST:-emqx}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
EMQX_DASHBOARD_PASSWORD="${EMQX_DASHBOARD_PASSWORD:-public}"

# Ingesters
DEBUG="${DEBUG:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TTN_WEBHOOK_ENABLED="${TTN_WEBHOOK_ENABLED:-false}"
TTN_WEBHOOK_PORT="${TTN_WEBHOOK_PORT:-5000}"
HA_URL="${HA_URL:-http://homeassistant.local:8123}"
HA_ACCESS_TOKEN="${HA_ACCESS_TOKEN:-}"
HA_NODE_NAME="${HA_NODE_NAME:-}"
DISABLE_CLICKHOUSE="${DISABLE_CLICKHOUSE:-false}"

# Classifier
CLASSIFIER_SCHEDULE="${CLASSIFIER_SCHEDULE:-0 */12 * * *}"
CLASSIFIER_RUN_ON_STARTUP="${CLASSIFIER_RUN_ON_STARTUP:-true}"
CLASSIFIER_DRY_RUN="${CLASSIFIER_DRY_RUN:-false}"

# Images
INGESTER_MESHTASTIC_IMAGE="${INGESTER_MESHTASTIC_IMAGE:-ghcr.io/wesense-earth/wesense-ingester-meshtastic:latest}"
INGESTER_WESENSE_IMAGE="${INGESTER_WESENSE_IMAGE:-ghcr.io/wesense-earth/wesense-ingester-wesense:latest}"
INGESTER_HA_IMAGE="${INGESTER_HA_IMAGE:-ghcr.io/wesense-earth/wesense-ingester-homeassistant:latest}"
RESPIRO_IMAGE="${RESPIRO_IMAGE:-ghcr.io/wesense-earth/wesense-respiro:latest}"
CLASSIFIER_IMAGE="${CLASSIFIER_IMAGE:-ghcr.io/wesense-earth/wesense-deployment-classifier:latest}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}# ========================================${NC}"
    echo -e "${BLUE}# $1${NC}"
    echo -e "${BLUE}# ========================================${NC}"
}

print_network() {
    echo -e "${YELLOW}# Create network first (if not exists):${NC}"
    echo "docker network create wesense-net 2>/dev/null || true"
    echo ""
}

generate_emqx() {
    print_header "EMQX - MQTT Broker"
    cat << EOF
docker run -d \\
  --name wesense-emqx \\
  --network wesense-net \\
  --restart unless-stopped \\
  --user 0:0 \\
  --entrypoint /opt/emqx/scripts/init-auth.sh \\
  -p ${PORT_MQTT}:1883 \\
  -v ${DATA_DIR}/emqx/data:/opt/emqx/data \\
  -v ${DATA_DIR}/emqx/log:/opt/emqx/log \\
  -v ${PROJECT_DIR}/certs:/opt/emqx/etc/certs:ro \\
  -v ${PROJECT_DIR}/emqx/etc/emqx.conf:/opt/emqx/etc/emqx.conf:ro \\
  -v ${PROJECT_DIR}/emqx/scripts/init-auth.sh:/opt/emqx/scripts/init-auth.sh:ro \\
  -e PUID=${PUID} \\
  -e PGID=${PGID} \\
  -e MQTT_USER=${MQTT_USER} \\
  -e MQTT_PASSWORD=${MQTT_PASSWORD} \\
  -e EMQX_DASHBOARD__DEFAULT_PASSWORD=${EMQX_DASHBOARD_PASSWORD} \\
  -e EMQX_LISTENERS__SSL__DEFAULT__ENABLED=${TLS_MQTT_ENABLED} \\
  -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__CERTFILE=${TLS_CERTFILE} \\
  -e EMQX_LISTENERS__SSL__DEFAULT__SSL_OPTIONS__KEYFILE=${TLS_KEYFILE} \\
  -e EMQX_LISTENERS__WSS__DEFAULT__ENABLED=${TLS_WS_ENABLED} \\
  -e EMQX_LISTENERS__WSS__DEFAULT__SSL_OPTIONS__CERTFILE=${TLS_CERTFILE} \\
  -e EMQX_LISTENERS__WSS__DEFAULT__SSL_OPTIONS__KEYFILE=${TLS_KEYFILE} \\
  -e TZ=${TZ} \\
  emqx/emqx:5.8.9 \\
  /opt/emqx/bin/emqx foreground
EOF
    echo ""
}

generate_clickhouse() {
    print_header "ClickHouse - Time Series Database"
    cat << EOF
docker run -d \\
  --name wesense-clickhouse \\
  --network wesense-net \\
  --restart unless-stopped \\
  -v ${CLICKHOUSE_DATA_DIR:-${DATA_DIR}/clickhouse}/data:/var/lib/clickhouse \\
  -v ${CLICKHOUSE_DATA_DIR:-${DATA_DIR}/clickhouse}/logs:/var/log/clickhouse-server \\
  -v ${PROJECT_DIR}/clickhouse/init:/docker-entrypoint-initdb.d:ro \\
  -e CLICKHOUSE_DB=${CLICKHOUSE_DB} \\
  -e CLICKHOUSE_USER=default \\
  -e CLICKHOUSE_PASSWORD=${CLICKHOUSE_ADMIN_PASSWORD} \\
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \\
  -e CLICKHOUSE_APP_USER=${CLICKHOUSE_USER} \\
  -e CLICKHOUSE_APP_PASSWORD=${CLICKHOUSE_PASSWORD} \\
  -e TZ=${TZ} \\
  --cap-add SYS_NICE \\
  --ulimit nproc=65535 \\
  --ulimit nofile=262144:262144 \\
  clickhouse/clickhouse-server:24
EOF
    echo ""
}

generate_ingester_meshtastic() {
    print_header "Meshtastic Ingester (community mode)"
    cat << EOF
docker run -d \\
  --name wesense-ingester-meshtastic \\
  --network wesense-net \\
  --restart unless-stopped \\
  -v ${DATA_DIR}/ingester-meshtastic/cache:/app/cache \\
  -v ${DATA_DIR}/ingester-meshtastic/logs:/app/logs \\
  -e MQTT_BROKER=${MQTT_HOST} \\
  -e MQTT_PORT=${MQTT_PORT} \\
  -e MQTT_USERNAME=${MQTT_USER} \\
  -e MQTT_PASSWORD=${MQTT_PASSWORD} \\
  -e CLICKHOUSE_HOST=${CLICKHOUSE_HOST} \\
  -e CLICKHOUSE_PORT=${CLICKHOUSE_PORT} \\
  -e CLICKHOUSE_DATABASE=${CLICKHOUSE_DB} \\
  -e CLICKHOUSE_USER=${CLICKHOUSE_USER} \\
  -e CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} \\
  -e CLICKHOUSE_BATCH_SIZE=${CLICKHOUSE_BATCH_SIZE} \\
  -e CLICKHOUSE_FLUSH_INTERVAL=${CLICKHOUSE_FLUSH_INTERVAL} \\
  -e WESENSE_OUTPUT_BROKER=${MQTT_HOST} \\
  -e WESENSE_OUTPUT_PORT=${MQTT_PORT} \\
  -e WESENSE_OUTPUT_USERNAME=${MQTT_USER} \\
  -e WESENSE_OUTPUT_PASSWORD=${MQTT_PASSWORD} \\
  -e DEBUG=${DEBUG} \\
  -e LOG_LEVEL=${LOG_LEVEL} \\
  -e TZ=${TZ} \\
  ${INGESTER_MESHTASTIC_IMAGE}
EOF
    echo ""
}

generate_ingester_meshtastic_downlink() {
    print_header "Meshtastic Downlink Ingester (global — hub operators only)"
    cat << EOF
docker run -d \\
  --name wesense-meshtastic-downlink \\
  --network wesense-net \\
  --restart unless-stopped \\
  -v ${DATA_DIR}/ingester-meshtastic-downlink/cache:/app/cache \\
  -v ${DATA_DIR}/ingester-meshtastic-downlink/logs:/app/logs \\
  -v ${PROJECT_DIR}/ingester-meshtastic-downlink/config:/app/config:ro \\
  -e MESHTASTIC_MODE=downlink \\
  -e CLICKHOUSE_HOST=${CLICKHOUSE_HOST} \\
  -e CLICKHOUSE_PORT=${CLICKHOUSE_PORT} \\
  -e CLICKHOUSE_DATABASE=${CLICKHOUSE_DB} \\
  -e CLICKHOUSE_USER=${CLICKHOUSE_USER} \\
  -e CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} \\
  -e CLICKHOUSE_BATCH_SIZE=${CLICKHOUSE_BATCH_SIZE} \\
  -e CLICKHOUSE_FLUSH_INTERVAL=${CLICKHOUSE_FLUSH_INTERVAL} \\
  -e WESENSE_OUTPUT_BROKER=${MQTT_HOST} \\
  -e WESENSE_OUTPUT_PORT=${MQTT_PORT} \\
  -e WESENSE_OUTPUT_USERNAME=${MQTT_USER} \\
  -e WESENSE_OUTPUT_PASSWORD=${MQTT_PASSWORD} \\
  -e DEBUG=${DEBUG} \\
  -e LOG_LEVEL=${LOG_LEVEL} \\
  -e TZ=${TZ} \\
  ${INGESTER_MESHTASTIC_IMAGE}
EOF
    echo ""
}

generate_ingester_wesense() {
    print_header "WeSense Ingester (WiFi + LoRa + TTN webhook)"
    cat << EOF
docker run -d \\
  --name wesense-ingester-wesense \\
  --network wesense-net \\
  --restart unless-stopped \\
  -v ${DATA_DIR}/ingester-wesense/cache:/app/cache \\
  -v ${DATA_DIR}/ingester-wesense/logs:/app/logs \\
  -e MQTT_BROKER=${MQTT_HOST} \\
  -e MQTT_PORT=${MQTT_PORT} \\
  -e MQTT_USERNAME=${MQTT_USER} \\
  -e MQTT_PASSWORD=${MQTT_PASSWORD} \\
  -e CLICKHOUSE_HOST=${CLICKHOUSE_HOST} \\
  -e CLICKHOUSE_PORT=${CLICKHOUSE_PORT} \\
  -e CLICKHOUSE_DATABASE=${CLICKHOUSE_DB} \\
  -e CLICKHOUSE_USER=${CLICKHOUSE_USER} \\
  -e CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} \\
  -e CLICKHOUSE_BATCH_SIZE=${CLICKHOUSE_BATCH_SIZE} \\
  -e CLICKHOUSE_FLUSH_INTERVAL=${CLICKHOUSE_FLUSH_INTERVAL} \\
  -e WESENSE_OUTPUT_BROKER=${MQTT_HOST} \\
  -e WESENSE_OUTPUT_PORT=${MQTT_PORT} \\
  -e WESENSE_OUTPUT_USERNAME=${MQTT_USER} \\
  -e WESENSE_OUTPUT_PASSWORD=${MQTT_PASSWORD} \\
  -e TTN_WEBHOOK_ENABLED=${TTN_WEBHOOK_ENABLED} \\
  -e TTN_WEBHOOK_PORT=${TTN_WEBHOOK_PORT} \\
  -e DEBUG=${DEBUG} \\
  -e TZ=${TZ} \\
  ${INGESTER_WESENSE_IMAGE}
EOF
    echo ""
}

generate_ingester_homeassistant() {
    print_header "Home Assistant Ingester"
    cat << EOF
docker run -d \\
  --name wesense-ingester-homeassistant \\
  --network wesense-net \\
  --restart on-failure \\
  -v ${PROJECT_DIR}/ingester-homeassistant/config:/app/config:ro \\
  -v ${DATA_DIR}/ingester-homeassistant/logs:/app/logs \\
  -e HA_URL=${HA_URL} \\
  -e HA_ACCESS_TOKEN=${HA_ACCESS_TOKEN} \\
  -e NODE_NAME=${HA_NODE_NAME} \\
  -e CLICKHOUSE_HOST=${CLICKHOUSE_HOST} \\
  -e CLICKHOUSE_PORT=${CLICKHOUSE_PORT} \\
  -e CLICKHOUSE_DATABASE=${CLICKHOUSE_DB} \\
  -e CLICKHOUSE_USER=${CLICKHOUSE_USER} \\
  -e CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} \\
  -e LOCAL_MQTT_BROKER=${MQTT_HOST} \\
  -e LOCAL_MQTT_PORT=${MQTT_PORT} \\
  -e DISABLE_CLICKHOUSE=${DISABLE_CLICKHOUSE} \\
  -e LOG_LEVEL=${LOG_LEVEL} \\
  -e TZ=${TZ} \\
  ${INGESTER_HA_IMAGE}
EOF
    echo ""
}

generate_respiro() {
    print_header "Respiro - Environmental Sensor Map"
    cat << EOF
docker run -d \\
  --name wesense-respiro \\
  --network wesense-net \\
  --restart unless-stopped \\
  -p ${PORT_RESPIRO}:3000 \\
  -v ${DATA_DIR}/respiro:/app/data \\
  -e CLICKHOUSE_HOST=${CLICKHOUSE_HOST} \\
  -e CLICKHOUSE_PORT=${CLICKHOUSE_PORT} \\
  -e CLICKHOUSE_DATABASE=${CLICKHOUSE_DB} \\
  -e CLICKHOUSE_USERNAME=${CLICKHOUSE_USER} \\
  -e CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} \\
  -e MQTT_BROKER_URL=mqtt://${MQTT_HOST}:${MQTT_PORT} \\
  -e MQTT_USERNAME=${MQTT_USER} \\
  -e MQTT_PASSWORD=${MQTT_PASSWORD} \\
  -e MQTT_TOPIC_FILTER=wesense/decoded/# \\
  -e PORT=3000 \\
  -e HOST=0.0.0.0 \\
  -e TZ=${TZ} \\
  ${RESPIRO_IMAGE}
EOF
    echo ""
}

generate_deployment_classifier() {
    print_header "Deployment Classifier"
    cat << EOF
docker run -d \\
  --name wesense-deployment-classifier \\
  --network wesense-net \\
  --restart unless-stopped \\
  -v ${DATA_DIR}/deployment-classifier/reports:/app/reports \\
  -v ${DATA_DIR}/deployment-classifier/logs:/app/logs \\
  -e CLICKHOUSE_HOST=http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT} \\
  -e CLICKHOUSE_USER=${CLICKHOUSE_USER} \\
  -e CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD} \\
  -e CLICKHOUSE_DATABASE=${CLICKHOUSE_DB} \\
  -e CLASSIFIER_MODE=scheduler \\
  -e CLASSIFIER_SCHEDULE="${CLASSIFIER_SCHEDULE}" \\
  -e RUN_ON_STARTUP=${CLASSIFIER_RUN_ON_STARTUP} \\
  -e DRY_RUN=${CLASSIFIER_DRY_RUN} \\
  -e TZ=${TZ} \\
  ${CLASSIFIER_IMAGE}
EOF
    echo ""
}

usage() {
    echo "Generate docker run commands for WeSense services"
    echo ""
    echo "Usage: $0 [persona|service]"
    echo ""
    echo "Personas:"
    echo "  contributor  - Ingesters only (sends to remote MQTT hub)"
    echo "  station      - Full local stack (EMQX + ClickHouse + Ingesters + Respiro + Classifier)"
    echo "  hub          - EMQX only (production mqtt.wesense.earth)"
    echo ""
    echo "Add-ons (combine with a persona):"
    echo "  downlink     - Global Meshtastic downlink (hub operators only)"
    echo ""
    echo "Services:"
    echo "  emqx                         - MQTT Broker"
    echo "  clickhouse                   - Time Series Database"
    echo "  ingester-meshtastic          - Meshtastic Ingester (community mode)"
    echo "  ingester-meshtastic-downlink - Meshtastic Downlink (global, hub operators only)"
    echo "  ingester-wesense             - WeSense Ingester (WiFi + LoRa + TTN)"
    echo "  ingester-homeassistant       - Home Assistant Ingester"
    echo "  respiro                      - Environmental Sensor Map"
    echo "  deployment-classifier        - Sensor Deployment Classifier"
    echo ""
    echo "Examples:"
    echo "  $0 station                   # All commands for station deployment"
    echo "  $0 station downlink          # Station + global Meshtastic downlink"
    echo "  $0 contributor               # Ingesters only"
    echo "  $0 emqx                      # Just EMQX command"
    echo "  $0 station > run-all.sh      # Save to script"
    echo ""
    exit 0
}

# Main — support multiple arguments (e.g., "station downlink")
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

first=true
for arg in "$@"; do
    case "$arg" in
        hub|contributor|station|downlink)
            if [ "$first" = true ]; then
                first=false
                echo "#!/bin/bash"
                echo "# WeSense deployment - docker run commands"
                echo "# Generated: $(date)"
                echo ""
                print_network
            fi
            case "$arg" in
                hub) generate_emqx ;;
                contributor)
                    generate_ingester_meshtastic
                    generate_ingester_wesense
                    generate_ingester_homeassistant
                    ;;
                station)
                    generate_emqx
                    generate_clickhouse
                    generate_ingester_meshtastic
                    generate_ingester_wesense
                    generate_ingester_homeassistant
                    generate_respiro
                    generate_deployment_classifier
                    ;;
                downlink)
                    generate_ingester_meshtastic_downlink
                    ;;
            esac
            ;;
        emqx)
            print_network; generate_emqx ;;
        clickhouse)
            print_network; generate_clickhouse ;;
        ingester-meshtastic)
            print_network; generate_ingester_meshtastic ;;
        ingester-meshtastic-downlink)
            print_network; generate_ingester_meshtastic_downlink ;;
        ingester-wesense)
            print_network; generate_ingester_wesense ;;
        ingester-homeassistant)
            print_network; generate_ingester_homeassistant ;;
        respiro)
            print_network; generate_respiro ;;
        deployment-classifier)
            print_network; generate_deployment_classifier ;;
        *)
            echo -e "${RED}Error: Unknown persona or service: $arg${NC}"
            echo ""
            usage
            ;;
    esac
done
