#!/usr/bin/env bash
# spec-parser.sh - Unified YAML / JSON spec file parser
# Uses yq (Go version v4+) for YAML and jq for JSON.
#
# Can be sourced as a library or invoked directly:
#   spec-parser.sh read  <spec_file> <query>
#   spec-parser.sh count <spec_file> <query>
#
# Source guard
[[ -n "${_BAREIGNITE_SPEC_PARSER_LOADED:-}" ]] && return 0
_BAREIGNITE_SPEC_PARSER_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# Format detection
# ---------------------------------------------------------------------------

# detect_spec_format <file>
# Returns "yaml" or "json".
detect_spec_format() {
    local file="$1"

    # First, try by extension
    case "${file##*.}" in
        yaml|yml) echo "yaml"; return 0 ;;
        json)     echo "json"; return 0 ;;
    esac

    # Fall back to content sniffing: if the first non-blank character is '{' or '['
    # treat it as JSON; otherwise assume YAML.
    local first_char
    first_char="$(sed -n '/[^[:space:]]/{ s/^\([^[:space:]]\).*/\1/; p; q; }' "$file")"
    if [[ "$first_char" == "{" || "$first_char" == "[" ]]; then
        echo "json"
    else
        echo "yaml"
    fi
}

# ---------------------------------------------------------------------------
# Internal: run the right tool based on format
# ---------------------------------------------------------------------------
_spec_query() {
    local file="$1"
    local query="$2"
    local format
    format="$(detect_spec_format "$file")"

    if [[ "$format" == "json" ]]; then
        jq -r "$query" "$file"
    else
        yq eval "$query" "$file"
    fi
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# spec_get <file> <jq-path>
# Return a scalar value.  Outputs empty string for null/missing keys.
spec_get() {
    local file="$1"
    local query="$2"
    local result
    result="$(_spec_query "$file" "$query")"

    # Normalise yq/jq null representations to empty string
    if [[ "$result" == "null" || -z "$result" ]]; then
        echo ""
    else
        echo "$result"
    fi
}

# spec_get_array <file> <jq-path>
# Return array elements, one per line.
# Example: spec_get_array spec.yaml '.servers[].name'
spec_get_array() {
    local file="$1"
    local query="$2"
    local format
    format="$(detect_spec_format "$file")"

    if [[ "$format" == "json" ]]; then
        jq -r "$query // empty" "$file"
    else
        yq eval "$query" "$file" | grep -v '^---$' | sed '/^$/d'
    fi
}

# spec_get_length <file> <jq-path>
# Return the length of an array node.
# Example: spec_get_length spec.yaml '.servers'
spec_get_length() {
    local file="$1"
    local query="$2"
    local format
    format="$(detect_spec_format "$file")"

    if [[ "$format" == "json" ]]; then
        jq -r "${query} | length" "$file"
    else
        yq eval "${query} | length" "$file"
    fi
}

# spec_get_object <file> <jq-path>
# Return a JSON-encoded object (useful for downstream jq processing).
# Always returns JSON regardless of input format.
spec_get_object() {
    local file="$1"
    local query="$2"
    local format
    format="$(detect_spec_format "$file")"

    if [[ "$format" == "json" ]]; then
        jq "$query" "$file"
    else
        yq eval "$query" "$file" -o json
    fi
}

# ---------------------------------------------------------------------------
# Convenience wrappers (compatible with scaffold API)
# ---------------------------------------------------------------------------

# spec_read - alias for spec_get (backward compatibility)
spec_read() { spec_get "$@"; }

# spec_server_count <file>
spec_server_count() { spec_get_length "$1" '.servers'; }

# spec_server_field <file> <index> <field>
spec_server_field() {
    spec_get "$1" ".servers[$2].$3"
}

# spec_for_each_server <file> <callback> [extra_args...]
spec_for_each_server() {
    local spec_file="$1"; shift
    local count
    count="$(spec_server_count "$spec_file")"
    for (( i=0; i<count; i++ )); do
        "$@" "$spec_file" "$i"
    done
}

# ---------------------------------------------------------------------------
# CLI entrypoint (when invoked directly)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        read)
            shift; spec_get "$@" ;;
        count)
            shift; spec_get_length "$1" "$2" ;;
        server-count)
            shift; spec_server_count "$1" ;;
        server-field)
            shift; spec_server_field "$@" ;;
        *)
            echo "Usage: $(basename "$0") {read|count|server-count|server-field} <spec_file> ..." >&2
            exit 1 ;;
    esac
fi
