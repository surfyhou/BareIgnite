#!/usr/bin/env bash
# init-services.sh -- Start all BareIgnite provisioning services
# Usage: init-services.sh <project_dir>
#
# Starts the following services in order:
#   1. dnsmasq  (DHCP + TFTP + DNS)
#   2. nginx    (HTTP server for install media and configs)
#   3. samba    (SMB share for Windows installs, if needed)
#   4. callback (HTTP listener for install-complete signals)
#
# Must be run as root.  The project must have been generated first
# (i.e., generated/ directory must exist).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/spec-parser.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CALLBACK_PORT="${CALLBACK_PORT:-8888}"

# ---------------------------------------------------------------------------
# Local helpers (not in common.sh)
# ---------------------------------------------------------------------------

# is_port_listening <port>
# Check whether a TCP port is being listened on.
is_port_listening() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} "
    else
        (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
    fi
}

# graceful_kill <pid> <name> [timeout]
# Send SIGTERM, wait, then SIGKILL if still alive.
graceful_kill() {
    local pid="$1" name="${2:-process}" timeout="${3:-10}"

    if ! is_pid_running "$pid"; then
        return 0
    fi

    log_info "Sending SIGTERM to ${name} (PID ${pid})..."
    kill -TERM "$pid" 2>/dev/null || true

    local waited=0
    while is_pid_running "$pid" && (( waited < timeout )); do
        sleep 1
        (( waited++ ))
    done

    if is_pid_running "$pid"; then
        log_warn "${name} (PID ${pid}) did not stop after ${timeout}s, sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    ! is_pid_running "$pid"
}

# has_windows_servers <spec_file>
# Returns 0 if at least one server uses a Windows OS.
has_windows_servers() {
    local spec_file="$1"
    local count
    count="$(spec_server_count "$spec_file")"
    for (( i = 0; i < count; i++ )); do
        local os
        os="$(spec_server_field "$spec_file" "$i" "os")"
        case "$os" in
            win*) return 0 ;;
        esac
    done
    return 1
}

