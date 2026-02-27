#!/usr/bin/env bash
# generate-configs.sh -- Master configuration generator for BareIgnite
#
# Reads the project spec file and generates all provisioning configs:
#   1. dnsmasq.conf (DHCP + TFTP + DNS)
#   2. Per-host DHCP static reservations
#   3. nginx.conf (HTTP server)
#   4. Per-server kickstart / autoinstall / ESXi / Windows configs
#   5. Per-server PXE / GRUB boot menus
#   6. Ansible inventory
#
# Usage:
#   generate-configs.sh <project_dir_or_spec_file>
#
# Can also be invoked via: bareignite.sh generate <project>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAREIGNITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Set TOOLS_BIN for generators that use yq/jq directly
TOOLS_BIN="${BAREIGNITE_ROOT}/tools/bin"
export TOOLS_BIN

# Source shared libraries
source "${BAREIGNITE_ROOT}/scripts/lib/common.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/spec-parser.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/mac-utils.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/os-detection.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/network-utils.sh"
source "${BAREIGNITE_ROOT}/scripts/lib/template-engine.sh"

# Source generators
source "${BAREIGNITE_ROOT}/scripts/generators/gen-kickstart.sh"
source "${BAREIGNITE_ROOT}/scripts/generators/gen-pxe-menu.sh"

# Source optional generators (may not exist yet for all phases)
if [[ -f "${BAREIGNITE_ROOT}/scripts/generators/gen-autoinstall.sh" ]]; then
    source "${BAREIGNITE_ROOT}/scripts/generators/gen-autoinstall.sh"
fi
if [[ -f "${BAREIGNITE_ROOT}/scripts/generators/gen-esxi-ks.sh" ]]; then
    source "${BAREIGNITE_ROOT}/scripts/generators/gen-esxi-ks.sh"
fi
if [[ -f "${BAREIGNITE_ROOT}/scripts/generators/gen-winpe.sh" ]]; then
    source "${BAREIGNITE_ROOT}/scripts/generators/gen-winpe.sh"
fi

# ---------------------------------------------------------------------------
# get_control_ip <project_dir>
#
# Determine the control node IP address.
# Priority: bareignite.conf CONTROL_IP -> spec network.ipmi.gateway -> fallback
# ---------------------------------------------------------------------------
get_control_ip() {
    local project_dir="$1"

    # Try bareignite.conf
    local conf_file="${BAREIGNITE_ROOT}/conf/bareignite.conf"
    if [[ -f "$conf_file" ]]; then
        source "$conf_file"
        if [[ -n "${CONTROL_IP:-}" ]]; then
            echo "$CONTROL_IP"
            return 0
        fi
    fi

    # Try spec file: use the IPMI gateway as the control IP
    # (control node typically sits on the IPMI network)
    local spec_file
    spec_file="$(find_spec_file "$project_dir")"
    local gateway
    gateway="$(spec_get "$spec_file" '.network.ipmi.gateway')"
    if [[ -n "$gateway" ]]; then
        echo "$gateway"
        return 0
    fi

    # Fallback
    log_warn "Cannot determine control IP, using 10.0.1.1"
    echo "10.0.1.1"
}

