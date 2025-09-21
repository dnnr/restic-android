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
LOG_DIR="/storage/emulated/0/ResticLogs/"
RESTIC_ENV_FILE="$HOME/.config/restic-android/env"
SOURCE_DIR="/storage/emulated/0"
EXCLUDE_FILE="$HOME/.config/restic-android/excludes"
RESTIC_CACHE_DIR="$PREFIX/var/cache/restic"

declare -a TERMUX_NOTIFICATIONS=()
TERMUX_NOTIFICATION_ID="restic-${HOSTNAME}"

ensure_log_and_reexec() {
    mkdir -p "$LOG_DIR"
    if [ "${RESTIC_BACKUP_LOGGING:-}" != "1" ]; then
        export RESTIC_BACKUP_LOGGING=1
        local logfile
        logfile="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).txt"
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
        msg "Setting up periodic job"
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

notify() {
    local persist=$1
    shift
    local id="$1"
    shift
    local -a args=("--group" "${TERMUX_NOTIFICATION_ID}" "--id" "$id")

    if termux-notification "${args[@]}" "$@"; then
        if [ "$persist" -eq 0 ]; then
            TERMUX_NOTIFICATIONS+=("$id")
        fi
    fi
}

msg() {
    echo "***" "$@"
}

info() {
    msg "INFO:" "$@"
    termux-toast -s "$*"
}

warn() {
    msg "WARN:" "$@"
    echo "Warning:" "$@" | \
        notify 1 failure \
        --title "restic" \
        --alert-once \
        --priority low
}

fatal() {
    msg "ERROR:" "$@"
    echo "Error:" "$@" | \
        notify 1 failure \
        --title "restic" \
        --alert-once \
        --priority high
    exit 1
}

cleanup() {
  for notification in "${TERMUX_NOTIFICATIONS[@]}"; do
    termux-notification-remove "$notification"
  done
  termux-wake-unlock
}

register_exit_cleanup() {
    trap "cleanup" EXIT
    termux-wake-lock
    notify 0 progress \
        --alert-once \
        --ongoing \
        --priority low \
        --title "restic" \
        --content "Running backup for ${HOSTNAME}"
}


main() {
    ensure_log_and_reexec "$@"
    ensure_schedule

    if [ ! -r "$RESTIC_ENV_FILE" ]; then
        fatal "Restic environment file not found: $RESTIC_ENV_FILE"
    fi
    set -a  # Marks modified/created variables for export
    . "$RESTIC_ENV_FILE"

    if ! is_wifi_connected; then
        msg "Not connected to Wi-Fi. Exiting."
        exit 1
    fi

    if ! is_charging; then
        msg "Device not charging. Exiting."
        exit 1
    fi

    mkdir -p "$RESTIC_CACHE_DIR"
    export RESTIC_CACHE_DIR
    restic unlock

    register_exit_cleanup

    termux-wake-lock
    notify 0 progress \
      --alert-once \
      --ongoing \
      --priority low \
      --title "restic" \
      --content "Running backup"

    restic backup --exclude-caches --exclude-file "$EXCLUDE_FILE" "$SOURCE_DIR" &
    local restic_pid=$!
    monitor_conditions "$restic_pid"
    wait "$restic_pid"
    if [ $? -ne 0 ]; then
        fatal "Backup failed!"
    fi
    info "Backup finished successfully"
}

main "$@"
