#!/usr/bin/env bash
# gen-pxe-menu.sh -- Generate PXE/GRUB boot menu configs for each server
#
# For each server, generates:
#   - BIOS:  pxelinux.cfg/01-{mac} (per-host BIOS PXE config)
#   - UEFI x86_64: grub.cfg/grub.cfg-01-{mac} (per-host GRUB config)
#   - UEFI aarch64: grub.cfg/grub.cfg-01-{mac} (ARM64 GRUB config)
#   - Default fallback menus (boot from local disk)

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
# generate_pxe_config
#   Generate PXE/GRUB boot config for a single server.
#
# Arguments:
#   $1 - spec_file      Path to the project spec file
#   $2 - server_index   Index of the server in spec servers[]
#   $3 - generated_dir  Path to the project generated/ directory
#   $4 - control_ip     Control node IP address
# ---------------------------------------------------------------------------
generate_pxe_config() {
    local spec_file="$1"
    local idx="$2"
    local generated_dir="$3"
    local control_ip="$4"

    # --- Extract server fields ---
    local hostname os_id arch boot_mode
    hostname="$(spec_get "$spec_file" ".servers[$idx].name")"
    os_id="$(spec_get "$spec_file" ".servers[$idx].os")"
    arch="$(spec_get "$spec_file" ".servers[$idx].arch // \"x86_64\"")"

    if ! is_known_os "$os_id"; then
        log_warn "Unknown OS '${os_id}' for '${hostname}' -- skipping PXE config"
        return 0
    fi

    # Determine boot mode
    boot_mode="$(spec_get "$spec_file" "
        .servers[$idx].boot_mode //
        .defaults.boot_mode //
        \"uefi\"
    ")"
    if [[ "$arch" == "aarch64" ]]; then
        boot_mode="uefi"
    fi

    # Get PXE MAC address
    local pxe_mac
    pxe_mac="$(spec_get "$spec_file" "
        .servers[$idx].mac_addresses.pxe_boot //
        .servers[$idx].mac_addresses.ipmi
    ")"
    pxe_mac="$(normalize_mac "$pxe_mac")"

    # Get OS family and method
    local family method
    family="$(get_os_family "$os_id")"
    method="$(get_install_method "$os_id")"

    # HTTP port and server URL
    local http_port="${HTTP_PORT:-8080}"
    local http_url="http://${control_ip}:${http_port}"

    # Determine kernel, initrd, and boot params based on OS family
    local kernel_path initrd_path boot_params ks_url repo_url

    case "$family" in
        rhel)
            kernel_path="images/${os_id}/images/pxeboot/vmlinuz"
            initrd_path="images/${os_id}/images/pxeboot/initrd.img"
            ks_url="${http_url}/kickstart/${hostname}.ks"
            repo_url="${http_url}/images/${os_id}/"
            boot_params="inst.ks=${ks_url} inst.repo=${repo_url} ip=dhcp quiet"
            ;;
        debian)
            kernel_path="images/${os_id}/casper/vmlinuz"
            initrd_path="images/${os_id}/casper/initrd"
            ks_url="${http_url}/autoinstall/${hostname}/"
            repo_url="${http_url}/images/${os_id}/"
            boot_params="ip=dhcp cloud-config-url=/dev/null autoinstall \"ds=nocloud-net;s=${ks_url}\""
            ;;
        esxi)
            kernel_path="images/${os_id}/mboot.efi"
            initrd_path=""
            ks_url="${http_url}/esxi/${hostname}.cfg"
            repo_url=""
            boot_params="-c ${ks_url}"
            ;;
        windows)
            # Windows uses iPXE chain, not standard PXE/GRUB
            log_debug "Windows server '${hostname}' uses iPXE -- skipping standard PXE menu"
            return 0
            ;;
        *)
            log_warn "Unknown OS family '${family}' for '${hostname}' -- skipping PXE"
            return 0
            ;;
    esac

    log_debug "PXE config for ${hostname}: boot_mode=${boot_mode}, family=${family}"

    # --- Build template variables ---
    local vars_file="${generated_dir}/.pxe-${hostname}-vars.json"
    cat > "$vars_file" <<VARSEOF
{
    "hostname": "${hostname}",
    "os_id": "${os_id}",
    "arch": "${arch}",
    "boot_mode": "${boot_mode}",
    "os_family": "${family}",
    "control_ip": "${control_ip}",
    "http_port": "${http_port}",
    "http_url": "${http_url}",
    "kernel_path": "${kernel_path}",
    "initrd_path": "${initrd_path}",
    "boot_params": "${boot_params}",
    "ks_url": "${ks_url}",
    "repo_url": "${repo_url}"
}
VARSEOF

    # --- Generate configs based on boot mode ---
    case "$boot_mode" in
        bios)
            _generate_pxelinux_config "$spec_file" "$idx" "$generated_dir" "$vars_file" "$pxe_mac"
            ;;
        uefi)
            _generate_grub_config "$spec_file" "$idx" "$generated_dir" "$vars_file" "$pxe_mac" "$arch"
            ;;
        auto|*)
            # Generate both BIOS and UEFI configs
            _generate_pxelinux_config "$spec_file" "$idx" "$generated_dir" "$vars_file" "$pxe_mac"
            _generate_grub_config "$spec_file" "$idx" "$generated_dir" "$vars_file" "$pxe_mac" "$arch"
            ;;
    esac

    # Clean up temporary vars file
    rm -f "$vars_file"
}