# get_control_ip <project_dir> <spec_file>
# Determine the control node IP address.
get_control_ip() {
    local project_dir="$1" spec_file="$2"
    if [[ -f "${project_dir}/.control_ip" ]]; then
        cat "${project_dir}/.control_ip"
    else
        spec_get "$spec_file" '.network.ipmi.gateway'
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <project_dir>

Start all provisioning services for the given project.
Must be run as root.  Run 'bareignite.sh generate' first.
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
SPEC_FILE="$(find_spec_file "$PROJECT_DIR")"

# Verify generated directory exists
if [[ ! -d "$GENERATED_DIR" ]]; then
    die "Generated directory not found: ${GENERATED_DIR}
Run 'bareignite.sh generate ${PROJECT_DIR}' first."
fi

# Check for required generated config files
for required_file in dnsmasq.conf nginx.conf; do
    if [[ ! -f "${GENERATED_DIR}/${required_file}" ]]; then
        die "Required generated config missing: ${GENERATED_DIR}/${required_file}
Run 'bareignite.sh generate ${PROJECT_DIR}' first."
    fi
done

# Check if services are already running
if [[ -f "${PROJECT_DIR}/.running" ]]; then
    die "Services appear to be already running (marker file exists).
Run 'bareignite.sh stop ${PROJECT_DIR}' first, or remove ${PROJECT_DIR}/.running"
fi

# Create runtime directories
ensure_dir "$LOGS_DIR"
ensure_dir "$PIDS_DIR"

log_info "============================================"
log_info "  BareIgnite Service Startup"
log_info "  Project: ${PROJECT_DIR}"
log_info "============================================"

# Track startup success for cleanup
SERVICES_STARTED=()
STARTUP_FAILED=false

# Cleanup on failure: stop already-started services
cleanup_on_failure() {
    if [[ "$STARTUP_FAILED" == "true" ]]; then
        log_error "Startup failed. Rolling back already-started services..."
        for svc in "${SERVICES_STARTED[@]}"; do
            local pid
            pid="$(read_pid_file "${PIDS_DIR}/${svc}.pid")"
            if [[ -n "$pid" ]]; then
                graceful_kill "$pid" "$svc" 5 || true
            fi
            rm -f "${PIDS_DIR}/${svc}.pid"
        done
        rm -f "${PROJECT_DIR}/.running"
    fi
}
trap cleanup_on_failure EXIT

# ===================================================================
# 1. Start dnsmasq (DHCP + TFTP + DNS)
# ===================================================================
start_dnsmasq() {
    log_info "[1/4] Starting dnsmasq (DHCP + TFTP + DNS)..."

    check_dependencies dnsmasq

    local conf="${GENERATED_DIR}/dnsmasq.conf"
    local pid_file="${PIDS_DIR}/dnsmasq.pid"
    local logfile="${LOGS_DIR}/dnsmasq.log"

    # Stop system dnsmasq to avoid port conflicts
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        log_warn "Stopping system dnsmasq to avoid port conflicts..."
        systemctl stop dnsmasq 2>/dev/null || true
    fi

    # Run dnsmasq in the background (--keep-in-foreground keeps it as a
    # direct child so we can track its PID reliably).
    dnsmasq \
        --conf-file="$conf" \
        --log-facility="$logfile" \
        --keep-in-foreground &
    local bg_pid=$!

    sleep 2

    if ! is_pid_running "$bg_pid"; then
        log_error "dnsmasq failed to start. Check: $logfile"
        STARTUP_FAILED=true
        return 1
    fi

    write_pid_file "$pid_file" "$bg_pid"
    SERVICES_STARTED+=("dnsmasq")

    if is_port_listening 53; then
        log_info "  dnsmasq listening on DNS port 53"
    else
        log_debug "  DNS port 53 not detected (UDP-only is normal)"
    fi

    log_info "  dnsmasq started  PID=${bg_pid}  conf=${conf}"
}

# ===================================================================
# 2. Start nginx (HTTP server)
# ===================================================================
start_nginx() {
    log_info "[2/4] Starting nginx (HTTP server)..."

    check_dependencies nginx

    local conf="${GENERATED_DIR}/nginx.conf"
    local pid_file="${PIDS_DIR}/nginx.pid"

    # Stop system nginx to avoid port conflicts
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_warn "Stopping system nginx to avoid port conflicts..."
        systemctl stop nginx 2>/dev/null || true
    fi

    nginx -c "$conf" -g "pid ${pid_file};"

    sleep 1

    local pid
    pid="$(read_pid_file "$pid_file")"

    if [[ -z "$pid" ]] || ! is_pid_running "$pid"; then
        log_error "nginx failed to start. Check logs in: $LOGS_DIR"
        STARTUP_FAILED=true
        return 1
    fi

    SERVICES_STARTED+=("nginx")

    if is_port_listening 80; then
        log_info "  nginx listening on port 80"
    else
        log_debug "  Port 80 not detected yet"
    fi

    log_info "  nginx started  PID=${pid}  conf=${conf}"
}

# ===================================================================
# 3. Start Samba (only when Windows servers are in the spec)
# ===================================================================
start_samba() {
    log_info "[3/4] Checking for Windows servers (Samba)..."

    if ! has_windows_servers "$SPEC_FILE"; then
        log_info "  No Windows servers in spec -- skipping Samba."
        return 0
    fi

    log_info "  Windows servers detected, starting Samba..."

    if ! command -v smbd &>/dev/null; then
        log_warn "  smbd not found.  Windows PXE installs will not work."
        log_warn "  Install samba: yum install -y samba"
        return 0
    fi

    local smb_conf="${GENERATED_DIR}/smb.conf"

    # Generate a minimal smb.conf if the generator did not produce one
    if [[ ! -f "$smb_conf" ]]; then
        log_info "  Generating minimal smb.conf..."
        cat > "$smb_conf" <<SMBEOF
[global]
workgroup = WORKGROUP
server string = BareIgnite Install Server
security = user
map to guest = Bad Password
log file = ${LOGS_DIR}/samba-%m.log
max log size = 1024
server role = standalone server

[install]
path = ${IMAGES_DIR}/windows
browsable = yes
read only = yes
guest ok = yes
force user = nobody
SMBEOF
    fi

    # Stop system samba if running
    systemctl stop smb  2>/dev/null || true
    systemctl stop nmb  2>/dev/null || true

    # Start smbd
    smbd --configfile="$smb_conf" --piddir="$PIDS_DIR" --daemon
    sleep 1

    local smbd_pid=""
    if [[ -f "${PIDS_DIR}/smbd.pid" ]]; then
        smbd_pid="$(cat "${PIDS_DIR}/smbd.pid")"
    fi
    if [[ -n "$smbd_pid" ]] && is_pid_running "$smbd_pid"; then
        SERVICES_STARTED+=("smbd")
        log_info "  smbd started  PID=${smbd_pid}"
    else
        log_warn "  smbd may have failed to start."
    fi

    # Start nmbd (NetBIOS name service)
    if command -v nmbd &>/dev/null; then
        nmbd --configfile="$smb_conf" --piddir="$PIDS_DIR" --daemon
        sleep 1

        local nmbd_pid=""
        if [[ -f "${PIDS_DIR}/nmbd.pid" ]]; then
            nmbd_pid="$(cat "${PIDS_DIR}/nmbd.pid")"
        fi
        if [[ -n "$nmbd_pid" ]] && is_pid_running "$nmbd_pid"; then
            SERVICES_STARTED+=("nmbd")
            log_info "  nmbd started  PID=${nmbd_pid}"
        else
            log_debug "  nmbd may have failed to start (non-critical)"
        fi
    fi

    log_info "  Samba config: ${smb_conf}"
}

# ===================================================================
# 4. Start callback server
# ===================================================================
start_callback() {
    log_info "[4/4] Starting callback server (port ${CALLBACK_PORT})..."

    local callback_script="${SCRIPT_DIR}/callbacks/callback-server.sh"
    local pid_file="${PIDS_DIR}/callback.pid"
    local logfile="${LOGS_DIR}/callback.log"

    if [[ ! -x "$callback_script" ]]; then
        die "Callback script not found or not executable: $callback_script"
    fi

    # Launch in background
    CALLBACK_PORT="$CALLBACK_PORT" \
    PROJECT_DIR="$PROJECT_DIR" \
    BAREIGNITE_ROOT="$BAREIGNITE_ROOT" \
        nohup "$callback_script" "$PROJECT_DIR" \
        >> "$logfile" 2>&1 &
    local bg_pid=$!

    write_pid_file "$pid_file" "$bg_pid"
    sleep 2

    if ! is_pid_running "$bg_pid"; then
        log_error "Callback server failed to start. Check: $logfile"
        STARTUP_FAILED=true
        return 1
    fi

    SERVICES_STARTED+=("callback")

    if is_port_listening "$CALLBACK_PORT"; then
        log_info "  Callback server listening on port ${CALLBACK_PORT}"
    else
        log_debug "  Callback port ${CALLBACK_PORT} not yet detected"
    fi

    log_info "  Callback server started  PID=${bg_pid}  log=${logfile}"
}

# ===================================================================
# Initialize status.json
# ===================================================================
init_status_file() {
    local status_file="${GENERATED_DIR}/status.json"

    if [[ -f "$status_file" ]]; then
        log_info "Status file already exists, preserving: ${status_file}"
        return 0
    fi

    log_info "Initializing deployment status file..."

    local count
    count="$(spec_server_count "$SPEC_FILE")"
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local project_name
    project_name="$(spec_get "$SPEC_FILE" '.project.name')"

    # Build JSON by hand (no jq dependency at this stage)
    {
        echo "{"
        echo "  \"project\": \"${project_name}\","
        echo "  \"started_at\": \"${now}\","
        echo "  \"total_servers\": ${count},"
        echo "  \"servers\": {"

        for (( i = 0; i < count; i++ )); do
            local name os mac
            name="$(spec_server_field "$SPEC_FILE" "$i" "name")"
            os="$(spec_server_field "$SPEC_FILE" "$i" "os")"
            mac="$(spec_server_field "$SPEC_FILE" "$i" "mac_addresses.ipmi")"

            (( i > 0 )) && echo ","
            printf '    "%s": {\n' "$name"
            printf '      "os": "%s",\n' "$os"
            printf '      "mac": "%s",\n' "$mac"
            printf '      "status": "pending",\n'
            printf '      "updated_at": "%s"\n' "$now"
            printf '    }'
        done

        echo ""
        echo "  }"
        echo "}"
    } > "$status_file"

    log_info "Status file: ${status_file}"
}

# ===================================================================
# Print status summary
# ===================================================================
print_summary() {
    local control_ip
    control_ip="$(get_control_ip "$PROJECT_DIR" "$SPEC_FILE")"

    echo ""
    print_separator "="
    printf "${_COLOR_GREEN}  BareIgnite Services Started Successfully${_COLOR_RESET}\n"
    print_separator "="
    echo ""

    printf "  %-20s %s\n" "Project:" "$PROJECT_DIR"
    printf "  %-20s %s\n" "Control IP:" "${control_ip:-N/A}"
    echo ""

    printf "  %-20s %-12s %-10s\n" "Service" "Status" "Port(s)"
    print_separator "-" 44

    # Helper: print service row
    _svc_row() {
        local name="$1" pid_name="$2" ports="$3"
        local pid
        pid="$(read_pid_file "${PIDS_DIR}/${pid_name}.pid")"
        if [[ -n "$pid" ]] && is_pid_running "$pid"; then
            printf "  %-20s ${_COLOR_GREEN}%-12s${_COLOR_RESET} %-10s\n" "$name" "running" "$ports"
        else
            printf "  %-20s ${_COLOR_RED}%-12s${_COLOR_RESET} %-10s\n" "$name" "stopped" "-"
        fi
    }

    _svc_row "dnsmasq"       "dnsmasq"  "53/67/69"
    _svc_row "nginx"         "nginx"    "80"

    # Samba: show skipped if no Windows servers
    local smbd_pid
    smbd_pid="$(read_pid_file "${PIDS_DIR}/smbd.pid")"
    if [[ -n "$smbd_pid" ]] && is_pid_running "$smbd_pid"; then
        printf "  %-20s ${_COLOR_GREEN}%-12s${_COLOR_RESET} %-10s\n" "samba (smbd)" "running" "445"
    elif has_windows_servers "$SPEC_FILE" 2>/dev/null; then
        printf "  %-20s ${_COLOR_RED}%-12s${_COLOR_RESET} %-10s\n" "samba (smbd)" "stopped" "-"
    else
        printf "  %-20s %-12s %-10s\n" "samba (smbd)" "skipped" "-"
    fi

    _svc_row "callback"      "callback" "$CALLBACK_PORT"

    echo ""
    print_separator "-" 44

    local server_count
    server_count="$(spec_server_count "$SPEC_FILE")"
    printf "  Servers to provision: %d\n" "$server_count"

    echo ""
    log_info "Monitor deployment:  bareignite.sh status ${PROJECT_DIR}"
    log_info "Stop services:       bareignite.sh stop   ${PROJECT_DIR}"
    echo ""
}

# ===================================================================
# Main execution
# ===================================================================

init_status_file

start_dnsmasq
start_nginx
start_samba
start_callback

# Write .running marker
date -u '+%Y-%m-%dT%H:%M:%SZ' > "${PROJECT_DIR}/.running"

# Success -- disable the failure trap
STARTUP_FAILED=false
trap - EXIT

print_summary

log_info "All services started.  Servers can now PXE boot."
