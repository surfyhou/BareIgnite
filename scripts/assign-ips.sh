#!/usr/bin/env bash
# assign-ips.sh -- Post-install data network IP reconfiguration
#
# Reads the project spec file, generates an Ansible inventory using IPMI IPs
# as ansible_host (since data NICs are not yet configured), then runs the
# network-reconfig playbook to set final data network IPs on each server.
#
# Usage:
#   assign-ips.sh <project_dir> [--server <name>] [--verify-only]
#
# Prerequisites:
#   - All target servers must have completed OS installation
#   - SSH must be accessible via the IPMI/provisioning IP
#   - spec file must contain data NIC definitions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/spec-parser.sh
source "${SCRIPT_DIR}/lib/spec-parser.sh"

# --- Usage ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <project_dir> [OPTIONS]

Reconfigure data network IPs on provisioned servers.

Options:
  --server <name>    Only reconfigure a specific server
  --verify-only      Only verify current IP assignments, do not change
  --skip-verify      Skip post-reconfiguration verification
  -h, --help         Show this help message

Examples:
  $(basename "$0") projects/bjdc-phase3
  $(basename "$0") projects/bjdc-phase3 --server db-master-01
  $(basename "$0") bjdc-phase3 --verify-only
EOF
}

# --- Parse arguments ---

PROJECT_INPUT=""
TARGET_SERVER=""
VERIFY_ONLY=false
SKIP_VERIFY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)
            TARGET_SERVER="$2"
            shift 2
            ;;
        --verify-only)
            VERIFY_ONLY=true
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            log_fatal "Unknown option: $1"
            ;;
        *)
            PROJECT_INPUT="$1"
            shift
            ;;
    esac
done

if [[ -z "$PROJECT_INPUT" ]]; then
    log_error "Project directory is required."
    usage
    exit 1
fi

# --- Resolve paths ---

PROJECT_DIR="$(resolve_project_dir "$PROJECT_INPUT")"
SPEC_FILE="$(find_spec_file "$PROJECT_DIR")"
ANSIBLE_DIR="${BAREIGNITE_ROOT}/ansible"
GENERATED_DIR="${PROJECT_DIR}/generated/ansible"
INVENTORY_FILE="${GENERATED_DIR}/inventory-ipmi.ini"
LOGS_DIR="${PROJECT_DIR}/logs"

mkdir -p "$GENERATED_DIR" "$LOGS_DIR"

log_info "Project directory: ${PROJECT_DIR}"
log_info "Spec file: ${SPEC_FILE}"

# --- Generate IPMI-based inventory ---

generate_ipmi_inventory() {
    log_info "Generating IPMI-based Ansible inventory..."

    local server_count
    server_count=$(spec_server_count "$SPEC_FILE")

    cat > "$INVENTORY_FILE" <<HEADER
# BareIgnite IPMI-based inventory for network reconfiguration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Servers connect via IPMI/provisioning IPs

[all:vars]
ansible_user=root
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

HEADER

    # Collect servers by role for group sections
    declare -A role_servers

    for ((i = 0; i < server_count; i++)); do
        local name ipmi_ip os_id os_family role arch
        name=$(spec_server_field "$SPEC_FILE" "$i" "name")
        ipmi_ip=$(spec_server_field "$SPEC_FILE" "$i" "network.ipmi.ip")
        os_id=$(spec_server_field "$SPEC_FILE" "$i" "os")
        role=$(spec_server_field "$SPEC_FILE" "$i" "role")
        arch=$(spec_server_field "$SPEC_FILE" "$i" "arch")

        # Skip null/empty values
        if [[ "$name" == "null" || -z "$name" ]]; then
            log_warn "Server at index $i has no name, skipping"
            continue
        fi

        # Skip Windows and ESXi (limited Ansible support for network reconfig)
        os_family=$(spec_os_family "$SPEC_FILE" "$os_id")
        if [[ "$os_family" == "windows" ]]; then
            log_warn "Skipping Windows server: $name (use manual network config)"
            continue
        fi

        # Apply server filter if specified
        if [[ -n "$TARGET_SERVER" && "$name" != "$TARGET_SERVER" ]]; then
            continue
        fi

        # Collect data NIC info for host_vars
        generate_host_vars "$name" "$i"

        # Add to role group
        if [[ -z "${role_servers[$role]+_}" ]]; then
            role_servers[$role]=""
        fi
        role_servers[$role]+="${name} ansible_host=${ipmi_ip} os_family=${os_family} arch=${arch}"$'\n'
    done

    # Write role groups
    for role in "${!role_servers[@]}"; do
        echo "[${role}]" >> "$INVENTORY_FILE"
        echo "${role_servers[$role]}" >> "$INVENTORY_FILE"
    done

    # Write OS family children groups
    cat >> "$INVENTORY_FILE" <<'GROUPS'
[rhel:children]
database
appserver
hypervisor

[linux:children]
rhel
GROUPS

    log_info "Inventory written to: ${INVENTORY_FILE}"
}