# ---------------------------------------------------------------------------
# generate_dnsmasq_conf
#   Render dnsmasq.conf from the Jinja2 template.
# ---------------------------------------------------------------------------
generate_dnsmasq_conf() {
    local spec_file="$1"
    local generated_dir="$2"
    local control_ip="$3"

    local template="${BAREIGNITE_ROOT}/conf/dnsmasq.conf.j2"
    local output="${generated_dir}/dnsmasq.conf"

    if [[ ! -f "$template" ]]; then
        log_warn "dnsmasq.conf.j2 template not found -- skipping"
        return 0
    fi

    # Extract network config from spec
    local subnet gateway dhcp_range dns_server
    subnet="$(spec_get "$spec_file" '.network.ipmi.subnet')"
    gateway="$(spec_get "$spec_file" '.network.ipmi.gateway')"
    dhcp_range="$(spec_get "$spec_file" '.network.ipmi.dhcp_range')"
    dns_server="$(spec_get "$spec_file" '.network.ipmi.dns')"

    # Parse CIDR for netmask
    local prefix netmask
    prefix="${subnet#*/}"
    netmask="$(cidr_to_netmask "$prefix")"

    # DHCP range: may be "start,end" or separate fields
    local dhcp_range_start dhcp_range_end
    if [[ "$dhcp_range" == *","* ]]; then
        dhcp_range_start="${dhcp_range%%,*}"
        dhcp_range_end="${dhcp_range##*,}"
    else
        dhcp_range_start="$(spec_get "$spec_file" '.network.ipmi.dhcp_range_start')"
        dhcp_range_end="$(spec_get "$spec_file" '.network.ipmi.dhcp_range_end')"
    fi

    # Interface and TFTP root
    local interface tftp_root http_port domain
    interface="${IPMI_INTERFACE:-eth0}"
    tftp_root="${BAREIGNITE_ROOT}/pxe"
    http_port="${HTTP_PORT:-8080}"
    domain="bareignite.local"

    # Build vars file for template rendering
    local vars_file="${generated_dir}/.dnsmasq-vars.json"
    cat > "$vars_file" <<VARSEOF
{
    "control_interface": "${interface}",
    "control_ip": "${control_ip}",
    "domain": "${domain}",
    "dhcp_range_start": "${dhcp_range_start}",
    "dhcp_range_end": "${dhcp_range_end}",
    "netmask": "${netmask}",
    "gateway": "${gateway}",
    "dns_server": "${dns_server:-${control_ip}}",
    "dhcp_hosts_dir": "${generated_dir}/dhcp-hosts",
    "tftp_root": "${tftp_root}",
    "bareignite_root": "${BAREIGNITE_ROOT}",
    "project_generated": "${generated_dir}",
    "project_logs": "$(dirname "$generated_dir")/logs",
    "http_port": "${http_port}"
}
VARSEOF

    render_template_with_file "$template" "$output" "$vars_file"
}

# ---------------------------------------------------------------------------
# generate_dhcp_hosts
#   Generate per-host DHCP static reservation files for dnsmasq.
# ---------------------------------------------------------------------------
generate_dhcp_hosts() {
    local spec_file="$1"
    local generated_dir="$2"

    local hosts_dir="${generated_dir}/dhcp-hosts"
    mkdir -p "$hosts_dir"

    local server_count
    server_count="$(spec_server_count "$spec_file")"

    for ((i = 0; i < server_count; i++)); do
        local hostname os_id mac_raw ipmi_ip
        hostname="$(spec_get "$spec_file" ".servers[$i].name")"
        os_id="$(spec_get "$spec_file" ".servers[$i].os")"

        # Get PXE boot MAC (prefer pxe_boot, fall back to ipmi)
        mac_raw="$(spec_get "$spec_file" ".servers[$i].mac_addresses.pxe_boot")"
        if [[ -z "$mac_raw" ]] || [[ "$mac_raw" == "null" ]]; then
            mac_raw="$(spec_get "$spec_file" ".servers[$i].mac_addresses.ipmi")"
        fi

        # Get IPMI static IP (if assigned)
        ipmi_ip="$(spec_get "$spec_file" ".servers[$i].ipmi.ip")"
        if [[ -z "$ipmi_ip" ]] || [[ "$ipmi_ip" == "null" ]]; then
            ipmi_ip="$(spec_get "$spec_file" ".servers[$i].network.ipmi.ip")"
        fi

        local mac
        mac="$(normalize_mac "$mac_raw")"

        local host_file="${hosts_dir}/${hostname}.conf"

        if [[ -n "$ipmi_ip" ]] && [[ "$ipmi_ip" != "null" ]]; then
            cat > "$host_file" <<EOF
# ${hostname}: ${os_id}
dhcp-host=${mac},${ipmi_ip},${hostname}
EOF
        else
            cat > "$host_file" <<EOF
# ${hostname}: ${os_id}
dhcp-host=${mac},${hostname}
EOF
        fi

        log_debug "DHCP host entry: ${hostname} (${mac})"
    done

    log_info "Generated ${server_count} DHCP host reservation(s) in dhcp-hosts/"
}

# ---------------------------------------------------------------------------
# generate_nginx_conf
#   Render nginx.conf from the Jinja2 template.
# ---------------------------------------------------------------------------
generate_nginx_conf() {
    local spec_file="$1"
    local generated_dir="$2"
    local control_ip="$3"

    local template="${BAREIGNITE_ROOT}/conf/nginx.conf.j2"
    local output="${generated_dir}/nginx.conf"

    if [[ ! -f "$template" ]]; then
        log_warn "nginx.conf.j2 template not found -- skipping"
        return 0
    fi

    local http_port="${HTTP_PORT:-8080}"
    local project_dir
    project_dir="$(dirname "$generated_dir")"
    local domain="bareignite.local"

    local vars_file="${generated_dir}/.nginx-vars.json"
    cat > "$vars_file" <<VARSEOF
{
    "control_ip": "${control_ip}",
    "http_port": "${http_port}",
    "domain": "${domain}",
    "bareignite_root": "${BAREIGNITE_ROOT}",
    "project_generated": "${generated_dir}",
    "project_logs": "${project_dir}/logs",
    "images_dir": "${BAREIGNITE_ROOT}/images"
}
VARSEOF

    render_template_with_file "$template" "$output" "$vars_file"
}