# ---------------------------------------------------------------------------
# _generate_pxelinux_config
#   Generate a BIOS PXE (pxelinux) per-host config file.
# ---------------------------------------------------------------------------
_generate_pxelinux_config() {
    local spec_file="$1"
    local idx="$2"
    local generated_dir="$3"
    local vars_file="$4"
    local pxe_mac="$5"

    local pxe_dir="${generated_dir}/pxelinux.cfg"
    mkdir -p "$pxe_dir"

    local pxe_filename
    pxe_filename="$(mac_to_pxelinux "$pxe_mac")"
    local output_file="${pxe_dir}/${pxe_filename}"

    local template="${BAREIGNITE_ROOT}/templates/pxe/pxelinux-per-host.j2"

    if [[ -f "$template" ]]; then
        render_template_with_file "$template" "$output_file" "$vars_file"
    else
        # Fallback: generate inline without template
        log_warn "PXE template not found, generating inline: ${output_file}"
        _generate_pxelinux_inline "$output_file" "$vars_file"
    fi

    log_debug "  BIOS PXE: ${output_file}"
}

# ---------------------------------------------------------------------------
# _generate_grub_config
#   Generate a UEFI GRUB per-host config file.
# ---------------------------------------------------------------------------
_generate_grub_config() {
    local spec_file="$1"
    local idx="$2"
    local generated_dir="$3"
    local vars_file="$4"
    local pxe_mac="$5"
    local arch="$6"

    local grub_dir="${generated_dir}/grub.cfg"
    mkdir -p "$grub_dir"

    local grub_filename
    grub_filename="$(mac_to_grub "$pxe_mac")"
    local output_file="${grub_dir}/${grub_filename}"

    local template="${BAREIGNITE_ROOT}/templates/pxe/grub-per-host.cfg.j2"

    if [[ -f "$template" ]]; then
        render_template_with_file "$template" "$output_file" "$vars_file"
    else
        log_warn "GRUB template not found, generating inline: ${output_file}"
        _generate_grub_inline "$output_file" "$vars_file"
    fi

    log_debug "  UEFI GRUB (${arch}): ${output_file}"
}

# ---------------------------------------------------------------------------
# _generate_pxelinux_inline
#   Fallback: generate a pxelinux config without the Jinja2 template.
# ---------------------------------------------------------------------------
_generate_pxelinux_inline() {
    local output_file="$1"
    local vars_file="$2"

    # Parse vars from JSON
    local hostname os_id http_url kernel_path initrd_path boot_params
    hostname="$(jq -r '.hostname' "$vars_file")"
    os_id="$(jq -r '.os_id' "$vars_file")"
    http_url="$(jq -r '.http_url' "$vars_file")"
    kernel_path="$(jq -r '.kernel_path' "$vars_file")"
    initrd_path="$(jq -r '.initrd_path' "$vars_file")"
    boot_params="$(jq -r '.boot_params' "$vars_file")"

    cat > "$output_file" <<PXEEOF
# BareIgnite PXE config for ${hostname} (${os_id})
# Auto-generated -- do not edit

DEFAULT install
PROMPT 0
TIMEOUT 50

LABEL install
  MENU LABEL Install ${os_id} on ${hostname}
  KERNEL ${http_url}/${kernel_path}
  APPEND initrd=${http_url}/${initrd_path} ${boot_params}

LABEL local
  MENU LABEL Boot from local disk
  LOCALBOOT 0
PXEEOF
}