# --- Generate per-host variable files ---

generate_host_vars() {
    local server_name="$1"
    local index="$2"
    local host_vars_dir="${GENERATED_DIR}/host_vars"
    local host_vars_file="${host_vars_dir}/${server_name}.yml"

    mkdir -p "$host_vars_dir"

    log_info "Generating host_vars for ${server_name}..."

    # Start the host vars file
    cat > "$host_vars_file" <<HEADER
---
# Host variables for ${server_name}
# Generated by assign-ips.sh

HEADER

    # Extract data NIC configurations
    local data_nic_count
    data_nic_count=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data | length")

    if [[ "$data_nic_count" == "null" || "$data_nic_count" -eq 0 ]]; then
        echo "network_data_nics: []" >> "$host_vars_file"
    else
        echo "network_data_nics:" >> "$host_vars_file"
        for ((j = 0; j < data_nic_count; j++)); do
            local nic_name nic_mac nic_ip nic_prefix nic_gw nic_mode nic_network
            nic_name=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data[${j}].nic")
            nic_mac=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data[${j}].mac")
            nic_ip=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data[${j}].ip")
            nic_prefix=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data[${j}].prefix")
            nic_gw=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data[${j}].gateway")
            nic_mode=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data[${j}].mode")
            nic_network=$(spec_read "$SPEC_FILE" ".servers[${index}].network.data[${j}].network")

            # Resolve gateway from network definition if not per-NIC
            if [[ "$nic_gw" == "null" || -z "$nic_gw" ]]; then
                nic_gw=$(spec_read "$SPEC_FILE" ".network.data[] | select(.name == \"${nic_network}\") | .gateway")
            fi

            # Resolve DNS from network definition
            local dns_line
            dns_line=$(spec_read "$SPEC_FILE" ".network.data[] | select(.name == \"${nic_network}\") | .dns[]" 2>/dev/null || true)

            cat >> "$host_vars_file" <<NIC
  - name: "${nic_name}"
    device: "${nic_name}"
    mac: "${nic_mac}"
    ip: "${nic_ip}"
    prefix: ${nic_prefix:-24}
    gateway: "${nic_gw:-}"
    mode: "${nic_mode:-static}"
    dns:
NIC
            if [[ -n "$dns_line" ]]; then
                while IFS= read -r dns; do
                    echo "      - \"${dns}\"" >> "$host_vars_file"
                done <<< "$dns_line"
            else
                echo "      []" >> "$host_vars_file"
            fi
        done
    fi

    # Extract bonding configurations
    local bond_count
    bond_count=$(spec_read "$SPEC_FILE" ".servers[${index}].network.bonding | length" 2>/dev/null || echo "0")

    if [[ "$bond_count" == "null" || "$bond_count" -eq 0 ]]; then
        echo "network_bonds: []" >> "$host_vars_file"
    else
        echo "network_bonds:" >> "$host_vars_file"
        for ((j = 0; j < bond_count; j++)); do
            local bond_name bond_mode bond_ip bond_prefix bond_network
            bond_name=$(spec_read "$SPEC_FILE" ".servers[${index}].network.bonding[${j}].name")
            bond_mode=$(spec_read "$SPEC_FILE" ".servers[${index}].network.bonding[${j}].mode")
            bond_ip=$(spec_read "$SPEC_FILE" ".servers[${index}].network.bonding[${j}].ip")
            bond_prefix=$(spec_read "$SPEC_FILE" ".servers[${index}].network.bonding[${j}].prefix")
            bond_network=$(spec_read "$SPEC_FILE" ".servers[${index}].network.bonding[${j}].network")

            # Get bond slaves
            local slaves
            slaves=$(spec_read "$SPEC_FILE" ".servers[${index}].network.bonding[${j}].slaves[]")

            # Resolve gateway from network definition
            local bond_gw
            bond_gw=$(spec_read "$SPEC_FILE" ".network.data[] | select(.name == \"${bond_network}\") | .gateway" 2>/dev/null || echo "")

            cat >> "$host_vars_file" <<BOND
  - name: "${bond_name}"
    mode: "${bond_mode:-802.3ad}"
    ip: "${bond_ip}"
    prefix: ${bond_prefix:-24}
    gateway: "${bond_gw:-}"
    slaves:
BOND
            while IFS= read -r slave; do
                echo "      - \"${slave}\"" >> "$host_vars_file"
            done <<< "$slaves"
        done
    fi

    # VLAN configurations (empty by default; populated from spec if present)
    echo "network_vlans: []" >> "$host_vars_file"
}

