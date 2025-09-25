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
LOCK_FILE="$HOME/.local/share/restic-android/lock"
RESTIC_ENV_FILE="$HOME/.config/restic-android/env"
SOURCE_DIR="/storage/emulated/0"
EXCLUDE_FILE="$HOME/.config/restic-android/excludes"
RESTIC_CACHE_DIR="$PREFIX/var/cache/restic"

TERMUX_NOTIFICATION_GROUP="restic-${HOSTNAME}"

# Always make sure cache dir exists and is used (otherwise performance will be bad, see https://github.com/restic/restic/issues/4775 )
mkdir -p "$RESTIC_CACHE_DIR"
export RESTIC_CACHE_DIR

ensure_log_and_reexec() {
    mkdir -p "$LOG_DIR"
    if [ "${RESTIC_BACKUP_LOGGING:-}" != "1" ]; then
        export RESTIC_BACKUP_LOGGING=1
        local logfile
        logfile="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S)_$BASHPID.txt"
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
        local needs_killing=0
        if ! is_wifi_connected; then
            warn "Wi-Fi disconnected, aborting backup" >&2
            needs_killing=1
        fi
        if ! is_charging; then
            warn "Charger disconnected, aborting backup" >&2
            needs_killing=1
        fi
        if [ $needs_killing -ne 0 ]; then
            msg "Killing restic PID $pid"
            kill "$pid"
            msg "Waiting for restic to quit"
            wait "$pid" 2>/dev/null
            exit 1
        fi
    done
}

termux_job_scheduler()
{
    timeout 60 termux-job-scheduler "$@"
    if [ $? -eq 124 ]; then
        msg "Call to termux-job-scheduler was most likely stuck and we killed it after a timeout (happens sometimes)"
        return
    fi
}

ensure_schedule() {
    msg "Verifying job schedule"
    local exists
    exists=$(termux_job_scheduler -p 2>/dev/null | grep -F "Pending Job $JOB_ID" || true)
    if [ -z "$exists" ]; then
        msg "Setting up periodic job"
        termux_job_scheduler \
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

ensure_flock() {
    mkdir -p "$(dirname $LOCK_FILE)"
    exec 4<>"$LOCK_FILE"
    flock --nonblock 4 || fatal "Another backup is still running (failed to acquire lock: $LOCK_FILE)"
    msg "Acquired lock: $LOCK_FILE"
}

notify() {
    local id="$1"
    shift
    local -a args=("--group" "${TERMUX_NOTIFICATION_GROUP}")
    if [ -n "$id" ]; then
        args+=("--id" "$id")
    fi

    termux-notification "${args[@]}" "$@"
}

msg() {
    echo "*** $(date --iso-8601=seconds): " "$@"
}

info() {
    msg "INFO:" "$@"
    termux-toast -s "$*"
}

progress() {
    msg "PROGRESS: " "$@"
    echo "$@" | \
        notify progress \
        --title "restic" \
        --alert-once \
        --ongoing \
        --priority low
    }

warn() {
    msg "WARN:" "$@"
    echo "Warning:" "$@" | \
        notify "" \
        --title "restic" \
        --alert-once \
        --priority low
}

fatal() {
    msg "ERROR:" "$@"
    echo "Error:" "$@" | \
        notify "" \
        --title "restic" \
        --alert-once \
        --priority high
    exit 1
}

# Register this before taking a wake lock and before posting progress notifications
cleanup() {
    # Clear progress notifications
    termux-notification-remove progress

    msg "Releasing Android wake lock"
    termux-wake-unlock
}

main() {
    ensure_log_and_reexec "$@"
    ensure_flock
    ensure_schedule

    trap "cleanup" INT TERM EXIT

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

    msg "Acquiring Android wake lock"
    termux-wake-lock

    progress "Unlocking repository"
    restic unlock

    progress "Running backup"
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
