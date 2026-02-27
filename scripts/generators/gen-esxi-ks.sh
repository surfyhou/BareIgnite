#!/usr/bin/env bash
# gen-esxi-ks.sh -- Generate ESXi kickstart configs from spec
# ESXi uses a simplified kickstart format. UEFI-only (ESXi 7+).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---------------------------------------------------------------------------
# generate_esxi_kickstart -- Main entry point
#
# Arguments:
#   $1 -- project directory (contains spec.yaml/json and generated/ output)
#
# For each server whose OS family is "esxi", this function:
#   1. Validates the server is configured for UEFI boot
#   2. Selects the correct template (esxi7 or esxi8)
#   3. Renders the kickstart config via Ansible Jinja2
#   4. Writes output to generated/esxi/{hostname}.cfg
# ---------------------------------------------------------------------------
generate_esxi_kickstart() {
    local project_dir="$1"
    local spec_file
    spec_file="$(find_spec_file "$project_dir")"

    local output_base="${project_dir}/generated/esxi"
    mkdir -p "$output_base"

    local server_count
    server_count="$(_spec_read "$spec_file" '.servers | length')"

    local generated=0
    for (( i=0; i<server_count; i++ )); do
        local os_id
        os_id="$(_spec_read "$spec_file" ".servers[$i].os")"

        local family
        family="$(_spec_read "$spec_file" ".os_catalog.${os_id}.family // \"unknown\"")"

        # Only process esxi-family servers
        if [[ "$family" != "esxi" ]]; then
            continue
        fi

        _generate_server_esxi_ks "$spec_file" "$i" "$os_id" "$output_base"
        (( generated++ ))
    done

    if (( generated == 0 )); then
        log_info "No ESXi servers found in spec -- skipping"
    else
        log_info "Generated ESXi kickstart configs for ${generated} server(s)"
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

# Generate ESXi kickstart for a single server
_generate_server_esxi_ks() {
    local spec_file="$1"
    local idx="$2"
    local os_id="$3"
    local output_base="$4"

    # --- Extract server fields ---
    local hostname
    hostname="$(_spec_read "$spec_file" ".servers[$idx].name")"

    local arch
    arch="$(_spec_read "$spec_file" ".servers[$idx].arch // \"x86_64\"")"

    # --- Validate UEFI boot mode ---
    # ESXi 7+ requires UEFI. Reject BIOS boot mode.
    local boot_mode
    boot_mode="$(_spec_read "$spec_file" "
        .servers[$idx].boot_mode //
        .defaults.boot_mode //
        \"uefi\"
    ")"

    if [[ "$boot_mode" == "bios" ]]; then
        log_error "ESXi requires UEFI boot mode but server '${hostname}' is set to BIOS -- skipping"
        return 1
    fi

    # Force UEFI for ESXi regardless of "auto" setting
    boot_mode="uefi"

    # --- Determine template ---
    local template_path
    template_path="$(_spec_read "$spec_file" ".os_catalog.${os_id}.template")"

    if [[ -z "$template_path" ]] || [[ "$template_path" == "null" ]]; then
        log_error "No template defined for OS '${os_id}' -- skipping ${hostname}"
        return 1
    fi

    local template_file="${BAREIGNITE_ROOT}/${template_path}"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: ${template_file} -- skipping ${hostname}"
        return 1
    fi

    # --- Resolve values ---
    # ESXi uses plaintext root password (not hashed)
    local root_password
    root_password="$(_resolve_field "$spec_file" "$idx" "root_password" "")"

    local hostname_fqdn="$hostname"

    # PXE MAC address
    local pxe_mac
    pxe_mac="$(_spec_read "$spec_file" "
        .servers[$idx].mac_addresses.pxe_boot //
        .servers[$idx].mac_addresses.ipmi
    ")"
    pxe_mac="$(echo "$pxe_mac" | tr '[:upper:]' '[:lower:]')"

    # Network configuration -- check for static IP on data network
    local static_ip="" netmask="" gateway="" vlan=""

    # Try to get static IP from the first data NIC configuration
    local data_nic_count
    data_nic_count="$(_spec_read "$spec_file" ".servers[$idx].network.data | length" 2>/dev/null || echo "0")"

    if [[ "$data_nic_count" != "null" ]] && (( data_nic_count > 0 )); then
        local data_mode
        data_mode="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].mode // \"dhcp\"")"

        if [[ "$data_mode" == "static" ]]; then
            static_ip="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].ip // \"\"")"
            local prefix
            prefix="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].prefix // 24")"
            netmask="$(_prefix_to_netmask "$prefix")"
            gateway="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].gateway // \"\"")"

            # If per-NIC gateway not set, try the network-level gateway
            if [[ -z "$gateway" ]] || [[ "$gateway" == "null" ]]; then
                local net_name
                net_name="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].network // \"\"")"
                if [[ -n "$net_name" ]] && [[ "$net_name" != "null" ]]; then
                    gateway="$(_spec_read "$spec_file" "
                        .network.data[] | select(.name == \"${net_name}\") | .gateway // \"\"
                    ")"
                fi
            fi
        fi

        # VLAN (optional)
        local net_name
        net_name="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].network // \"\"")"
        if [[ -n "$net_name" ]] && [[ "$net_name" != "null" ]]; then
            vlan="$(_spec_read "$spec_file" "
                .network.data[] | select(.name == \"${net_name}\") | .vlan // \"\"
            ")"
        fi
    fi

    # Install disk (default: first disk with --overwritevmfs)
    local install_disk
    install_disk="$(_spec_read "$spec_file" ".servers[$idx].disk_layout.install_disk // \"firstdisk\"" 2>/dev/null || echo "firstdisk")"

    # Control IP for callback
    local control_ip
    control_ip="$(get_control_ip "$(dirname "$spec_file")")"

    # Callback port
    local callback_port="8888"

    # DNS
    local nameservers_json
    nameservers_json="$(_spec_read "$spec_file" "
        .defaults.nameservers // [] | tojson
    " 2>/dev/null || echo '[]')"

    # ESXi version
    local esxi_version
    esxi_version="$(_spec_read "$spec_file" ".os_catalog.${os_id}.version // \"\"")"

    log_info "Generating ESXi kickstart for ${hostname} (${os_id}, UEFI)"

    # --- Build Ansible extra-vars JSON for template rendering ---
    local vars_file
    vars_file="$(mktemp)"
    trap "rm -f '$vars_file'" RETURN

    cat > "$vars_file" <<VARSEOF
{
    "hostname": "${hostname}",
    "root_password": "${root_password}",
    "pxe_mac": "${pxe_mac}",
    "static_ip": "${static_ip}",
    "netmask": "${netmask}",
    "gateway": "${gateway}",
    "vlan": "${vlan}",
    "install_disk": "${install_disk}",
    "control_ip": "${control_ip}",
    "callback_port": "${callback_port}",
    "nameservers": ${nameservers_json},
    "esxi_version": "${esxi_version}",
    "os_id": "${os_id}",
    "arch": "${arch}",
    "boot_mode": "${boot_mode}"
}
VARSEOF

    # --- Render ESXi kickstart template ---
    local output_file="${output_base}/${hostname}.cfg"

    ansible localhost -m template \
        -a "src='${template_file}' dest='${output_file}'" \
        -e "@${vars_file}" \
        --connection=local \
        2>/dev/null \
    || log_fatal "Failed to render ESXi kickstart template for ${hostname}"

    log_info "  -> ${output_file}"
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

# Convert CIDR prefix length to dotted-decimal netmask
_prefix_to_netmask() {
    local prefix="$1"
    local mask=""
    local full_octets=$(( prefix / 8 ))
    local partial_bits=$(( prefix % 8 ))

    for (( o=0; o<4; o++ )); do
        if (( o < full_octets )); then
            mask="${mask}255"
        elif (( o == full_octets )); then
            mask="${mask}$(( 256 - (1 << (8 - partial_bits)) ))"
        else
            mask="${mask}0"
        fi
        if (( o < 3 )); then
            mask="${mask}."
        fi
    done

    echo "$mask"
}

# ---------------------------------------------------------------------------
# If executed directly (not sourced), run generate_esxi_kickstart with args
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <project_dir>" >&2
        exit 1
    fi
    generate_esxi_kickstart "$1"
fi