# --- Verify IP reachability ---

verify_ips() {
    log_info "Verifying data network IP reachability..."

    local server_count
    server_count=$(spec_server_count "$SPEC_FILE")
    local all_ok=true

    for ((i = 0; i < server_count; i++)); do
        local name os_id os_family
        name=$(spec_server_field "$SPEC_FILE" "$i" "name")
        os_id=$(spec_server_field "$SPEC_FILE" "$i" "os")
        os_family=$(spec_os_family "$SPEC_FILE" "$os_id")

        # Skip Windows
        if [[ "$os_family" == "windows" ]]; then
            continue
        fi

        # Apply server filter
        if [[ -n "$TARGET_SERVER" && "$name" != "$TARGET_SERVER" ]]; then
            continue
        fi

        local data_nic_count
        data_nic_count=$(spec_read "$SPEC_FILE" ".servers[${i}].network.data | length")

        for ((j = 0; j < data_nic_count; j++)); do
            local data_ip
            data_ip=$(spec_read "$SPEC_FILE" ".servers[${i}].network.data[${j}].ip")

            if [[ "$data_ip" == "null" || -z "$data_ip" ]]; then
                continue
            fi

            if ping -c 1 -W 3 "$data_ip" >/dev/null 2>&1; then
                log_info "  ${name} (${data_ip}): ${COLOR_GREEN}REACHABLE${COLOR_RESET}"
            else
                log_warn "  ${name} (${data_ip}): ${COLOR_RED}UNREACHABLE${COLOR_RESET}"
                all_ok=false
            fi
        done
    done

    if $all_ok; then
        log_info "All data network IPs are reachable."
    else
        log_warn "Some data network IPs are not reachable."
    fi

    $all_ok
}

# --- Update inventory with final IPs ---

