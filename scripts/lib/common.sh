#!/usr/bin/env bash
# common.sh - Shared library for BareIgnite
# Provides logging, path helpers, dependency checks, and common utilities.
#
# Source guard: prevent double-sourcing
[[ -n "${_BAREIGNITE_COMMON_LOADED:-}" ]] && return 0
_BAREIGNITE_COMMON_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# Root path detection
# ---------------------------------------------------------------------------
# BAREIGNITE_ROOT can be set externally; otherwise derive from this file's
# location:  scripts/lib/common.sh  ->  two levels up = project root
if [[ -z "${BAREIGNITE_ROOT:-}" ]]; then
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BAREIGNITE_ROOT="$(cd "${_self_dir}/../.." && pwd)"
    unset _self_dir
fi
export BAREIGNITE_ROOT

# ---------------------------------------------------------------------------
# Standard directories
# ---------------------------------------------------------------------------
SCRIPTS_DIR="${BAREIGNITE_ROOT}/scripts"
CONF_DIR="${BAREIGNITE_ROOT}/conf"
PROJECTS_DIR="${BAREIGNITE_ROOT}/projects"
TEMPLATES_DIR="${BAREIGNITE_ROOT}/templates"
IMAGES_DIR="${BAREIGNITE_ROOT}/images"
PXE_DIR="${BAREIGNITE_ROOT}/pxe"
TOOLS_DIR="${BAREIGNITE_ROOT}/tools"

# Per-project directories (set after resolving a project)
GENERATED_DIR=""   # <project>/generated
LOGS_DIR=""        # <project>/logs

# ---------------------------------------------------------------------------
# Color / logging
# ---------------------------------------------------------------------------
_COLOR_RESET="\033[0m"
_COLOR_RED="\033[0;31m"
_COLOR_GREEN="\033[0;32m"
_COLOR_YELLOW="\033[0;33m"
_COLOR_CYAN="\033[0;36m"

# Disable colors when stdout is not a terminal
if [[ ! -t 1 ]]; then
    _COLOR_RESET="" _COLOR_RED="" _COLOR_GREEN="" _COLOR_YELLOW="" _COLOR_CYAN=""
fi

log_info() {
    printf "${_COLOR_GREEN}[INFO]${_COLOR_RESET}  %s\n" "$*"
}

log_warn() {
    printf "${_COLOR_YELLOW}[WARN]${_COLOR_RESET}  %s\n" "$*" >&2
}

log_error() {
    printf "${_COLOR_RED}[ERROR]${_COLOR_RESET} %s\n" "$*" >&2
}

log_debug() {
    if [[ -n "${BAREIGNITE_DEBUG:-}" ]]; then
        printf "${_COLOR_CYAN}[DEBUG]${_COLOR_RESET} %s\n" "$*" >&2
    fi
}

# die - print error message and exit
die() {
    log_error "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This command must be run as root (use sudo)."
    fi
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
# check_dependencies [tool ...]
# When called without arguments, checks the full set required by BareIgnite.
check_dependencies() {
    local tools=("$@")
    if [[ ${#tools[@]} -eq 0 ]]; then
        tools=(yq jq ansible dnsmasq nginx samba socat curl mkisofs)
    fi

    local missing=()
    for cmd in "${tools[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing[*]}"
    fi
    log_debug "All dependencies satisfied: ${tools[*]}"
}

# ---------------------------------------------------------------------------
# Directory helpers
# ---------------------------------------------------------------------------
# ensure_dir <path> - create directory if it does not exist
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || die "Failed to create directory: $dir"
        log_debug "Created directory: $dir"
    fi
}

# get_project_dir <name_or_path>
# Resolve a project identifier to its absolute directory path.
# Accepts either:
#   - a bare name   -> ${PROJECTS_DIR}/<name>
#   - an absolute or relative path that contains spec.yaml / spec.json
get_project_dir() {
    local project="$1"
    local project_dir

    # If it looks like a path (contains /), resolve it
    if [[ "$project" == */* ]]; then
        project_dir="$(cd "$project" 2>/dev/null && pwd)" \
            || die "Project path does not exist: $project"
    else
        project_dir="${PROJECTS_DIR}/${project}"
    fi

    if [[ ! -d "$project_dir" ]]; then
        die "Project directory not found: $project_dir"
    fi

    echo "$project_dir"
}

# set_project_paths <project_dir>
# Populate GENERATED_DIR and LOGS_DIR for the given project directory.
set_project_paths() {
    local project_dir="$1"
    GENERATED_DIR="${project_dir}/generated"
    LOGS_DIR="${project_dir}/logs"
    export GENERATED_DIR LOGS_DIR
}

# find_spec_file <project_dir>
# Locate the spec file (YAML or JSON) inside a project directory.
find_spec_file() {
    local project_dir="$1"
    if [[ -f "${project_dir}/spec.yaml" ]]; then
        echo "${project_dir}/spec.yaml"
    elif [[ -f "${project_dir}/spec.yml" ]]; then
        echo "${project_dir}/spec.yml"
    elif [[ -f "${project_dir}/spec.json" ]]; then
        echo "${project_dir}/spec.json"
    else
        die "No spec file found in ${project_dir} (expected spec.yaml or spec.json)"
    fi
}

# ---------------------------------------------------------------------------
# PID file management (preserved from scaffold for later phases)
# ---------------------------------------------------------------------------
write_pid_file() {
    local pid_file="$1"
    local pid="$2"
    echo "$pid" > "$pid_file"
}

read_pid_file() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        cat "$pid_file"
    fi
}

is_pid_running() {
    local pid="$1"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
print_separator() {
    local char="${1:--}"
    local width="${2:-72}"
    printf '%*s\n' "$width" '' | tr ' ' "$char"
}
