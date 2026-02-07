#!/bin/sh
# init-auth.sh — EMQX entrypoint wrapper
#
# Runs as root (user: "0:0" in docker-compose), then drops to PUID:PGID.
#
# Responsibilities:
#   1. Fixes data directory ownership (fresh deployments create them as root)
#   2. Optionally enables MQTT authentication when MQTT_USER + MQTT_PASSWORD are set
#   3. Drops privileges to PUID:PGID before starting EMQX
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
BOOTSTRAP_FILE="/opt/emqx/etc/auth-bootstrap.csv"

# --- Fix ownership ---
# Ensure the entire EMQX tree is owned by PUID:PGID so the process can
# read binaries/configs and write to data/log after we drop privileges.
chown -R "$PUID:$PGID" /opt/emqx 2>/dev/null || true

# Point HOME inside /opt/emqx so Erlang's cookie file and other runtime
# files land somewhere PUID:PGID owns, regardless of /etc/passwd.
export HOME=/opt/emqx

# --- MQTT authentication (opt-in) ---
if [ -n "$MQTT_USER" ] && [ -n "$MQTT_PASSWORD" ]; then
    echo "init-auth: MQTT_USER and MQTT_PASSWORD are set — enabling authentication"

    # Generate bootstrap CSV with required header + data line.
    # EMQX parses the first line as column headers (map keys), so the header
    # MUST be present — without it the data line is treated as the header
    # and zero users are imported.
    # Column order: user_id,password_hash,salt,is_superuser
    # Random salt + SHA256 hash — each startup gets a unique salt so the
    # hash in Mnesia is never the same twice, defeating rainbow tables.
    SALT=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n')
    PASS_HASH=$(printf '%s%s' "$MQTT_PASSWORD" "$SALT" | sha256sum | cut -d' ' -f1)
    printf 'user_id,password_hash,salt,is_superuser\n%s,%s,%s,true\n' \
        "$MQTT_USER" "$PASS_HASH" "$SALT" > "$BOOTSTRAP_FILE"
    chown "$PUID:$PGID" "$BOOTSTRAP_FILE"
    chmod 600 "$BOOTSTRAP_FILE"

    # Configure EMQX built-in DB authenticator via environment variable overrides
    export EMQX_AUTHENTICATION__1__MECHANISM="password_based"
    export EMQX_AUTHENTICATION__1__BACKEND="built_in_database"
    export EMQX_AUTHENTICATION__1__USER_ID_TYPE="username"
    export EMQX_AUTHENTICATION__1__PASSWORD_HASH_ALGORITHM__NAME="sha256"
    export EMQX_AUTHENTICATION__1__PASSWORD_HASH_ALGORITHM__SALT_POSITION="suffix"
    export EMQX_AUTHENTICATION__1__BOOTSTRAP_FILE="$BOOTSTRAP_FILE"

    # Background cleanup: wait for EMQX to become healthy, then remove the CSV
    # so plaintext credentials don't persist on disk. The subshell survives
    # the exec below as an orphan process reparented to PID 1.
    (
        attempts=0
        max_attempts=60
        while [ $attempts -lt $max_attempts ]; do
            sleep 5
            if /opt/emqx/bin/emqx ctl status >/dev/null 2>&1; then
                rm -f "$BOOTSTRAP_FILE"
                echo "init-auth: bootstrap CSV removed (credentials loaded into Mnesia)"
                exit 0
            fi
            attempts=$((attempts + 1))
        done
        echo "init-auth: WARNING — timed out waiting for EMQX, bootstrap CSV not cleaned up"
    ) &
else
    echo "init-auth: MQTT_USER/MQTT_PASSWORD not set — anonymous access (no authentication)"
fi

# --- Drop privileges and hand off to the real EMQX entrypoint ---
echo "init-auth: starting EMQX as UID=$PUID GID=$PGID"
exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups \
    /usr/bin/docker-entrypoint.sh "$@"