update_final_inventory() {
    log_info "Generating final inventory with data network IPs..."

    local final_inventory="${GENERATED_DIR}/inventory.ini"
    local server_count
    server_count=$(spec_server_count "$SPEC_FILE")

    cat > "$final_inventory" <<HEADER
# BareIgnite final inventory (data network IPs)
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

[all:vars]
ansible_user=root
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

HEADER

    declare -A role_servers

    for ((i = 0; i < server_count; i++)); do
        local name role os_id os_family arch data_ip ipmi_ip
        name=$(spec_server_field "$SPEC_FILE" "$i" "name")
        role=$(spec_server_field "$SPEC_FILE" "$i" "role")
        os_id=$(spec_server_field "$SPEC_FILE" "$i" "os")
        arch=$(spec_server_field "$SPEC_FILE" "$i" "arch")
        os_family=$(spec_os_family "$SPEC_FILE" "$os_id")
        ipmi_ip=$(spec_server_field "$SPEC_FILE" "$i" "network.ipmi.ip")

        if [[ "$name" == "null" || -z "$name" ]]; then
            continue
        fi

        # Use first data IP as ansible_host, fallback to IPMI IP
        data_ip=$(spec_read "$SPEC_FILE" ".servers[${i}].network.data[0].ip" 2>/dev/null || echo "")
        local ansible_host="${data_ip:-$ipmi_ip}"
        if [[ "$ansible_host" == "null" ]]; then
            ansible_host="$ipmi_ip"
        fi

        local host_line="${name} ansible_host=${ansible_host} data_ip=${data_ip:-} ipmi_ip=${ipmi_ip} os_family=${os_family} arch=${arch}"

        # Windows servers use WinRM
        if [[ "$os_family" == "windows" ]]; then
            host_line+=" ansible_connection=winrm ansible_winrm_transport=basic"
        fi

        if [[ -z "${role_servers[$role]+_}" ]]; then
            role_servers[$role]=""
        fi
        role_servers[$role]+="${host_line}"$'\n'
    done

    for role in "${!role_servers[@]}"; do
        echo "[${role}]" >> "$final_inventory"
        echo "${role_servers[$role]}" >> "$final_inventory"
    done

    # Write group children
    cat >> "$final_inventory" <<'GROUPS'
[rhel:children]
database
appserver

[linux:children]
rhel

[all_linux:children]
linux
hypervisor
GROUPS

    log_info "Final inventory written to: ${final_inventory}"
}

# --- Main ---

main() {
    print_separator "="
    log_info "BareIgnite -- Data Network IP Reconfiguration"
    print_separator "="

    # Generate IPMI-based inventory and host_vars
    generate_ipmi_inventory

    if $VERIFY_ONLY; then
        verify_ips
        exit $?
    fi

    # Run the network-reconfig playbook
    log_info "Running network reconfiguration playbook..."
    export ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg"

    local ansible_args=(
        ansible-playbook
        -i "$INVENTORY_FILE"
        "${ANSIBLE_DIR}/playbooks/network-reconfig.yml"
    )

    # Add host_vars path
    if [[ -d "${GENERATED_DIR}/host_vars" ]]; then
        ansible_args+=(-e "@${GENERATED_DIR}/host_vars/\${inventory_hostname}.yml" 2>/dev/null || true)
        # Use the host_vars directory directly by symlinking into ansible dir
        local ansible_host_vars="${ANSIBLE_DIR}/host_vars"
        if [[ -L "$ansible_host_vars" ]]; then
            rm -f "$ansible_host_vars"
        fi
        ln -sf "${GENERATED_DIR}/host_vars" "$ansible_host_vars"
    fi

    log_info "Command: ${ansible_args[*]}"

    if "${ansible_args[@]}" 2>&1 | tee "${LOGS_DIR}/assign-ips.log"; then
        log_info "Network reconfiguration completed successfully."
    else
        log_error "Network reconfiguration failed. Check ${LOGS_DIR}/assign-ips.log"
        exit 1
    fi

    # Verify new IPs are reachable
    if ! $SKIP_VERIFY; then
        log_info "Waiting 10 seconds for interfaces to stabilize..."
        sleep 10
        verify_ips || log_warn "Some IPs are not reachable. Manual verification may be needed."
    fi

    # Update inventory with final data IPs
    update_final_inventory

    print_separator "="
    log_info "IP reconfiguration complete."
    log_info "Final inventory: ${GENERATED_DIR}/inventory.ini"
    print_separator "="
}

main
