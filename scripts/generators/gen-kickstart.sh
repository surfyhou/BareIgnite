#!/usr/bin/env bash
# gen-kickstart.sh -- Generate RHEL-family kickstart configs from spec
#
# Supports: Rocky 8/9, CentOS 7, RHEL 7/8/9, Kylin V10, NeoKylin, UOS
# For each matching server, renders the appropriate kickstart template
# to generated/kickstart/{hostname}.ks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAREIGNITE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source shared libraries
source "${BAREIGNITE_ROOT}/scripts/lib/common.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/spec-parser.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/os-detection.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/mac-utils.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/template-engine.sh"

# ---------------------------------------------------------------------------
# generate_kickstart
#   Generate a kickstart file for a single RHEL-family server.
#
# Arguments:
#   $1 - spec_file      Path to the project spec file
#   $2 - server_index   Index of the server in spec servers[]
#   $3 - generated_dir  Path to the project generated/ directory
#   $4 - control_ip     Control node IP address
# ---------------------------------------------------------------------------
generate_kickstart() {
    local spec_file="$1"
    local idx="$2"
    local generated_dir="$3"
    local control_ip="$4"

    # --- Extract server fields ---
    local hostname os_id arch role
    hostname="$(spec_get "$spec_file" ".servers[$idx].name")"
    os_id="$(spec_get "$spec_file" ".servers[$idx].os")"
    arch="$(spec_get "$spec_file" ".servers[$idx].arch // \"x86_64\"")"
    role="$(spec_get "$spec_file" ".servers[$idx].role // \"generic\"")"

    # Validate this is a kickstart-compatible OS
    if ! is_known_os "$os_id"; then
        log_warn "Unknown OS '${os_id}' for server '${hostname}' -- skipping kickstart"
        return 0
    fi

    local method
    method="$(get_install_method "$os_id")"
    if [[ "$method" != "kickstart" ]]; then
        return 0
    fi

    log_info "Generating kickstart for ${hostname} (${os_id}, ${arch})"

    # --- Determine template ---
    local template_name
    template_name="$(_select_ks_template "$os_id")"
    local template_file="${BAREIGNITE_ROOT}/templates/kickstart/${template_name}"

    if [[ ! -f "$template_file" ]]; then
        log_error "Kickstart template not found: ${template_file} -- skipping ${hostname}"
        return 1
    fi

    # --- Resolve values (server -> defaults -> fallbacks) ---
    local locale timezone root_password boot_mode
    locale="$(_ks_resolve_field "$spec_file" "$idx" "locale" "en_US.UTF-8")"
    timezone="$(_ks_resolve_field "$spec_file" "$idx" "timezone" "UTC")"
    root_password="$(_ks_resolve_field "$spec_file" "$idx" "root_password" "")"
    boot_mode="$(_ks_resolve_field "$spec_file" "$idx" "boot_mode" "uefi")"

    # ARM64 forces UEFI
    if [[ "$arch" == "aarch64" ]]; then
        boot_mode="uefi"
    fi

    # SSH keys: merge server-level and default-level
    local ssh_keys_json
    ssh_keys_json="$(spec_get_object "$spec_file" "
        (.servers[$idx].ssh_keys // .defaults.ssh_keys // [])
    " 2>/dev/null || echo '[]')"

    # PXE MAC address
    local pxe_mac
    pxe_mac="$(spec_get "$spec_file" "
        .servers[$idx].mac_addresses.pxe_boot //
        .servers[$idx].mac_addresses.ipmi
    ")"
    pxe_mac="$(normalize_mac "$pxe_mac")"

    # Extra packages
    local extra_packages_json
    extra_packages_json="$(spec_get_object "$spec_file" "
        (.servers[$idx].extra_packages // [])
    " 2>/dev/null || echo '[]')"

    # Partition scheme
    local partition_scheme
    partition_scheme="$(spec_get "$spec_file" "
        .servers[$idx].disk_layout.scheme //
        .defaults.partition_scheme //
        \"generic\"
    ")"

    # Partition template path (relative to templates/ for Jinja2 include)
    local partition_template="partitions/${partition_scheme}.part.j2"
    local partition_template_abs="${BAREIGNITE_ROOT}/templates/${partition_template}"

    if [[ ! -f "$partition_template_abs" ]]; then
        log_warn "Partition template not found: ${partition_template_abs} -- using generic"
        partition_template="partitions/generic.part.j2"
    fi

    # NTP servers
    local ntp_json
    ntp_json="$(spec_get_object "$spec_file" "
        .defaults.ntp_servers // []
    " 2>/dev/null || echo '[]')"

    # Nameservers
    local nameservers_json
    nameservers_json="$(spec_get_object "$spec_file" "
        .defaults.nameservers // []
    " 2>/dev/null || echo '[]')"

    # HTTP server URL for installer
    local http_port="${HTTP_PORT:-8080}"
    local http_server="http://${control_ip}:${http_port}"

    # Callback URL
    local callback_port="${CALLBACK_PORT:-8888}"

    # --- Build vars file for Ansible template rendering ---
    local output_dir="${generated_dir}/kickstart"
    mkdir -p "$output_dir"

    local vars_file="${output_dir}/.${hostname}-vars.json"
    cat > "$vars_file" <<VARSEOF
{
    "hostname": "${hostname}",
    "os_id": "${os_id}",
    "arch": "${arch}",
    "role": "${role}",
    "locale": "${locale}",
    "timezone": "${timezone}",
    "root_password": "${root_password}",
    "boot_mode": "${boot_mode}",
    "ssh_keys": ${ssh_keys_json},
    "pxe_mac": "${pxe_mac}",
    "extra_packages": ${extra_packages_json},
    "partition_scheme": "${partition_scheme}",
    "partition_template": "${partition_template}",
    "ntp_servers": ${ntp_json},
    "nameservers": ${nameservers_json},
    "http_server": "${http_server}",
    "control_ip": "${control_ip}",
    "http_port": "${http_port}",
    "callback_port": "${callback_port}"
}
VARSEOF

    # --- Render kickstart template ---
    local output_file="${output_dir}/${hostname}.ks"

    render_template_with_file "$template_file" "$output_file" "$vars_file"
    log_info "  -> ${output_file}"
}

# ---------------------------------------------------------------------------
# _select_ks_template
#   Map an os_id to the correct kickstart template filename.
# ---------------------------------------------------------------------------
_select_ks_template() {
    local os_id="$1"

    case "$os_id" in
        rocky9|rhel9)       echo "rhel9-base.ks.j2" ;;
        rocky8|rhel8)       echo "rhel8-base.ks.j2" ;;
        centos7|rhel7)      echo "rhel7-base.ks.j2" ;;
        kylin-v10|kylin_v10) echo "kylin-v10.ks.j2" ;;
        neokylin)           echo "neokylin.ks.j2" ;;
        uos)                echo "uos.ks.j2" ;;
        *)
            # Fall back to matching by version from os_catalog
            local version
            version="$(get_os_version "$os_id" 2>/dev/null || echo "")"
            case "$version" in
                9|9.*)  echo "rhel9-base.ks.j2" ;;
                8|8.*)  echo "rhel8-base.ks.j2" ;;
                7|7.*)  echo "rhel7-base.ks.j2" ;;
                *)      echo "rhel9-base.ks.j2" ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _ks_resolve_field
#   Resolve a field with server-override -> defaults -> fallback priority.
# ---------------------------------------------------------------------------
_ks_resolve_field() {
    local spec_file="$1" idx="$2" field="$3" fallback="$4"
    local value
    value="$(spec_get "$spec_file" ".servers[$idx].${field} // .defaults.${field} // null")"
    if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
        echo "$fallback"
    else
        echo "$value"
    fi
}

# ---------------------------------------------------------------------------
# If executed directly, process all kickstart servers in a project
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <project_dir>" >&2
        exit 1
    fi

    project_dir="$1"
    spec_file="$(find_spec_file "$project_dir")"
    generated_dir="${project_dir}/generated"
    mkdir -p "${generated_dir}/kickstart"

    # Source bareignite.conf
    [[ -f "${BAREIGNITE_ROOT}/conf/bareignite.conf" ]] && source "${BAREIGNITE_ROOT}/conf/bareignite.conf"
    control_ip="${CONTROL_IP:-10.0.1.1}"

    server_count="$(spec_server_count "$spec_file")"
    for ((i = 0; i < server_count; i++)); do
        generate_kickstart "$spec_file" "$i" "$generated_dir" "$control_ip"
    done
fi