# ---------------------------------------------------------------------------
# _generate_grub_inline
#   Fallback: generate a GRUB config without the Jinja2 template.
# ---------------------------------------------------------------------------
_generate_grub_inline() {
    local output_file="$1"
    local vars_file="$2"

    local hostname os_id os_family http_url control_ip http_port
    local kernel_path initrd_path boot_params
    hostname="$(jq -r '.hostname' "$vars_file")"
    os_id="$(jq -r '.os_id' "$vars_file")"
    os_family="$(jq -r '.os_family' "$vars_file")"
    http_url="$(jq -r '.http_url' "$vars_file")"
    control_ip="$(jq -r '.control_ip' "$vars_file")"
    http_port="$(jq -r '.http_port' "$vars_file")"
    kernel_path="$(jq -r '.kernel_path' "$vars_file")"
    initrd_path="$(jq -r '.initrd_path' "$vars_file")"
    boot_params="$(jq -r '.boot_params' "$vars_file")"

    if [[ "$os_family" == "esxi" ]]; then
        cat > "$output_file" <<GRUBEOF
# BareIgnite GRUB config for ${hostname} (${os_id})
# ESXi UEFI boot
set timeout=5
set default=0

menuentry 'BareIgnite: Install ${os_id} on ${hostname}' {
    chainloader ${http_url}/${kernel_path} ${boot_params}
}

menuentry 'Boot from local disk' {
    exit
}
GRUBEOF
    else
        cat > "$output_file" <<GRUBEOF
# BareIgnite GRUB config for ${hostname} (${os_id})
set timeout=5
set default=0

menuentry 'BareIgnite: Install ${os_id} on ${hostname}' {
    linuxefi /${kernel_path} ${boot_params}
    initrdefi /${initrd_path}
}

menuentry 'Boot from local disk' {
    exit
}
GRUBEOF
    fi
}

# ---------------------------------------------------------------------------
# generate_default_menu
#   Generate default PXE and GRUB menus (boot from local disk).
# ---------------------------------------------------------------------------
generate_default_menu() {
    local generated_dir="$1"

    # Default BIOS PXE menu
    local pxe_default="${generated_dir}/pxelinux.cfg/default"
    cat > "$pxe_default" <<'PXEEOF'
# BareIgnite default PXE menu
# Unrecognized MACs boot from local disk

DEFAULT local
PROMPT 0
TIMEOUT 30

LABEL local
  MENU LABEL Boot from local disk
  LOCALBOOT 0
PXEEOF
    log_debug "Default PXE menu: ${pxe_default}"

    # Default UEFI GRUB menu
    local grub_default="${generated_dir}/grub.cfg/grub.cfg"
    cat > "$grub_default" <<'GRUBEOF'
# BareIgnite default GRUB menu
# Unrecognized MACs boot from local disk

set timeout=5
set default=0

menuentry 'Boot from local disk' {
    exit
}
GRUBEOF
    log_debug "Default GRUB menu: ${grub_default}"
}

# ---------------------------------------------------------------------------
# If executed directly, process all servers in a project
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <project_dir>" >&2
        exit 1
    fi

    project_dir="$1"
    spec_file="$(find_spec_file "$project_dir")"
    generated_dir="${project_dir}/generated"
    mkdir -p "${generated_dir}/pxelinux.cfg" "${generated_dir}/grub.cfg"

    # Source bareignite.conf
    [[ -f "${BAREIGNITE_ROOT}/conf/bareignite.conf" ]] && source "${BAREIGNITE_ROOT}/conf/bareignite.conf"
    control_ip="${CONTROL_IP:-10.0.1.1}"

    server_count="$(spec_server_count "$spec_file")"
    for ((i = 0; i < server_count; i++)); do
        generate_pxe_config "$spec_file" "$i" "$generated_dir" "$control_ip"
    done

    generate_default_menu "$generated_dir"
fi
