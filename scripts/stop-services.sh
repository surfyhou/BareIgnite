#!/usr/bin/env bash
# stop-services.sh -- Gracefully stop all BareIgnite provisioning services
# Usage: stop-services.sh <project_dir>
#
# Stops services in reverse startup order:
#   1. callback server
#   2. samba (nmbd, smbd)
#   3. nginx
#   4. dnsmasq
#
# Each process receives SIGTERM first; if still alive after a timeout
# it is sent SIGKILL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# graceful_kill <pid> <name> [timeout]
graceful_kill() {
    local pid="$1" name="${2:-process}" timeout="${3:-10}"

    if ! is_pid_running "$pid"; then
        return 0
    fi

    log_info "  Sending SIGTERM to ${name} (PID ${pid})..."
    kill -TERM "$pid" 2>/dev/null || true

    local waited=0
    while is_pid_running "$pid" && (( waited < timeout )); do
        sleep 1
        (( waited++ ))
    done

    if is_pid_running "$pid"; then
        log_warn "  ${name} still alive after ${timeout}s -- sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    ! is_pid_running "$pid"
}

# stop_service_tree <pid> <name> [timeout]
# Kill a process and all its children (process group).
stop_service_tree() {
    local pid="$1" name="${2:-process}" timeout="${3:-10}"

    if ! is_pid_running "$pid"; then
        return 0
    fi

    log_info "  Stopping ${name} (PID ${pid}) and children..."

    # Try to kill the entire process group
    local pgid
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" || true
    if [[ -n "$pgid" && "$pgid" != "0" ]]; then
        kill -TERM -- -"$pgid" 2>/dev/null || true
    else
        kill -TERM "$pid" 2>/dev/null || true
    fi

    local waited=0
    while is_pid_running "$pid" && (( waited < timeout )); do
        sleep 1
        (( waited++ ))
    done

    if is_pid_running "$pid"; then
        log_warn "  ${name} still alive after ${timeout}s -- sending SIGKILL..."
        if [[ -n "$pgid" && "$pgid" != "0" ]]; then
            kill -9 -- -"$pgid" 2>/dev/null || true
        else
            kill -9 "$pid" 2>/dev/null || true
        fi
        sleep 1
    fi

    ! is_pid_running "$pid"
}

# stop_by_pidfile <service_name> [timeout] [tree]
# Read PID from ${PIDS_DIR}/<service_name>.pid, stop the process, remove file.
stop_by_pidfile() {
    local svc="$1"
    local timeout="${2:-10}"
    local use_tree="${3:-false}"
    local pid_file="${PIDS_DIR}/${svc}.pid"

    local pid
    pid="$(read_pid_file "$pid_file")"

    if [[ -z "$pid" ]]; then
        log_info "  ${svc}: no PID file -- skipping."
        return 0
    fi

    if ! is_pid_running "$pid"; then
        log_info "  ${svc}: process (PID ${pid}) already gone -- cleaning up."
        rm -f "$pid_file"
        return 0
    fi

    local ok
    if [[ "$use_tree" == "true" ]]; then
        stop_service_tree "$pid" "$svc" "$timeout" && ok=true || ok=false
    else
        graceful_kill "$pid" "$svc" "$timeout" && ok=true || ok=false
    fi

    if [[ "$ok" == "true" ]]; then
        log_info "  ${svc}: stopped (was PID ${pid})."
        rm -f "$pid_file"
    else
        log_error "  ${svc}: FAILED to stop (PID ${pid})."
        (( STOP_ERRORS++ )) || true
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <project_dir>

Gracefully stop all provisioning services for the given project.
EOF
}

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

check_root

PROJECT_DIR="$(get_project_dir "$1")"
set_project_paths "$PROJECT_DIR"
PIDS_DIR="${PROJECT_DIR}/pids"

log_info "============================================"
log_info "  BareIgnite Service Shutdown"
log_info "  Project: ${PROJECT_DIR}"
log_info "============================================"
echo ""

STOP_ERRORS=0

# ===================================================================
# Stop services in reverse order
# ===================================================================

# 1. Callback server (may have forked socat children)
log_info "[1/4] Stopping callback server..."
stop_by_pidfile "callback" 10 true

# 2. Samba
log_info "[2/4] Stopping Samba..."
stop_by_pidfile "nmbd" 5
stop_by_pidfile "smbd" 5

# 3. nginx (prefer its own stop signal first)
log_info "[3/4] Stopping nginx..."
NGINX_PID="$(read_pid_file "${PIDS_DIR}/nginx.pid")"
if [[ -n "$NGINX_PID" ]] && is_pid_running "$NGINX_PID"; then
    if command -v nginx &>/dev/null; then
        nginx -s stop 2>/dev/null || true
        sleep 1
    fi
    if is_pid_running "$NGINX_PID"; then
        graceful_kill "$NGINX_PID" "nginx" 10 || (( STOP_ERRORS++ )) || true
    fi
    log_info "  nginx: stopped."
    rm -f "${PIDS_DIR}/nginx.pid"
else
    log_info "  nginx: not running or no PID file."
    rm -f "${PIDS_DIR}/nginx.pid"
fi

# 4. dnsmasq
log_info "[4/4] Stopping dnsmasq..."
stop_by_pidfile "dnsmasq" 10

# ===================================================================
# Clean up
# ===================================================================
echo ""

# Remove .running marker
if [[ -f "${PROJECT_DIR}/.running" ]]; then
    rm -f "${PROJECT_DIR}/.running"
    log_info "Removed .running marker."
fi

# Sweep any remaining PID files
if [[ -d "$PIDS_DIR" ]]; then
    remaining=0
    for pf in "${PIDS_DIR}"/*.pid; do
        [[ -f "$pf" ]] || continue
        local_pid="$(cat "$pf" 2>/dev/null)" || continue
        if [[ -n "$local_pid" ]] && is_pid_running "$local_pid"; then
            log_warn "Orphaned process: $(basename "$pf") PID ${local_pid}"
            (( remaining++ ))
        else
            rm -f "$pf"
        fi
    done
    if (( remaining == 0 )); then
        rm -rf "$PIDS_DIR"
    fi
fi

# ===================================================================
# Final status
# ===================================================================
echo ""
print_separator "="

if (( STOP_ERRORS > 0 )); then
    printf "${_COLOR_YELLOW}  BareIgnite Services Stopped (%d error(s))${_COLOR_RESET}\n" "$STOP_ERRORS"
    print_separator "="
    echo ""
    log_warn "Some services may not have stopped cleanly."
    log_warn "Manual check: ps aux | grep -E 'dnsmasq|nginx|smbd|nmbd|socat|callback'"
    exit 1
else
    printf "${_COLOR_GREEN}  BareIgnite Services Stopped Successfully${_COLOR_RESET}\n"
    print_separator "="
    echo ""
    log_info "All services stopped. PXE provisioning is no longer active."
fi