# ---------------------------------------------------------------------------
# generate_server_configs
#   Iterate servers and call the appropriate OS-family generator for each.
#   Kickstart configs are generated per-server; autoinstall, ESXi, and Windows
#   generators process all servers internally, so they are called once.
# ---------------------------------------------------------------------------
generate_server_configs() {
    local spec_file="$1"
    local generated_dir="$2"
    local control_ip="$3"

    local server_count
    server_count="$(spec_server_count "$spec_file")"
    local ks_count=0 skip_count=0
    local has_autoinstall=false has_esxi=false has_windows=false

    # Pass 1: Generate kickstart configs per-server, track other families
    for ((i = 0; i < server_count; i++)); do
        local hostname os_id
        hostname="$(spec_get "$spec_file" ".servers[$i].name")"
        os_id="$(spec_get "$spec_file" ".servers[$i].os")"

        if ! is_known_os "$os_id"; then
            log_warn "Unknown OS '${os_id}' for server '${hostname}' -- skipping"
            ((skip_count++)) || true
            continue
        fi

        local method
        method="$(get_install_method "$os_id")"

        case "$method" in
            kickstart)
                generate_kickstart "$spec_file" "$i" "$generated_dir" "$control_ip"
                ((ks_count++)) || true
                ;;
            autoinstall)
                has_autoinstall=true
                ;;
            esxi-kickstart|esxi_kickstart)
                has_esxi=true
                ;;
            winpe)
                has_windows=true
                ;;
            *)
                log_warn "Unsupported install method '${method}' for ${hostname} -- skipping"
                ((skip_count++)) || true
                ;;
        esac
    done

    # Pass 2: Call bulk generators once for each OS family that needs it
    local auto_count=0 esxi_count=0 win_count=0
    local project_dir
    project_dir="$(dirname "$generated_dir")"

    if [[ "$has_autoinstall" == "true" ]] && declare -f generate_autoinstall &>/dev/null; then
        generate_autoinstall "$project_dir"
        auto_count=1
    fi

    if [[ "$has_esxi" == "true" ]] && declare -f generate_esxi_kickstart &>/dev/null; then
        generate_esxi_kickstart "$project_dir"
        esxi_count=1
    fi

    if [[ "$has_windows" == "true" ]] && declare -f generate_all_windows_configs &>/dev/null; then
        generate_all_windows_configs "$spec_file" "$generated_dir" "$control_ip"
        win_count=1
    fi

    log_info "Server config generation summary:"
    log_info "  Kickstart (RHEL family): ${ks_count}"
    log_info "  Autoinstall (Ubuntu):    ${auto_count}"
    log_info "  ESXi kickstart:          ${esxi_count}"
    log_info "  Windows PE:              ${win_count}"
    if ((skip_count > 0)); then
        log_warn "  Skipped:                 ${skip_count}"
    fi
}

# ---------------------------------------------------------------------------
# generate_pxe_configs
#   Generate PXE/GRUB boot configs for all servers, plus default menus.
# ---------------------------------------------------------------------------
generate_pxe_configs() {
    local spec_file="$1"
    local generated_dir="$2"
    local control_ip="$3"

    local server_count
    server_count="$(spec_server_count "$spec_file")"

    for ((i = 0; i < server_count; i++)); do
        generate_pxe_config "$spec_file" "$i" "$generated_dir" "$control_ip"
    done

    # Generate default menus (boot from local disk)
    generate_default_menu "$generated_dir"

    log_info "PXE/GRUB configs generated for ${server_count} server(s)"
}

