#!/data/data/com.termux/files/usr/bin/bash

# Termux restic backup script
#
# Required tools:
#   jq
#   termux-api
#   restic

set -euo pipefail

SCRIPT_PATH="$(realpath "$0")"
JOB_ID=4242
LOG_DIR="$HOME/.local/share/restic-android/logs"
RESTIC_ENV_FILE="$HOME/.config/restic-android.env"
SOURCE_DIR="/storage/emulated/0"
RESTIC_CACHE_DIR="$PREFIX/var/cache/restic"

ensure_log_and_reexec() {
    mkdir -p "$LOG_DIR"
    if [ "${RESTIC_BACKUP_LOGGING:-}" != "1" ]; then
        export RESTIC_BACKUP_LOGGING=1
        local logfile
        logfile="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).log"
        "$SCRIPT_PATH" "$@" 2>&1 | tee "$logfile"
        exit
    fi
}

is_wifi_connected() {
    termux-wifi-connectioninfo | jq -e '.supplicant_state == "COMPLETED"' >/dev/null 2>&1
}

is_charging() {
    termux-battery-status | jq -e '.plugged != "UNPLUGGED"' >/dev/null 2>&1
}

monitor_conditions() {
    local pid="$1"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 15
        if ! is_wifi_connected; then
            echo "Wi-Fi disconnected, aborting backup" >&2
            kill "$pid"
            wait "$pid" 2>/dev/null
            exit 1
        fi
        if ! is_charging; then
            echo "Charger disconnected, aborting backup" >&2
            kill "$pid"
            wait "$pid" 2>/dev/null
            exit 1
        fi
    done
}

ensure_schedule() {
    local exists
    exists=$(termux-job-scheduler -p 2>/dev/null | grep -F "Pending Job $JOB_ID" || true)
    if [ -z "$exists" ]; then
        termux-job-scheduler \
            --job-id "$JOB_ID" \
            --period-ms 1800000 \
            --network unmetered \
            --charging true \
            --script "$SCRIPT_PATH" \
            --battery-not-low true \
            --storage-not-low true \
            --persisted true
    fi
}

main() {
    ensure_log_and_reexec "$@"
    ensure_schedule

    if [ ! -r "$RESTIC_ENV_FILE" ]; then
        echo "Restic environment file not found: $RESTIC_ENV_FILE" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$RESTIC_ENV_FILE"

    if ! is_wifi_connected; then
        echo "Not connected to Wi-Fi. Exiting." >&2
        exit 1
    fi

    if ! is_charging; then
        echo "Device not charging. Exiting." >&2
        exit 1
    fi

    mkdir -p "$RESTIC_CACHE_DIR"
    export RESTIC_CACHE_DIR
    restic unlock
    restic backup "$SOURCE_DIR" &
    local restic_pid=$!
    monitor_conditions "$restic_pid"
    wait "$restic_pid"
}

main "$@"
