#!/usr/bin/env bash
# template-engine.sh -- Jinja2 template rendering using Ansible
# Provides functions to render Jinja2 templates using ansible's template module.
# This gives us full Jinja2 power (conditionals, loops, includes) without
# requiring Python directly.

# Source guard
[[ -n "${_BAREIGNITE_TEMPLATE_ENGINE_LOADED:-}" ]] && return 0
_BAREIGNITE_TEMPLATE_ENGINE_LOADED=1

set -euo pipefail

# Source common library if not already loaded
if [[ -z "${BAREIGNITE_ROOT:-}" ]]; then
    BAREIGNITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "${BAREIGNITE_ROOT}/scripts/lib/common.sh"

# ---------------------------------------------------------------------------
# render_template <template_file> <output_file> [key=value ...]
#
# Render a Jinja2 template with key=value variable pairs.
# Builds a JSON vars object and uses ansible -m template for rendering.
#
# Arguments:
#   template_file  - Path to the Jinja2 template (.j2)
#   output_file    - Path to write the rendered output
#   key=value      - Variable assignments passed to the template
# ---------------------------------------------------------------------------
render_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: ${template_file}"
        return 1
    fi

    # Ensure output directory exists
    mkdir -p "$(dirname "$output_file")"

    # Build JSON vars from key=value arguments
    local vars_json
    vars_json="$(_build_vars_json "$@")"

    log_info "Rendering: $(basename "$template_file") -> $(basename "$output_file")"
    log_debug "  Template: ${template_file}"
    log_debug "  Output:   ${output_file}"

    if ! ansible localhost \
        -m template \
        -a "src=${template_file} dest=${output_file}" \
        -e "${vars_json}" \
        --connection=local \
        -i "localhost," \
        2>&1 | _filter_ansible_output; then
        log_error "Failed to render template: ${template_file}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# render_template_with_file <template_file> <output_file> <vars_json_file>
#
# Render a Jinja2 template using a JSON vars file instead of individual args.
#
# Arguments:
#   template_file   - Path to the Jinja2 template (.j2)
#   output_file     - Path to write the rendered output
#   vars_json_file  - Path to a JSON file containing template variables
# ---------------------------------------------------------------------------
render_template_with_file() {
    local template_file="$1"
    local output_file="$2"
    local vars_json_file="$3"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: ${template_file}"
        return 1
    fi

    if [[ ! -f "$vars_json_file" ]]; then
        log_error "Variables file not found: ${vars_json_file}"
        return 1
    fi

    mkdir -p "$(dirname "$output_file")"

    log_info "Rendering: $(basename "$template_file") -> $(basename "$output_file")"
    log_debug "  Template: ${template_file}"
    log_debug "  Output:   ${output_file}"
    log_debug "  Vars:     ${vars_json_file}"

    if ! ansible localhost \
        -m template \
        -a "src=${template_file} dest=${output_file}" \
        -e "@${vars_json_file}" \
        --connection=local \
        -i "localhost," \
        2>&1 | _filter_ansible_output; then
        log_error "Failed to render template: ${template_file}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# render_template_to_stdout <template_file> [key=value ...]
#
# Render a template and output to stdout (useful for piping / appending).
# ---------------------------------------------------------------------------
render_template_to_stdout() {
    local template_file="$1"
    shift

    local tmp_output
    tmp_output="$(mktemp)"
    trap "rm -f '${tmp_output}'" RETURN

    if render_template "$template_file" "$tmp_output" "$@"; then
        cat "$tmp_output"
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# write_vars_file <output_json_file> [key=value ...]
#
# Write template variables to a JSON file for use with render_template_with_file.
# ---------------------------------------------------------------------------
write_vars_file() {
    local output_file="$1"
    shift

    mkdir -p "$(dirname "$output_file")"
    _build_vars_json "$@" > "$output_file"
    log_debug "Wrote vars file: ${output_file}"
}

# ---------------------------------------------------------------------------
# Internal: Convert key=value pairs to a JSON object
# ---------------------------------------------------------------------------
_build_vars_json() {
    local json="{"
    local first=true

    for arg in "$@"; do
        if [[ "$arg" != *"="* ]]; then
            log_warn "Skipping invalid variable (no '='): ${arg}"
            continue
        fi

        local key="${arg%%=*}"
        local value="${arg#*=}"

        if [[ "$first" == "true" ]]; then
            first=false
        else
            json+=","
        fi

        # Detect value type and format accordingly
        case "$value" in
            true|false|null)
                json+="\"${key}\": ${value}"
                ;;
            \[*\]|\{*\})
                # JSON array or object -- pass through as-is
                json+="\"${key}\": ${value}"
                ;;
            [0-9]*)
                if [[ "$value" =~ ^[0-9]+$ ]]; then
                    json+="\"${key}\": ${value}"
                else
                    json+="\"${key}\": \"${value}\""
                fi
                ;;
            *)
                value="${value//\\/\\\\}"
                value="${value//\"/\\\"}"
                json+="\"${key}\": \"${value}\""
                ;;
        esac
    done

    json+="}"
    echo "$json"
}

# ---------------------------------------------------------------------------
# Internal: Filter ansible output to reduce noise
# ---------------------------------------------------------------------------
_filter_ansible_output() {
    while IFS= read -r line; do
        if [[ "$line" == *"FAILED"* ]] || [[ "$line" == *"ERROR"* ]] || \
           [[ "$line" == *"fatal"* ]]; then
            log_error "Ansible: ${line}"
        elif [[ "$line" == *"WARNING"* ]]; then
            log_warn "Ansible: ${line}"
        fi
        if [[ -n "${BAREIGNITE_DEBUG:-}" ]]; then
            log_debug "Ansible: ${line}"
        fi
    done
    return 0
}