# ---------------------------------------------------------------------------
# generate_ansible_inventory
#   Produce an Ansible INI inventory from the spec file.
# ---------------------------------------------------------------------------
generate_ansible_inventory() {
    local spec_file="$1"
    local generated_dir="$2"

    local output_dir="${generated_dir}/ansible"
    mkdir -p "$output_dir"
    local output="${output_dir}/inventory.ini"

    local server_count
    server_count="$(spec_server_count "$spec_file")"

    # Collect servers by role
    declare -A role_servers

    for ((i = 0; i < server_count; i++)); do
        local hostname role os_id arch ipmi_ip data_ip
        hostname="$(spec_get "$spec_file" ".servers[$i].name")"
        role="$(spec_get "$spec_file" ".servers[$i].role")"
        os_id="$(spec_get "$spec_file" ".servers[$i].os")"
        arch="$(spec_get "$spec_file" ".servers[$i].arch")"

        # IPMI IP (for ansible_host during provisioning phase)
        ipmi_ip="$(spec_get "$spec_file" ".servers[$i].ipmi.ip")"
        if [[ -z "$ipmi_ip" ]] || [[ "$ipmi_ip" == "null" ]]; then
            ipmi_ip="$(spec_get "$spec_file" ".servers[$i].network.ipmi.ip")"
        fi

        # First data network IP
        data_ip="$(spec_get "$spec_file" ".servers[$i].networks[0].ip")"
        if [[ -z "$data_ip" ]] || [[ "$data_ip" == "null" ]]; then
            data_ip="$(spec_get "$spec_file" ".servers[$i].network.data[0].ip")"
        fi

        # Determine OS family
        local family=""
        if is_known_os "$os_id"; then
            family="$(get_os_family "$os_id")"
        fi

        # Build host line
        local host_line="${hostname}"
        if [[ -n "$ipmi_ip" ]] && [[ "$ipmi_ip" != "null" ]]; then
            host_line+=" ansible_host=${ipmi_ip}"
        fi
        if [[ -n "$data_ip" ]] && [[ "$data_ip" != "null" ]]; then
            host_line+=" data_ip=${data_ip}"
        fi
        host_line+=" os_id=${os_id} os_family=${family} arch=${arch}"

        # Add Windows-specific connection vars
        if [[ "$family" == "windows" ]]; then
            host_line+=" ansible_connection=winrm ansible_winrm_transport=basic"
        fi

        # Append to role group
        if [[ -n "${role_servers[$role]:-}" ]]; then
            role_servers[$role]+=$'\n'"${host_line}"
        else
            role_servers[$role]="${host_line}"
        fi
    done

    # Write inventory file
    {
        echo "# BareIgnite generated Ansible inventory"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "[all:vars]"
        echo "ansible_user=root"
        echo "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
        echo ""

        # Write per-role groups
        for role in $(echo "${!role_servers[@]}" | tr ' ' '\n' | sort); do
            echo "[${role}]"
            echo "${role_servers[$role]}"
            echo ""
        done

        # Write OS-family meta groups
        echo "# --- OS family meta-groups ---"
        local rhel_roles="" debian_roles="" esxi_roles="" windows_roles=""
        for role in "${!role_servers[@]}"; do
            # Check first server in this role group for family
            local first_line="${role_servers[$role]%%$'\n'*}"
            if [[ "$first_line" == *"os_family=rhel"* ]]; then
                rhel_roles+="${role} "
            elif [[ "$first_line" == *"os_family=debian"* ]]; then
                debian_roles+="${role} "
            elif [[ "$first_line" == *"os_family=esxi"* ]]; then
                esxi_roles+="${role} "
            elif [[ "$first_line" == *"os_family=windows"* ]]; then
                windows_roles+="${role} "
            fi
        done

        if [[ -n "$rhel_roles" ]]; then
            echo ""
            echo "[rhel:children]"
            for r in $rhel_roles; do echo "$r"; done
        fi
        if [[ -n "$debian_roles" ]]; then
            echo ""
            echo "[debian:children]"
            for r in $debian_roles; do echo "$r"; done
        fi
        if [[ -n "$esxi_roles" ]]; then
            echo ""
            echo "[esxi:children]"
            for r in $esxi_roles; do echo "$r"; done
        fi
        if [[ -n "$windows_roles" ]]; then
            echo ""
            echo "[windows:children]"
            for r in $windows_roles; do echo "$r"; done
        fi
    } > "$output"

    log_info "Generated Ansible inventory: ansible/inventory.ini"
}

