#!/usr/bin/env bash
# on-install-complete.sh -- Hook invoked when a server finishes OS installation
# Usage: on-install-complete.sh <project_dir> <server_name> <status>
#
# Called by callback-handler.sh after receiving an HTTP callback.
# Responsibilities:
#   1. Update status.json with the new server status and timestamp
#   2. Log the event
#   3. Check if all servers are done and print a completion message
#   4. Optionally trigger Ansible post-install if configured

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/spec-parser.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
    die "Usage: $(basename "$0") <project_dir> <server_name> <status>"
fi

PROJECT_DIR="$(get_project_dir "$1")"
SERVER_NAME="$2"
STATUS="$3"

set_project_paths "$PROJECT_DIR"
SPEC_FILE="$(find_spec_file "$PROJECT_DIR")"
STATUS_FILE="${GENERATED_DIR}/status.json"

NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
NOW_LOCAL="$(date '+%Y-%m-%d %H:%M:%S')"

# ---------------------------------------------------------------------------
# Log the event
# ---------------------------------------------------------------------------
log_info "Install callback: server=${SERVER_NAME} status=${STATUS} time=${NOW_LOCAL}"

# ---------------------------------------------------------------------------
# Update status.json
# ---------------------------------------------------------------------------
# Translate callback statuses to canonical values
case "$STATUS" in
    success|ok|done|complete)
        canonical_status="installed"
        ;;
    fail|failed|error)
        canonical_status="failed"
        ;;
    installing|in-progress)
        canonical_status="installing"
        ;;
    pxe-boot|pxe-booting|booting)
        canonical_status="pxe-booting"
        ;;
    *)
        canonical_status="$STATUS"
        ;;
esac

if [[ -f "$STATUS_FILE" ]]; then
    # Use jq if available for robust JSON manipulation
    if command -v jq &>/dev/null; then
        local_tmp="${STATUS_FILE}.tmp"
        jq \
            --arg server "$SERVER_NAME" \
            --arg status "$canonical_status" \
            --arg time "$NOW" \
            '
            if .servers[$server] then
                .servers[$server].status = $status |
                .servers[$server].updated_at = $time
            else
                .servers[$server] = {
                    "status": $status,
                    "updated_at": $time
                }
            end
            ' "$STATUS_FILE" > "$local_tmp" \
        && mv "$local_tmp" "$STATUS_FILE"
    else
        # Fallback: sed-based update (less robust but works without jq)
        # Find the server block and replace status + updated_at
        local_tmp="${STATUS_FILE}.tmp"
        cp "$STATUS_FILE" "$local_tmp"

        # Use awk for a safer in-place update
        awk -v server="$SERVER_NAME" \
            -v status="$canonical_status" \
            -v ts="$NOW" '
        BEGIN { in_server = 0 }
        {
            if ($0 ~ "\"" server "\":") {
                in_server = 1
            }
            if (in_server && $0 ~ /"status":/) {
                sub(/"status": *"[^"]*"/, "\"status\": \"" status "\"")
            }
            if (in_server && $0 ~ /"updated_at":/) {
                sub(/"updated_at": *"[^"]*"/, "\"updated_at\": \"" ts "\"")
                in_server = 0
            }
            print
        }
        ' "$local_tmp" > "$STATUS_FILE"
        rm -f "$local_tmp"
    fi

    log_info "Updated status.json: ${SERVER_NAME} -> ${canonical_status}"
else
    log_warn "Status file not found: ${STATUS_FILE}"
fi

# ---------------------------------------------------------------------------
# Per-server log
# ---------------------------------------------------------------------------
ensure_dir "${LOGS_DIR}/per-server"
{
    echo "[${NOW_LOCAL}] Status: ${canonical_status} (raw: ${STATUS})"
} >> "${LOGS_DIR}/per-server/${SERVER_NAME}.log"

# ---------------------------------------------------------------------------
# Check if all servers are done
# ---------------------------------------------------------------------------
check_all_done() {
    if [[ ! -f "$STATUS_FILE" ]] || ! command -v jq &>/dev/null; then
        return
    fi

    local total completed failed
    total="$(jq '.total_servers // 0' "$STATUS_FILE")"
    completed="$(jq '[.servers[] | select(.status == "installed")] | length' "$STATUS_FILE")"
    failed="$(jq '[.servers[] | select(.status == "failed")] | length' "$STATUS_FILE")"
    local finished=$(( completed + failed ))

    log_info "Progress: ${completed} installed, ${failed} failed, out of ${total} total."

    if (( finished >= total )); then
        echo ""
        print_separator "="
        if (( failed == 0 )); then
            printf "${_COLOR_GREEN}  ALL %d SERVERS INSTALLED SUCCESSFULLY${_COLOR_RESET}\n" "$total"
        else
            printf "${_COLOR_YELLOW}  ALL SERVERS FINISHED: %d installed, %d failed${_COLOR_RESET}\n" \
                "$completed" "$failed"
        fi
        print_separator "="
        echo ""

        log_info "Provisioning complete at ${NOW_LOCAL}."
        log_info "Next step: bareignite.sh ansible-run ${PROJECT_DIR}"

        # Update the status file with completion timestamp
        jq --arg ts "$NOW" '. + { "completed_at": $ts }' \
            "$STATUS_FILE" > "${STATUS_FILE}.tmp" \
        && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

        # Trigger Ansible post-install if auto_ansible is configured
        trigger_ansible_if_configured
    fi
}

# ---------------------------------------------------------------------------
# Optional: trigger Ansible post-install
# ---------------------------------------------------------------------------
trigger_ansible_if_configured() {
    local auto_ansible
    auto_ansible="$(spec_get "$SPEC_FILE" '.defaults.auto_ansible' 2>/dev/null)" || true

    if [[ "$auto_ansible" == "true" ]]; then
        local ansible_playbook="${BAREIGNITE_ROOT}/ansible/site.yml"
        local inventory="${GENERATED_DIR}/ansible/inventory.ini"

        if [[ -f "$ansible_playbook" && -f "$inventory" ]]; then
            log_info "Auto-ansible is enabled. Triggering post-install playbook..."
            # Run in background so we don't block the callback response
            (
                export ANSIBLE_CONFIG="${BAREIGNITE_ROOT}/ansible/ansible.cfg"
                ansible-playbook -i "$inventory" "$ansible_playbook" \
                    >> "${LOGS_DIR}/ansible-auto.log" 2>&1
            ) &
            log_info "Ansible playbook launched in background. Log: ${LOGS_DIR}/ansible-auto.log"
        else
            log_warn "Auto-ansible enabled but playbook or inventory missing."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_all_done
