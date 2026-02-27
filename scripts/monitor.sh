#!/usr/bin/env bash
# monitor.sh -- Real-time deployment status dashboard for BareIgnite
# Usage: monitor.sh [-w] <project_dir>
#
# Reads status.json and the spec file to display a table showing each
# server's provisioning progress.
#
# Options:
#   -w    Watch mode: auto-refresh every 5 seconds (Ctrl+C to exit).
#         Without -w a single snapshot is printed and the script exits.
#
# Status values:
#   pending     - Not yet started (grey)
#   pxe-booting - Server is PXE booting (blue)
#   installing  - OS installation in progress (yellow)
#   installed   - OS installed successfully (green)
#   failed      - Installation failed (red)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/spec-parser.sh"

# ---------------------------------------------------------------------------
# Color palette (extended beyond common.sh for dashboard use)
# ---------------------------------------------------------------------------
_COLOR_BLUE="\033[0;34m"
_COLOR_GREY="\033[0;90m"
_COLOR_BOLD="\033[1m"

if [[ ! -t 1 ]]; then
    _COLOR_BLUE="" _COLOR_GREY="" _COLOR_BOLD=""
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [-w] <project_dir>

Display deployment status dashboard.

Options:
  -w    Watch mode (auto-refresh every 5 seconds, Ctrl+C to exit)
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
WATCH_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--watch)
            WATCH_MODE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

PROJECT_DIR="$(get_project_dir "$1")"
set_project_paths "$PROJECT_DIR"
PIDS_DIR="${PROJECT_DIR}/pids"
SPEC_FILE="$(find_spec_file "$PROJECT_DIR")"
STATUS_FILE="${GENERATED_DIR}/status.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Colorize a status string
colorize_status() {
    local status="$1"
    case "$status" in
        installed)
            printf "${_COLOR_GREEN}%-12s${_COLOR_RESET}" "$status"
            ;;
        installing)
            printf "${_COLOR_YELLOW}%-12s${_COLOR_RESET}" "$status"
            ;;
        pxe-booting)
            printf "${_COLOR_BLUE}%-12s${_COLOR_RESET}" "$status"
            ;;
        failed)
            printf "${_COLOR_RED}%-12s${_COLOR_RESET}" "$status"
            ;;
        pending|*)
            printf "${_COLOR_GREY}%-12s${_COLOR_RESET}" "$status"
            ;;
    esac
}

# Draw a simple text-based progress bar
# draw_progress <completed> <total> [width]
draw_progress() {
    local completed="$1"
    local total="$2"
    local width="${3:-30}"

    if (( total == 0 )); then
        printf "[%*s] 0/0" "$width" ""
        return
    fi

    local filled=$(( (completed * width) / total ))
    local empty=$(( width - filled ))

    printf "${_COLOR_GREEN}"
    printf "["
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty"  '' | tr ' ' '-'
    printf "] %d/%d" "$completed" "$total"
    printf "${_COLOR_RESET}"
}

# Check if a service PID is alive
service_status_str() {
    local svc_name="$1"
    local pid_file="${PIDS_DIR}/${svc_name}.pid"
    local pid
    pid="$(read_pid_file "$pid_file")"
    if [[ -n "$pid" ]] && is_pid_running "$pid"; then
        printf "${_COLOR_GREEN}running${_COLOR_RESET}"
    else
        printf "${_COLOR_RED}stopped${_COLOR_RESET}"
    fi
}