# ---------------------------------------------------------------------------
# print_summary
#   Display a summary of everything that was generated.
# ---------------------------------------------------------------------------
print_summary() {
    local generated_dir="$1"

    print_separator "="
    log_info "Configuration generation complete!"
    print_separator "-"
    echo ""
    echo "Generated directory: ${generated_dir}/"
    echo ""

    # Count generated files
    local ks_count pxe_count dhcp_count
    ks_count=$(find "$generated_dir/kickstart" -name '*.ks' 2>/dev/null | wc -l | tr -d ' ')
    pxe_count=$(find "$generated_dir/pxelinux.cfg" "$generated_dir/grub.cfg" -type f 2>/dev/null | wc -l | tr -d ' ')
    dhcp_count=$(find "$generated_dir/dhcp-hosts" -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')

    echo "  Files generated:"
    [[ -f "$generated_dir/dnsmasq.conf" ]]      && echo "    - dnsmasq.conf"
    [[ -f "$generated_dir/nginx.conf" ]]         && echo "    - nginx.conf"
    echo "    - ${dhcp_count} DHCP host reservation(s)"
    echo "    - ${ks_count} kickstart file(s)"
    echo "    - ${pxe_count} PXE/GRUB boot config(s)"
    [[ -f "$generated_dir/ansible/inventory.ini" ]] && echo "    - ansible/inventory.ini"

    # List autoinstall dirs if present
    if [[ -d "$generated_dir/autoinstall" ]]; then
        local auto_count
        auto_count=$(find "$generated_dir/autoinstall" -name 'user-data' 2>/dev/null | wc -l | tr -d ' ')
        echo "    - ${auto_count} autoinstall config(s)"
    fi

    # ESXi
    if [[ -d "$generated_dir/esxi" ]]; then
        local esxi_count
        esxi_count=$(find "$generated_dir/esxi" -name '*.cfg' 2>/dev/null | wc -l | tr -d ' ')
        echo "    - ${esxi_count} ESXi kickstart(s)"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Review generated configs in ${generated_dir}/"
    echo "  2. Run: bareignite.sh start <project>"
    echo ""
    print_separator "="
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
main() {
    local input="${1:?Usage: generate-configs.sh <project_dir_or_spec_file>}"

    # Determine project dir and spec file
    local project_dir spec_file

    if [[ -f "$input" ]]; then
        # Input is a spec file
        spec_file="$input"
        project_dir="$(dirname "$spec_file")"
    elif [[ -d "$input" ]]; then
        # Input is a project directory
        project_dir="$(get_project_dir "$input")"
        spec_file="$(find_spec_file "$project_dir")"
    else
        # Try as project name
        project_dir="$(get_project_dir "$input")"
        spec_file="$(find_spec_file "$project_dir")"
    fi

    set_project_paths "$project_dir"

    # Load bareignite.conf defaults
    if [[ -f "${BAREIGNITE_ROOT}/conf/bareignite.conf" ]]; then
        source "${BAREIGNITE_ROOT}/conf/bareignite.conf"
    fi

    local control_ip
    control_ip="$(get_control_ip "$project_dir")"

    log_info "BareIgnite Configuration Generator"
    log_info "Project:    $(basename "$project_dir")"
    log_info "Spec file:  ${spec_file}"
    log_info "Control IP: ${control_ip}"
    print_separator "-"

    # Create generated directory structure
    local generated_dir="${project_dir}/generated"
    ensure_dir "$generated_dir"
    ensure_dir "${generated_dir}/kickstart"
    ensure_dir "${generated_dir}/dhcp-hosts"
    ensure_dir "${generated_dir}/pxelinux.cfg"
    ensure_dir "${generated_dir}/grub.cfg"
    ensure_dir "${generated_dir}/ansible"
    ensure_dir "${project_dir}/logs"

    # --- Step 1: Generate dnsmasq config ---
    log_info "Step 1/6: Generating dnsmasq configuration..."
    generate_dnsmasq_conf "$spec_file" "$generated_dir" "$control_ip"

    # --- Step 2: Generate per-host DHCP entries ---
    log_info "Step 2/6: Generating DHCP host reservations..."
    generate_dhcp_hosts "$spec_file" "$generated_dir"

    # --- Step 3: Generate nginx config ---
    log_info "Step 3/6: Generating nginx configuration..."
    generate_nginx_conf "$spec_file" "$generated_dir" "$control_ip"

    # --- Step 4: Generate per-server OS install configs ---
    log_info "Step 4/6: Generating OS installation configs..."
    generate_server_configs "$spec_file" "$generated_dir" "$control_ip"

    # --- Step 5: Generate PXE/GRUB menus ---
    log_info "Step 5/6: Generating PXE/GRUB boot menus..."
    generate_pxe_configs "$spec_file" "$generated_dir" "$control_ip"

    # --- Step 6: Generate Ansible inventory ---
    log_info "Step 6/6: Generating Ansible inventory..."
    generate_ansible_inventory "$spec_file" "$generated_dir"

    # --- Summary ---
    print_summary "$generated_dir"
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
