#!/bin/bash
# migrate-from-docker-run.sh — Migrate from old docker-run setup to new docker-compose
#
# Migrates ClickHouse data and Meshtastic ingester caches.
# Handles the database rename: sensormap → wesense_respiro
#
# Usage:
#   ./scripts/migrate-from-docker-run.sh export   # Step 1: while old ClickHouse is still running
#   ./scripts/migrate-from-docker-run.sh import   # Step 2: after new docker compose stack is up
#
# Between steps:
#   1. Stop old containers
#   2. Configure .env (copy from .env.sample, set passwords)
#   3. docker compose --profile station up -d
#   4. Wait for ClickHouse to be healthy
#
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./migration-backup}"
OLD_CH_URL="${OLD_CH_URL:-http://localhost:8123}"

# Old Meshtastic ingester cache paths (from docker-run setup)
OLD_CACHE_COMMUNITY="${OLD_CACHE_COMMUNITY:-/mnt/ssd1pool/docker2/wesense-ingester-meshtastic-community/cache}"
OLD_CACHE_DOWNLINK="${OLD_CACHE_DOWNLINK:-/mnt/ssd1pool/docker2/wesense-ingester-meshtastic/cache}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "==> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

check_clickhouse_http() {
    local url="$1" user="$2" pass="$3"
    local response
    response=$(curl -sf "${url}/?user=${user}&password=${pass}" --data-binary "SELECT 1" --connect-timeout 5 2>&1) || return 1
    [ "$response" = "1" ]
}

# ---------------------------------------------------------------------------
# EXPORT — run while old ClickHouse is still up
# ---------------------------------------------------------------------------
do_export() {
    local user pass

    info "ClickHouse data export"
    echo ""
    echo "This will export data from the OLD ClickHouse instance."
    echo "Make sure the old ClickHouse is still running."
    echo ""

    read -rp "Old ClickHouse URL [${OLD_CH_URL}]: " input
    OLD_CH_URL="${input:-$OLD_CH_URL}"

    read -rp "ClickHouse username [wesense]: " user
    user="${user:-wesense}"

    read -rsp "ClickHouse password: " pass
    echo ""

    [ -z "$pass" ] && error "Password cannot be empty"

    # Test connection
    info "Testing connection to ${OLD_CH_URL}..."
    check_clickhouse_http "$OLD_CH_URL" "$user" "$pass" \
        || error "Cannot connect to ClickHouse at ${OLD_CH_URL} with user '${user}'. Is it running?"

    # Check what databases/tables exist
    info "Checking databases..."
    local databases
    databases=$(curl -sf "${OLD_CH_URL}/?user=${user}&password=${pass}" \
        --data-binary "SELECT name FROM system.databases WHERE name NOT IN ('system','information_schema','INFORMATION_SCHEMA','default') FORMAT TabSeparatedRaw")
    echo "  Found databases: $(echo "$databases" | tr '\n' ' ')"

    mkdir -p "$BACKUP_DIR"

    # --- wesense.sensor_readings ---
    local sr_count
    sr_count=$(curl -sf "${OLD_CH_URL}/?user=${user}&password=${pass}" \
        --data-binary "SELECT count() FROM wesense.sensor_readings FORMAT TabSeparatedRaw" 2>/dev/null || echo "0")

    if [ "$sr_count" -gt 0 ] 2>/dev/null; then
        info "Exporting wesense.sensor_readings (${sr_count} rows)..."
        curl -sf "${OLD_CH_URL}/?user=${user}&password=${pass}" \
            --data-binary "SELECT * FROM wesense.sensor_readings FORMAT Native" \
            > "${BACKUP_DIR}/sensor_readings.native"
        info "  → $(du -h "${BACKUP_DIR}/sensor_readings.native" | cut -f1)"
    else
        info "Skipping wesense.sensor_readings (empty or missing)"
    fi

    # --- sensormap.region_boundaries (→ wesense_respiro) ---
    local rb_count
    rb_count=$(curl -sf "${OLD_CH_URL}/?user=${user}&password=${pass}" \
        --data-binary "SELECT count() FROM sensormap.region_boundaries FORMAT TabSeparatedRaw" 2>/dev/null || echo "0")

    if [ "$rb_count" -gt 0 ] 2>/dev/null; then
        info "Exporting sensormap.region_boundaries (${rb_count} rows)..."
        curl -sf "${OLD_CH_URL}/?user=${user}&password=${pass}" \
            --data-binary "SELECT * FROM sensormap.region_boundaries FORMAT Native" \
            > "${BACKUP_DIR}/region_boundaries.native"
        info "  → $(du -h "${BACKUP_DIR}/region_boundaries.native" | cut -f1)"
    else
        info "Skipping sensormap.region_boundaries (empty or missing)"
    fi

    # --- sensormap.device_region_cache (→ wesense_respiro) ---
    local drc_count
    drc_count=$(curl -sf "${OLD_CH_URL}/?user=${user}&password=${pass}" \
        --data-binary "SELECT count() FROM sensormap.device_region_cache FORMAT TabSeparatedRaw" 2>/dev/null || echo "0")

    if [ "$drc_count" -gt 0 ] 2>/dev/null; then
        info "Exporting sensormap.device_region_cache (${drc_count} rows)..."
        curl -sf "${OLD_CH_URL}/?user=${user}&password=${pass}" \
            --data-binary "SELECT * FROM sensormap.device_region_cache FORMAT Native" \
            > "${BACKUP_DIR}/device_region_cache.native"
        info "  → $(du -h "${BACKUP_DIR}/device_region_cache.native" | cut -f1)"
    else
        info "Skipping sensormap.device_region_cache (empty or missing)"
    fi

    echo ""
    info "Export complete! Files in ${BACKUP_DIR}/:"
    ls -lh "${BACKUP_DIR}/"*.native 2>/dev/null || echo "  (no files)"
    echo ""
    echo "Next steps:"
    echo "  1. Stop old containers"
    echo "  2. Configure .env (cp .env.sample .env, set passwords)"
    echo "  3. docker compose --profile station up -d"
    echo "  4. Wait for ClickHouse to start (~30s)"
    echo "  5. Run: $0 import"
}