# ---------------------------------------------------------------------------
# Render the dashboard
# ---------------------------------------------------------------------------
render_dashboard() {
    local now
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    local project_name
    project_name="$(spec_get "$SPEC_FILE" '.project.name')"

    # --- Header ---
    echo ""
    printf "${_COLOR_BOLD}  BareIgnite Deployment Dashboard${_COLOR_RESET}\n"
    print_separator "=" 72
    printf "  Project: %-30s  Updated: %s\n" "$project_name" "$now"
    echo ""

    # --- Service health ---
    printf "  ${_COLOR_BOLD}Service Health:${_COLOR_RESET}  "
    printf "dnsmasq=$(service_status_str dnsmasq)  "
    printf "nginx=$(service_status_str nginx)  "
    printf "samba=$(service_status_str smbd)  "
    printf "callback=$(service_status_str callback)"
    echo ""
    echo ""

    # --- Server table ---
    local count
    count="$(spec_server_count "$SPEC_FILE")"

    # Table header
    printf "  ${_COLOR_BOLD}%-20s %-12s %-20s %-12s %-20s${_COLOR_RESET}\n" \
        "Server" "OS" "MAC" "Status" "Updated"
    print_separator "-" 72

    local total_completed=0
    local total_failed=0

    for (( i = 0; i < count; i++ )); do
        local name os mac status updated_at

        name="$(spec_server_field "$SPEC_FILE" "$i" "name")"
        os="$(spec_server_field "$SPEC_FILE" "$i" "os")"
        mac="$(spec_server_field "$SPEC_FILE" "$i" "mac_addresses.ipmi")"

        # Read status from status.json if available
        status="pending"
        updated_at="-"

        if [[ -f "$STATUS_FILE" ]] && command -v jq &>/dev/null; then
            local srv_status srv_time
            srv_status="$(jq -r --arg n "$name" '.servers[$n].status // "pending"' "$STATUS_FILE")"
            srv_time="$(jq -r --arg n "$name" '.servers[$n].updated_at // "-"' "$STATUS_FILE")"
            status="$srv_status"
            # Format the timestamp for display (show only time portion if today)
            if [[ "$srv_time" != "-" && "$srv_time" != "null" ]]; then
                updated_at="$srv_time"
            fi
        fi

        # Truncate MAC for display
        local mac_display="${mac:0:17}"

        # Count completions
        case "$status" in
            installed) (( total_completed++ )) || true ;;
            failed)    (( total_failed++ ))    || true ;;
        esac

        # Print row with colorized status
        printf "  %-20s %-12s %-20s " "$name" "$os" "$mac_display"
        colorize_status "$status"
        printf " %-20s\n" "$updated_at"
    done

    print_separator "-" 72
    echo ""

    # --- Progress bar ---
    local total_done=$(( total_completed + total_failed ))
    printf "  Progress: "
    draw_progress "$total_completed" "$count" 30
    echo ""

    if (( total_failed > 0 )); then
        printf "  ${_COLOR_RED}Failed: %d${_COLOR_RESET}\n" "$total_failed"
    fi

    # --- Completion check ---
    if (( total_done >= count && count > 0 )); then
        echo ""
        if (( total_failed == 0 )); then
            printf "  ${_COLOR_GREEN}${_COLOR_BOLD}ALL %d SERVERS INSTALLED SUCCESSFULLY${_COLOR_RESET}\n" "$count"
        else
            printf "  ${_COLOR_YELLOW}${_COLOR_BOLD}ALL SERVERS FINISHED: %d ok, %d failed${_COLOR_RESET}\n" \
                "$total_completed" "$total_failed"
        fi
        printf "  Next step: bareignite.sh ansible-run %s\n" "$PROJECT_DIR"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Clean exit handler for watch mode
# ---------------------------------------------------------------------------
cleanup_watch() {
    # Re-enable cursor if we hid it
    tput cnorm 2>/dev/null || true
    echo ""
    log_info "Monitor stopped."
    exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "$WATCH_MODE" == "true" ]]; then
    trap cleanup_watch INT TERM

    # Hide cursor for cleaner display
    tput civis 2>/dev/null || true

    while true; do
        # Clear screen
        clear 2>/dev/null || printf "\033c"
        render_dashboard
        printf "  ${_COLOR_GREY}Auto-refreshing every 5s.  Press Ctrl+C to exit.${_COLOR_RESET}\n"
        sleep 5
    done
else
    render_dashboard
fi
