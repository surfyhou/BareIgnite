#!/usr/bin/env bash
# gen-autoinstall.sh -- Generate Ubuntu autoinstall configs from spec
# Produces cloud-init files (user-data, meta-data, vendor-data) per server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---------------------------------------------------------------------------
# generate_autoinstall -- Main entry point
#
# Arguments:
#   $1 -- project directory (contains spec.yaml/json and generated/ output)
#
# For each server whose OS family is "debian" (Ubuntu), this function:
#   1. Selects the correct user-data template (ubuntu2004, ubuntu2204, ubuntu2404)
#   2. Renders user-data, meta-data, and vendor-data via Ansible Jinja2
#   3. Writes output to generated/autoinstall/{hostname}/
# ---------------------------------------------------------------------------
generate_autoinstall() {
    local project_dir="$1"
    local spec_file
    spec_file="$(find_spec_file "$project_dir")"

    local output_base="${project_dir}/generated/autoinstall"
    mkdir -p "$output_base"

    local server_count
    server_count="$(_spec_read "$spec_file" '.servers | length')"

    local generated=0
    for (( i=0; i<server_count; i++ )); do
        local os_id
        os_id="$(_spec_read "$spec_file" ".servers[$i].os")"

        local family
        family="$(_spec_read "$spec_file" ".os_catalog.${os_id}.family // \"unknown\"")"

        # Only process debian-family (Ubuntu) servers
        if [[ "$family" != "debian" ]]; then
            continue
        fi

        local method
        method="$(_spec_read "$spec_file" ".os_catalog.${os_id}.method // \"unknown\"")"
        if [[ "$method" != "autoinstall" ]]; then
            continue
        fi

        _generate_server_autoinstall "$spec_file" "$i" "$os_id" "$output_base"
        (( generated++ ))
    done

    if (( generated == 0 )); then
        log_info "No Ubuntu autoinstall servers found in spec -- skipping"
    else
        log_info "Generated autoinstall configs for ${generated} Ubuntu server(s)"
    fi
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Wrapper around spec file reading (supports YAML via yq and JSON via jq)
_spec_read() {
    local spec_file="$1" query="$2"
    if [[ "$spec_file" == *.yaml ]] || [[ "$spec_file" == *.yml ]]; then
        "${TOOLS_BIN}/yq" eval "$query" "$spec_file"
    else
        "${TOOLS_BIN}/jq" -r "$query" "$spec_file"
    fi
}

# Generate autoinstall files for a single server
_generate_server_autoinstall() {
    local spec_file="$1"
    local idx="$2"
    local os_id="$3"
    local output_base="$4"

    # --- Extract server fields ---
    local hostname
    hostname="$(_spec_read "$spec_file" ".servers[$idx].name")"

    local arch
    arch="$(_spec_read "$spec_file" ".servers[$idx].arch // \"x86_64\"")"

    # Determine template name from os_id (e.g., ubuntu2204 -> ubuntu2204-user-data.j2)
    local template_path
    template_path="$(_spec_read "$spec_file" ".os_catalog.${os_id}.template")"

    if [[ -z "$template_path" ]] || [[ "$template_path" == "null" ]]; then
        log_error "No template defined for OS '${os_id}' -- skipping ${hostname}"
        return 1
    fi

    local template_file="${BAREIGNITE_ROOT}/${template_path}"
    local meta_template="${BAREIGNITE_ROOT}/templates/autoinstall/meta-data.j2"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: ${template_file} -- skipping ${hostname}"
        return 1
    fi

    # --- Resolve values (server overrides -> defaults -> fallbacks) ---
    local locale timezone root_password
    locale="$(_resolve_field "$spec_file" "$idx" "locale" "en_US.UTF-8")"
    timezone="$(_resolve_field "$spec_file" "$idx" "timezone" "UTC")"
    root_password="$(_resolve_field "$spec_file" "$idx" "root_password" "")"

    # SSH keys: merge server-level and default-level
    local ssh_keys_json
    ssh_keys_json="$(_spec_read "$spec_file" "
        (.servers[$idx].ssh_keys // .defaults.ssh_keys // []) | tojson
    " 2>/dev/null || echo '[]')"

    # PXE MAC address (for network matching during install)
    local pxe_mac
    pxe_mac="$(_spec_read "$spec_file" "
        .servers[$idx].mac_addresses.pxe_boot //
        .servers[$idx].mac_addresses.ipmi
    ")"
    pxe_mac="$(echo "$pxe_mac" | tr '[:upper:]' '[:lower:]')"

    # PXE interface name (Ubuntu uses MAC matching, but provide a default)
    local pxe_interface="ens3"

    # Control IP for callback
    local control_ip
    control_ip="$(get_control_ip "$(dirname "$spec_file")")"

    # Callback port (default 8888)
    local callback_port="8888"

    # Packages: merge server extra_packages with OS defaults
    local packages_json
    packages_json="$(_spec_read "$spec_file" "
        (.servers[$idx].extra_packages // []) + [\"openssh-server\", \"curl\", \"vim\", \"wget\"] | unique | tojson
    " 2>/dev/null || echo '["openssh-server", "curl", "vim", "wget"]')"

    # Partition scheme
    local partition_scheme
    partition_scheme="$(_spec_read "$spec_file" "
        .servers[$idx].disk_layout.scheme //
        .defaults.partition_scheme //
        \"generic\"
    ")"

    # Custom disk layout (if scheme == "custom")
    local custom_disk_json="[]"
    if [[ "$partition_scheme" == "custom" ]]; then
        custom_disk_json="$(_spec_read "$spec_file" ".servers[$idx].disk_layout.custom | tojson" 2>/dev/null || echo '[]')"
    fi

    # Partition template (for Ubuntu storage section)
    local partition_template="${BAREIGNITE_ROOT}/templates/partitions/${partition_scheme}.part.j2"

    # NTP servers
    local ntp_json
    ntp_json="$(_spec_read "$spec_file" "
        .defaults.ntp_servers // [] | tojson
    " 2>/dev/null || echo '[]')"

    # Nameservers
    local nameservers_json
    nameservers_json="$(_spec_read "$spec_file" "
        .defaults.nameservers // [] | tojson
    " 2>/dev/null || echo '[]')"

    # --- Create output directory ---
    local output_dir="${output_base}/${hostname}"
    mkdir -p "$output_dir"

    log_info "Generating autoinstall for ${hostname} (${os_id}, ${arch})"

    # --- Build Ansible extra-vars JSON for template rendering ---
    local vars_file
    vars_file="$(mktemp)"
    trap "rm -f '$vars_file'" RETURN

    cat > "$vars_file" <<VARSEOF
{
    "hostname": "${hostname}",
    "locale": "${locale}",
    "timezone": "${timezone}",
    "root_password": "${root_password}",
    "ssh_keys": ${ssh_keys_json},
    "pxe_mac": "${pxe_mac}",
    "pxe_interface": "${pxe_interface}",
    "control_ip": "${control_ip}",
    "callback_port": "${callback_port}",
    "packages": ${packages_json},
    "partition_scheme": "${partition_scheme}",
    "custom_disk_layout": ${custom_disk_json},
    "ntp_servers": ${ntp_json},
    "nameservers": ${nameservers_json},
    "os_id": "${os_id}",
    "arch": "${arch}"
}
VARSEOF

    # --- Render user-data template ---
    ansible localhost -m template \
        -a "src='${template_file}' dest='${output_dir}/user-data'" \
        -e "@${vars_file}" \
        --connection=local \
        2>/dev/null \
    || log_fatal "Failed to render user-data template for ${hostname}"

    # --- Render meta-data template ---
    if [[ -f "$meta_template" ]]; then
        ansible localhost -m template \
            -a "src='${meta_template}' dest='${output_dir}/meta-data'" \
            -e "@${vars_file}" \
            --connection=local \
            2>/dev/null \
        || log_fatal "Failed to render meta-data template for ${hostname}"
    else
        # Fallback: generate meta-data directly
        cat > "${output_dir}/meta-data" <<METAEOF
instance-id: ${hostname}
local-hostname: ${hostname}
METAEOF
    fi

    # --- Create empty vendor-data (required by cloud-init but can be empty) ---
    echo "" > "${output_dir}/vendor-data"

    log_info "  -> ${output_dir}/user-data"
    log_info "  -> ${output_dir}/meta-data"
    log_info "  -> ${output_dir}/vendor-data"
}

# Resolve a field with server-override -> defaults -> fallback priority
_resolve_field() {
    local spec_file="$1" idx="$2" field="$3" fallback="$4"
    local value
    value="$(_spec_read "$spec_file" ".servers[$idx].${field} // .defaults.${field} // null")"
    if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
        echo "$fallback"
    else
        echo "$value"
    fi
}

# ---------------------------------------------------------------------------
# If executed directly (not sourced), run generate_autoinstall with args
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <project_dir>" >&2
        exit 1
    fi
    generate_autoinstall "$1"
fi
