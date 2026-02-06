#!/bin/sh
# init-auth.sh — EMQX entrypoint wrapper for opt-in MQTT authentication
#
# When MQTT_USER and MQTT_PASSWORD are both set:
#   1. Generates a bootstrap CSV with the credentials
#   2. Exports EMQX env-var overrides to enable built-in DB authentication
#   3. Spawns a background process to delete the CSV after EMQX ingests it
#
# When they are not set, EMQX starts with anonymous access (default behavior).
set -e

BOOTSTRAP_FILE="/opt/emqx/etc/auth-bootstrap.csv"

if [ -n "$MQTT_USER" ] && [ -n "$MQTT_PASSWORD" ]; then
    echo "init-auth: MQTT_USER and MQTT_PASSWORD are set — enabling authentication"

    # Generate bootstrap CSV (username,password,is_superuser)
    # EMQX hashes the plaintext password on import.
    printf '%s,%s,true\n' "$MQTT_USER" "$MQTT_PASSWORD" > "$BOOTSTRAP_FILE"
    chmod 600 "$BOOTSTRAP_FILE"

    # Configure EMQX built-in DB authenticator via environment variable overrides
    export EMQX_AUTHENTICATION__1__MECHANISM="password_based"
    export EMQX_AUTHENTICATION__1__BACKEND="built_in_database"
    export EMQX_AUTHENTICATION__1__USER_ID_TYPE="username"
    export EMQX_AUTHENTICATION__1__PASSWORD_HASH_ALGORITHM__NAME="bcrypt"
    export EMQX_AUTHENTICATION__1__PASSWORD_HASH_ALGORITHM__SALT_ROUNDS="10"
    export EMQX_AUTHENTICATION__1__BOOTSTRAP_FILE="$BOOTSTRAP_FILE"
    export EMQX_AUTHENTICATION__1__BOOTSTRAP_TYPE="plain"

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

# Hand off to the real EMQX entrypoint
exec /usr/bin/docker-entrypoint.sh "$@"
