#!/usr/bin/env bash
# bareignite.sh - Main CLI entry point for BareIgnite
#
# Usage: bareignite.sh <command> [options]
# Run with --help or no arguments for usage information.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BAREIGNITE_ROOT="$SCRIPT_DIR"

# Source core library
source "${SCRIPT_DIR}/scripts/lib/common.sh"

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
VERSION_FILE="${BAREIGNITE_ROOT}/VERSION"
BAREIGNITE_VERSION="unknown"
if [[ -f "$VERSION_FILE" ]]; then
    BAREIGNITE_VERSION="$(cat "$VERSION_FILE" | tr -d '[:space:]')"
fi

# ---------------------------------------------------------------------------
# Help text
# ---------------------------------------------------------------------------
show_help() {
    cat <<EOF
BareIgnite v${BAREIGNITE_VERSION} - Offline Bare Metal Server Provisioning

Usage: $(basename "$0") <command> [options]

Commands:
  validate   <project>     Validate the project's spec file
  generate   <project>     Generate PXE, kickstart, and service configs
  start      <project>     Start provisioning services (DHCP, TFTP, HTTP, etc.)
  stop       <project>     Stop provisioning services
  status     <project>     Show service and provisioning status
  monitor    <project>     Live monitoring of provisioning progress
  reconfig-ip <project>    Re-assign / update server IP addresses

Options:
  -h, --help               Show this help message
  -v, --version            Show version
  --debug                  Enable debug output

Arguments:
  <project>                Project name (looked up in projects/) or path to
                           a project directory containing spec.yaml/spec.json

Examples:
  $(basename "$0") validate example
  $(basename "$0") generate ./projects/my-dc
  $(basename "$0") start example
  $(basename "$0") status example

EOF
}

# ---------------------------------------------------------------------------
# Resolve project and spec file
# ---------------------------------------------------------------------------
resolve_project() {
    local project_arg="$1"
    PROJECT_DIR="$(get_project_dir "$project_arg")"
    set_project_paths "$PROJECT_DIR"
    SPEC_FILE="$(find_spec_file "$PROJECT_DIR")"
    export PROJECT_DIR SPEC_FILE
}

# ---------------------------------------------------------------------------
# Sub-command implementations
# ---------------------------------------------------------------------------
cmd_validate() {
    local project="${1:?'project name or path required'}"
    resolve_project "$project"
    log_info "Validating project: $(basename "$PROJECT_DIR")"
    exec bash "${SCRIPTS_DIR}/validate-spec.sh" "$SPEC_FILE"
}

cmd_generate() {
    local project="${1:?'project name or path required'}"
    resolve_project "$project"

    local generator="${SCRIPTS_DIR}/generate-configs.sh"
    if [[ -x "$generator" ]]; then
        exec bash "$generator" "$PROJECT_DIR"
    else
        log_warn "generate-configs.sh not implemented yet (Phase 2)"
        exit 0
    fi
}

cmd_start() {
    local project="${1:?'project name or path required'}"
    resolve_project "$project"

    local init_script="${SCRIPTS_DIR}/init-services.sh"
    if [[ -x "$init_script" ]]; then
        exec bash "$init_script" "$SPEC_FILE"
    else
        log_warn "init-services.sh not implemented yet (Phase 3)"
        exit 0
    fi
}

cmd_stop() {
    local project="${1:?'project name or path required'}"
    resolve_project "$project"

    local stop_script="${SCRIPTS_DIR}/stop-services.sh"
    if [[ -x "$stop_script" ]]; then
        exec bash "$stop_script" "$SPEC_FILE"
    else
        log_warn "stop-services.sh not implemented yet (Phase 3)"
        exit 0
    fi
}

cmd_status() {
    local project="${1:?'project name or path required'}"
    resolve_project "$project"

    local monitor_script="${SCRIPTS_DIR}/monitor.sh"
    if [[ -x "$monitor_script" ]]; then
        exec bash "$monitor_script" status "$SPEC_FILE"
    else
        log_warn "monitor.sh not implemented yet (Phase 3)"
        exit 0
    fi
}

cmd_monitor() {
    local project="${1:?'project name or path required'}"
    resolve_project "$project"

    local monitor_script="${SCRIPTS_DIR}/monitor.sh"
    if [[ -x "$monitor_script" ]]; then
        exec bash "$monitor_script" watch "$SPEC_FILE"
    else
        log_warn "monitor.sh not implemented yet (Phase 3)"
        exit 0
    fi
}

cmd_reconfig_ip() {
    local project="${1:?'project name or path required'}"
    resolve_project "$project"

    local assign_script="${SCRIPTS_DIR}/assign-ips.sh"
    if [[ -x "$assign_script" ]]; then
        exec bash "$assign_script" "$SPEC_FILE"
    else
        log_warn "assign-ips.sh not implemented yet (Phase 3)"
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Main: parse global flags, then dispatch subcommand
# ---------------------------------------------------------------------------
main() {
    # No arguments → show help
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    # Parse global flags first
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "BareIgnite v${BAREIGNITE_VERSION}"
                exit 0
                ;;
            --debug)
                export BAREIGNITE_DEBUG=1
                shift
                ;;
            -*)
                die "Unknown option: $1 (use --help for usage)"
                ;;
            *)
                break  # first non-flag argument is the subcommand
                ;;
        esac
    done

    local command="${1:-}"
    shift || true

    case "$command" in
        validate)    cmd_validate "$@" ;;
        generate)    cmd_generate "$@" ;;
        start)       cmd_start "$@" ;;
        stop)        cmd_stop "$@" ;;
        status)      cmd_status "$@" ;;
        monitor)     cmd_monitor "$@" ;;
        reconfig-ip) cmd_reconfig_ip "$@" ;;
        *)
            die "Unknown command: $command (use --help for usage)"
            ;;
    esac
}

main "$@"