# ---------------------------------------------------------------------------
# IMPORT — run after new docker compose stack is up
# ---------------------------------------------------------------------------
do_import() {
    info "ClickHouse data import"
    echo ""
    echo "This will import data into the NEW docker compose ClickHouse."
    echo "Make sure the new stack is running (docker compose --profile station up -d)."
    echo ""

    # Try to read credentials from .env
    local user="" pass="" compose_project=""
    if [ -f .env ]; then
        user=$(grep -E '^CLICKHOUSE_USER=' .env | cut -d= -f2 | tr -d "'\"" || true)
        pass=$(grep -E '^CLICKHOUSE_PASSWORD=' .env | cut -d= -f2 | tr -d "'\"" || true)
    fi
    user="${user:-wesense}"

    if [ -z "$pass" ]; then
        read -rsp "ClickHouse password for user '${user}': " pass
        echo ""
    else
        info "Using credentials from .env (user: ${user})"
    fi

    [ -z "$pass" ] && error "Password cannot be empty"

    # Find the ClickHouse container
    local container
    container=$(docker compose ps --format '{{.Name}}' 2>/dev/null | grep clickhouse | head -1 || true)

    if [ -z "$container" ]; then
        error "Cannot find a running ClickHouse container. Is the stack up? (docker compose --profile station up -d)"
    fi

    info "Using container: ${container}"

    # Test connection via docker exec
    docker exec "$container" clickhouse-client \
        --user "$user" --password "$pass" \
        --query "SELECT 1" > /dev/null 2>&1 \
        || error "Cannot connect to ClickHouse inside container '${container}' with user '${user}'"

    # --- Import sensor_readings ---
    if [ -f "${BACKUP_DIR}/sensor_readings.native" ]; then
        local size
        size=$(du -h "${BACKUP_DIR}/sensor_readings.native" | cut -f1)
        info "Importing wesense.sensor_readings (${size})..."
        docker exec -i "$container" clickhouse-client \
            --user "$user" --password "$pass" \
            --query "INSERT INTO wesense.sensor_readings FORMAT Native" \
            < "${BACKUP_DIR}/sensor_readings.native"

        local count
        count=$(docker exec "$container" clickhouse-client \
            --user "$user" --password "$pass" \
            --query "SELECT count() FROM wesense.sensor_readings")
        info "  → ${count} rows in wesense.sensor_readings"
    else
        info "Skipping sensor_readings (no backup file)"
    fi

    # --- Import region_boundaries (sensormap → wesense_respiro) ---
    if [ -f "${BACKUP_DIR}/region_boundaries.native" ]; then
        local size
        size=$(du -h "${BACKUP_DIR}/region_boundaries.native" | cut -f1)
        info "Importing wesense_respiro.region_boundaries (${size})..."
        docker exec -i "$container" clickhouse-client \
            --user "$user" --password "$pass" \
            --query "INSERT INTO wesense_respiro.region_boundaries FORMAT Native" \
            < "${BACKUP_DIR}/region_boundaries.native"

        local count
        count=$(docker exec "$container" clickhouse-client \
            --user "$user" --password "$pass" \
            --query "SELECT count() FROM wesense_respiro.region_boundaries")
        info "  → ${count} rows in wesense_respiro.region_boundaries"
    else
        info "Skipping region_boundaries (no backup file)"
    fi

    # --- Import device_region_cache (sensormap → wesense_respiro) ---
    if [ -f "${BACKUP_DIR}/device_region_cache.native" ]; then
        local size
        size=$(du -h "${BACKUP_DIR}/device_region_cache.native" | cut -f1)
        info "Importing wesense_respiro.device_region_cache (${size})..."
        docker exec -i "$container" clickhouse-client \
            --user "$user" --password "$pass" \
            --query "INSERT INTO wesense_respiro.device_region_cache FORMAT Native" \
            < "${BACKUP_DIR}/device_region_cache.native"

        local count
        count=$(docker exec "$container" clickhouse-client \
            --user "$user" --password "$pass" \
            --query "SELECT count() FROM wesense_respiro.device_region_cache")
        info "  → ${count} rows in wesense_respiro.device_region_cache"
    else
        info "Skipping device_region_cache (no backup file)"
    fi

    echo ""
    info "ClickHouse import complete!"

    # -----------------------------------------------------------------------
    # Migrate Meshtastic ingester caches
    # -----------------------------------------------------------------------
    echo ""
    info "Meshtastic ingester cache migration"
    echo ""

    # Read DATA_DIR from .env (default: ./data)
    local data_dir=""
    if [ -f .env ]; then
        data_dir=$(grep -E '^DATA_DIR=' .env | cut -d= -f2 | tr -d "'\"" || true)
    fi
    data_dir="${data_dir:-./data}"

    # --- Community cache → main docker-compose ingester ---
    local new_community_cache="${data_dir}/ingester-meshtastic/cache"

    echo "Community ingester cache:"
    echo "  From: ${OLD_CACHE_COMMUNITY}"
    echo "  To:   ${new_community_cache}"

    if [ -d "$OLD_CACHE_COMMUNITY" ]; then
        local file_count
        file_count=$(ls -1 "$OLD_CACHE_COMMUNITY" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$file_count" -gt 0 ]; then
            mkdir -p "$new_community_cache"
            cp -v "$OLD_CACHE_COMMUNITY"/* "$new_community_cache"/
            info "  → Copied ${file_count} cache files"
        else
            info "  → Source directory empty, skipping"
        fi
    else
        info "  → Source not found (${OLD_CACHE_COMMUNITY}), skipping"
        echo "    Set OLD_CACHE_COMMUNITY=/path/to/cache to override"
    fi

    # --- Downlink cache → separate downlink compose ---
    echo ""
    echo "Downlink ingester cache:"
    echo "  From: ${OLD_CACHE_DOWNLINK}"

    if [ -d "$OLD_CACHE_DOWNLINK" ]; then
        local file_count
        file_count=$(ls -1 "$OLD_CACHE_DOWNLINK" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$file_count" -gt 0 ]; then
            local downlink_cache=""
            read -rp "  Downlink compose data/cache path (leave empty to skip): " downlink_cache

            if [ -n "$downlink_cache" ]; then
                mkdir -p "$downlink_cache"
                cp -v "$OLD_CACHE_DOWNLINK"/* "$downlink_cache"/
                info "  → Copied ${file_count} cache files"
            else
                info "  → Skipped (copy manually later)"
                echo "    cp -r ${OLD_CACHE_DOWNLINK}/* /path/to/wesense-ingester-meshtastic-downlink/data/cache/"
            fi
        else
            info "  → Source directory empty, skipping"
        fi
    else
        info "  → Source not found (${OLD_CACHE_DOWNLINK}), skipping"
        echo "    Set OLD_CACHE_DOWNLINK=/path/to/cache to override"
    fi

    echo ""
    info "Migration complete!"
    echo ""
    echo "Verify ClickHouse:"
    echo "  docker compose exec clickhouse clickhouse-client --user ${user} --password '***' --query 'SELECT count() FROM wesense.sensor_readings'"
    echo ""
    echo "You can delete the backup files when satisfied:"
    echo "  rm -rf ${BACKUP_DIR}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    export)
        do_export
        ;;
    import)
        do_import
        ;;
    *)
        echo "Usage: $0 {export|import}"
        echo ""
        echo "  export  — Backup data from old ClickHouse (run while old instance is up)"
        echo "  import  — Restore into new docker compose ClickHouse (run after stack is up)"
        echo ""
        echo "Environment variables:"
        echo "  BACKUP_DIR           Backup directory (default: ./migration-backup)"
        echo "  OLD_CH_URL           Old ClickHouse HTTP URL (default: http://localhost:8123)"
        echo "  OLD_CACHE_COMMUNITY  Old community ingester cache (default: /mnt/ssd1pool/docker2/wesense-ingester-meshtastic-community/cache)"
        echo "  OLD_CACHE_DOWNLINK   Old downlink ingester cache (default: /mnt/ssd1pool/docker2/wesense-ingester-meshtastic/cache)"
        exit 1
        ;;
esac
