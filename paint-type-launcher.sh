#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-License-Identifier: CC-BY-SA-4.0
#
# @a2ml-metadata begin
# (
#   id                   = "paint-type-launcher"
#   type                 = "launcher"
#   version              = "0.1.0"
#   app-name             = "paint-type"
#   app-display          = "paint.type"
#   app-url              = "http://localhost:8080"
#   runtime-kind         = "gui"
#   standards-compliance = [
#     "launcher-standard.adoc"
#     "LM-LA-LIFECYCLE-STANDARD.adoc"
#     "cross-platform-system-integration-modes"
#   ]
#   standard-spec-version = "0.2.0"
#   generator             = "manual"
# )
# @a2ml-metadata end
#
# paint-type-launcher.sh - paint.type Image Editor
# Compliant with launcher-standard.adoc

set -euo pipefail

# CONFIGURATION
APP_NAME="paint-type"
APP_DISPLAY="paint.type"
APP_DESC="Open cross-platform image editor for Paint.NET users"
RUNTIME_KIND="gui"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="http://localhost:8080"
APP_PORT="8080"
WAIT_SECONDS="10"

PID_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/${APP_NAME}-server.pid"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}"
LOG_FILE="${LOG_DIR}/server.log"
mkdir -p "$LOG_DIR"

START_COMMAND=""
for candidate in \
    "${REPO_DIR}/target/release/paint-type" \
    "${REPO_DIR}/paint-type" \
    "paint-type" \
    ; do
    if [ -x "$candidate" ]; then
        START_COMMAND="$candidate"
        break
    fi
done

MODE="${1:---auto}"
FORCE="false"
[[ "${2:-}" == "--force" ]] && FORCE="true"

# LOGGING
log()  { echo -e "\033[0;32m[${APP_DISPLAY}]\033[0m $1"; }
warn() { echo -e "\033[0;33m[${APP_DISPLAY}]\033[0m $1" >&2; }
err()  { echo -e "\033[0;31m[${APP_DISPLAY}]\033[0m ERROR: $1" >&2; }

is_gui_context() {
    [ ! -t 2 ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }
}

# PROCESS MANAGEMENT
is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start_server() {
    if [ -z "$START_COMMAND" ]; then
        err "Startup command not found - please build the project first"
        return 1
    fi
    if is_running; then
        if [ "$FORCE" = "true" ]; then
            stop_server
        else
            err "Already running (PID: $(cat "$PID_FILE"))"
            return 1
        fi
    fi
    log "Starting..."
    nohup "$START_COMMAND" >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    log "Started (PID: $!)"
}

stop_server() {
    if is_running; then
        log "Stopping..."
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
        log "Stopped"
    else
        log "Not running"
    fi
}

# SERVER READINESS
wait_for_server() {
    local max_wait="${WAIT_SECONDS:-15}"
    local poll_interval="1"
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if curl -fsS --max-time 2 "$URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$poll_interval"
        waited=$((waited + poll_interval))
    done
    return 1
}

# BROWSER
open_browser() {
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL"
    elif command -v open >/dev/null 2>&1; then
        open "$URL"
    else
        log "Could not open browser. Please visit: $URL"
    fi
}

# STATUS
status_server() {
    if is_running; then
        log "Running (PID: $(cat "$PID_FILE"))"
        log "Log: $LOG_FILE"
    else
        log "Not running"
    fi
}

# USAGE
usage() {
    echo "Usage: ${APP_NAME}-launcher.sh [MODE] [OPTIONS]"
    echo ""
    echo "Modes:"
    echo "  --start    Start application"
    echo "  --stop     Stop application"
    echo "  --restart  Restart application"
    echo "  --status   Show status"
    echo "  --auto     Start if not running"
    echo "  --browser  Start and open browser"
    echo "  --integ    Start and wait for server"
    echo "  --disinteg Stop server"
    echo "  --help     Show this help"
    echo ""
    echo "Options:"
    echo "  --force    Force action"
}

# MAIN DISPATCH
case "$MODE" in
    --start) start_server ;;
    --stop) stop_server ;;
    --restart) stop_server || true; start_server ;;
    --status) status_server ;;
    --auto) if ! is_running; then start_server; fi ;;
    --browser) start_server; if wait_for_server; then open_browser; else warn "Server timeout"; fi ;;
    --integ) start_server; wait_for_server ;;
    --disinteg) stop_server ;;
    --help|-h|"") usage ;;
    *) err "Unknown mode: $MODE"; usage; exit 1 ;;
esac
