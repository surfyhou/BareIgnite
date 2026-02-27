#!/usr/bin/env bash
# gen-winpe.sh -- Generate Windows PE/iPXE boot configs and autounattend.xml
# Produces per-server: boot.ipxe, autounattend.xml, winpeshl.ini, startup.bat
# Also produces a shared Samba config snippet for the Windows install share.
#
# Install flow: iPXE script -> wimboot -> WinPE(boot.wim) -> SMB share -> setup.exe /unattend
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# TOOLS_BIN for yq/jq (same pattern as gen-autoinstall.sh / gen-esxi-ks.sh)
TOOLS_BIN="${BAREIGNITE_ROOT}/tools/bin"

# ---------------------------------------------------------------------------
# generate_windows -- Main entry point
#
# Arguments:
#   $1 -- project directory (contains spec.yaml/json and generated/ output)
#
# For each server whose OS family is "windows", this function:
#   1. Renders an iPXE boot script from template (or generates inline)
#   2. Renders autounattend.xml from the appropriate template (2019/2022)
#   3. Creates winpeshl.ini and startup.bat for WinPE
#   4. Generates a Samba share config snippet
#   5. Writes output to generated/windows/{hostname}/
# ---------------------------------------------------------------------------
generate_windows() {
    local project_dir="$1"
    local spec_file
    spec_file="$(find_spec_file "$project_dir")"

    local output_base="${project_dir}/generated/windows"
    mkdir -p "$output_base"

    local server_count
    server_count="$(_spec_read "$spec_file" '.servers | length')"

    local generated=0
    for (( i=0; i<server_count; i++ )); do
        local os_id
        os_id="$(_spec_read "$spec_file" ".servers[$i].os")"

        local family
        family="$(_spec_read "$spec_file" ".os_catalog.${os_id}.family // \"unknown\"")"

        # Only process windows-family servers
        if [[ "$family" != "windows" ]]; then
            continue
        fi

        local method
        method="$(_spec_read "$spec_file" ".os_catalog.${os_id}.method // \"unknown\"")"
        if [[ "$method" != "winpe" ]]; then
            continue
        fi

        _generate_server_windows "$spec_file" "$i" "$os_id" "$output_base"
        (( generated++ ))
    done

    if (( generated == 0 )); then
        log_info "No Windows servers found in spec -- skipping"
    else
        # Generate shared Samba config snippet (one per project)
        _generate_samba_snippet "$output_base"
        log_info "Generated Windows configs for ${generated} server(s)"
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
# Generate all Windows provisioning artifacts for a single server.
# ---------------------------------------------------------------------------
_generate_server_windows() {
    local spec_file="$1"
    local idx="$2"
    local os_id="$3"
    local output_base="$4"

    # --- Extract server fields ---
    local hostname
    hostname="$(_spec_read "$spec_file" ".servers[$idx].name")"

    local arch
    arch="$(_spec_read "$spec_file" ".servers[$idx].arch // \"x86_64\"")"

    # Determine template path from os_catalog
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

    # ISO path from os_catalog
    local iso_path
    iso_path="$(_spec_read "$spec_file" ".os_catalog.${os_id}.iso_path")"

    log_info "Generating Windows config for ${hostname} (${os_id}, ${arch})"

    # --- Resolve values (server overrides -> defaults -> fallbacks) ---
    local admin_password timezone locale
    admin_password="$(_resolve_field "$spec_file" "$idx" "root_password" "")"
    timezone="$(_resolve_field "$spec_file" "$idx" "timezone" "Asia/Shanghai")"
    locale="$(_resolve_field "$spec_file" "$idx" "locale" "en_US.UTF-8")"

    # Product key (optional, Windows-specific field)
    local product_key
    product_key="$(_spec_read "$spec_file" ".servers[$idx].product_key // \"\"" 2>/dev/null || echo "")"
    [[ "$product_key" == "null" ]] && product_key=""

    # PXE MAC address
    local pxe_mac
    pxe_mac="$(_spec_read "$spec_file" "
        .servers[$idx].mac_addresses.pxe_boot //
        .servers[$idx].mac_addresses.ipmi
    ")"
    pxe_mac="$(echo "$pxe_mac" | tr '[:upper:]' '[:lower:]')"

    # Control IP for callback and install source
    local control_ip
    control_ip="$(_get_control_ip "$spec_file")"

    # Service ports
    local http_port callback_port
    http_port="8080"
    callback_port="8888"

    # Map Linux timezone to Windows timezone
    local win_timezone
    win_timezone="$(_map_timezone "$timezone")"

    # Map locale to Windows locale values
    local win_locale input_locale
    win_locale="$(_map_locale "$locale")"
    input_locale="$(_map_input_locale "$locale")"

    # Samba share name
    local samba_share_name="wininstall"

    # --- Extract data NIC info (first data NIC for static IP config) ---
    local data_ip="" data_prefix="" data_gateway="" data_dns=""
    local data_nic_count
    data_nic_count="$(_spec_read "$spec_file" ".servers[$idx].network.data | length" 2>/dev/null || echo "0")"

    if [[ "$data_nic_count" != "null" ]] && (( data_nic_count > 0 )); then
        data_ip="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].ip // \"\"")"
        data_prefix="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].prefix // 24")"

        # Get gateway from the matching network definition
        local data_net_name
        data_net_name="$(_spec_read "$spec_file" ".servers[$idx].network.data[0].network // \"\"")"
        if [[ -n "$data_net_name" ]] && [[ "$data_net_name" != "null" ]]; then
            data_gateway="$(_spec_read "$spec_file" "
                .network.data[] | select(.name == \"${data_net_name}\") | .gateway // \"\"
            ")"
            data_dns="$(_spec_read "$spec_file" "
                .network.data[] | select(.name == \"${data_net_name}\") | .dns[0] // \"\"
            ")"
        fi
    fi

    [[ "$data_ip" == "null" ]] && data_ip=""
    [[ "$data_gateway" == "null" ]] && data_gateway=""
    [[ "$data_dns" == "null" ]] && data_dns=""

    # --- Create output directory ---
    local output_dir="${output_base}/${hostname}"
    mkdir -p "$output_dir"

    # --- Build Ansible extra-vars JSON for template rendering ---
    local vars_file
    vars_file="$(mktemp)"
    trap "rm -f '$vars_file'" RETURN

    cat > "$vars_file" <<VARSEOF
{
    "hostname": "${hostname}",
    "control_ip": "${control_ip}",
    "os_id": "${os_id}",
    "arch": "${arch}",
    "iso_path": "${iso_path}",
    "http_port": "${http_port}",
    "callback_port": "${callback_port}",
    "admin_password": "${admin_password}",
    "win_timezone": "${win_timezone}",
    "locale": "${win_locale}",
    "input_locale": "${input_locale}",
    "system_locale": "${win_locale}",
    "ui_language": "${win_locale}",
    "user_locale": "${win_locale}",
    "product_key": "${product_key}",
    "samba_share_name": "${samba_share_name}",
    "data_ip": "${data_ip}",
    "data_prefix": "${data_prefix}",
    "data_gateway": "${data_gateway}",
    "data_dns": "${data_dns}",
    "pxe_mac": "${pxe_mac}"
}
VARSEOF

    # --- 1. Render autounattend.xml ---
    local autounattend_output="${output_dir}/autounattend.xml"
    ansible localhost -m template \
        -a "src='${template_file}' dest='${autounattend_output}'" \
        -e "@${vars_file}" \
        --connection=local \
        2>/dev/null \
    || log_fatal "Failed to render autounattend.xml template for ${hostname}"
    log_info "  -> ${autounattend_output}"

    # --- 2. Render iPXE boot script ---
    local ipxe_template="${BAREIGNITE_ROOT}/templates/windows/ipxe-boot.j2"
    local ipxe_output="${output_dir}/boot.ipxe"
    if [[ -f "$ipxe_template" ]]; then
        ansible localhost -m template \
            -a "src='${ipxe_template}' dest='${ipxe_output}'" \
            -e "@${vars_file}" \
            --connection=local \
            2>/dev/null \
        || log_fatal "Failed to render iPXE template for ${hostname}"
    else
        # Fallback: generate iPXE script inline
        _generate_ipxe_inline "$ipxe_output" "$hostname" "$os_id" \
            "$control_ip" "$http_port"
    fi
    log_info "  -> ${ipxe_output}"

    # --- 3. Generate winpeshl.ini ---
    local winpeshl_output="${output_dir}/winpeshl.ini"
    cat > "$winpeshl_output" <<'INIEOF'
[LaunchApps]
startup.bat
INIEOF
    log_info "  -> ${winpeshl_output}"

    # --- 4. Generate startup.bat ---
    local startup_output="${output_dir}/startup.bat"
    _generate_startup_bat "$startup_output" "$hostname" "$os_id" \
        "$control_ip" "$samba_share_name"
    log_info "  -> ${startup_output}"
}

# ---------------------------------------------------------------------------
# Generate iPXE script inline (fallback when template not available)
# ---------------------------------------------------------------------------
_generate_ipxe_inline() {
    local output_file="$1"
    local hostname="$2"
    local os_id="$3"
    local control_ip="$4"
    local http_port="$5"

    cat > "$output_file" <<IPXE_EOF
#!ipxe
# BareIgnite: iPXE boot script for ${hostname} (${os_id})
# Loads wimboot + WinPE components over HTTP

set server ${control_ip}
set http_port ${http_port}
set os_id ${os_id}

echo Booting Windows PE for ${hostname}...

kernel http://\${server}:\${http_port}/pxe/wimboot
initrd --name BCD       http://\${server}:\${http_port}/images/\${os_id}/boot/BCD        BCD
initrd --name boot.sdi  http://\${server}:\${http_port}/images/\${os_id}/boot/boot.sdi   boot.sdi
initrd --name boot.wim  http://\${server}:\${http_port}/images/\${os_id}/sources/boot.wim boot.wim
initrd --name winpeshl.ini http://\${server}:\${http_port}/configs/${hostname}/winpeshl.ini winpeshl.ini
initrd --name startup.bat  http://\${server}:\${http_port}/configs/${hostname}/startup.bat  startup.bat
boot
IPXE_EOF
}

# ---------------------------------------------------------------------------
# Generate WinPE startup batch script
# ---------------------------------------------------------------------------
_generate_startup_bat() {
    local output_file="$1"
    local hostname="$2"
    local os_id="$3"
    local control_ip="$4"
    local samba_share_name="$5"

    cat > "$output_file" <<BAT_EOF
@echo off
REM BareIgnite: WinPE startup script for ${hostname}
REM Maps SMB share and launches Windows setup with unattended answer file

echo ============================================================
echo  BareIgnite Windows Installer - ${hostname}
echo  OS: ${os_id}
echo ============================================================
echo.

REM Initialize WinPE networking
wpeinit
echo Waiting for network...
ping -n 5 127.0.0.1 >nul

REM Map the installation share
echo Mapping installation share...
net use Z: \\\\${control_ip}\\${samba_share_name} /user:guest ""
if errorlevel 1 (
    echo ERROR: Failed to map network share. Retrying...
    ping -n 10 127.0.0.1 >nul
    net use Z: \\\\${control_ip}\\${samba_share_name} /user:guest ""
)
if errorlevel 1 (
    echo FATAL: Cannot connect to installation server.
    echo Please check network connectivity to ${control_ip}
    pause
    exit /b 1
)

REM Launch Windows Setup with unattended answer file
echo Starting Windows Setup...
Z:\\${os_id}\\sources\\setup.exe /unattend:\\\\${control_ip}\\${samba_share_name}\\configs\\${hostname}\\autounattend.xml

REM If setup exits unexpectedly, drop to command prompt
echo.
echo Setup has exited. Press any key to open command prompt...
pause
cmd.exe
BAT_EOF
}

# ---------------------------------------------------------------------------
# Generate Samba share config snippet (shared across all Windows servers)
# ---------------------------------------------------------------------------
_generate_samba_snippet() {
    local output_base="$1"
    local samba_dir
    samba_dir="$(dirname "$output_base")/samba"
    mkdir -p "$samba_dir"
    local samba_file="${samba_dir}/wininstall.conf"

    cat > "$samba_file" <<SAMBA_EOF
# BareIgnite: Samba share for Windows installation
# Include this file in smb.conf via: include = ${samba_file}

[wininstall]
    comment = BareIgnite Windows Installation Share
    path = ${BAREIGNITE_ROOT}/images/windows
    browsable = yes
    read only = yes
    guest ok = yes
    force user = nobody
    force group = nobody

[configs]
    comment = BareIgnite Generated Configs (Windows)
    path = ${output_base}
    browsable = yes
    read only = yes
    guest ok = yes
    force user = nobody
    force group = nobody
SAMBA_EOF

    log_info "  Samba config: ${samba_file}"
}

# ---------------------------------------------------------------------------
# Get control IP (same logic as other generators)
# ---------------------------------------------------------------------------
_get_control_ip() {
    local spec_file="$1"
    local project_dir
    project_dir="$(dirname "$spec_file")"

    if [[ -f "${project_dir}/.control_ip" ]]; then
        cat "${project_dir}/.control_ip"
    else
        _spec_read "$spec_file" '.network.ipmi.gateway'
    fi
}

# ---------------------------------------------------------------------------
# Timezone mapping: Linux -> Windows timezone names
# ---------------------------------------------------------------------------
_map_timezone() {
    local linux_tz="$1"
    case "$linux_tz" in
        Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Urumqi)
            echo "China Standard Time" ;;
        Asia/Hong_Kong)
            echo "China Standard Time" ;;
        Asia/Taipei)
            echo "Taipei Standard Time" ;;
        Asia/Tokyo)
            echo "Tokyo Standard Time" ;;
        Asia/Seoul)
            echo "Korea Standard Time" ;;
        Asia/Singapore)
            echo "Singapore Standard Time" ;;
        America/New_York|US/Eastern)
            echo "Eastern Standard Time" ;;
        America/Chicago|US/Central)
            echo "Central Standard Time" ;;
        America/Denver|US/Mountain)
            echo "Mountain Standard Time" ;;
        America/Los_Angeles|US/Pacific)
            echo "Pacific Standard Time" ;;
        Europe/London)
            echo "GMT Standard Time" ;;
        Europe/Berlin|Europe/Paris)
            echo "W. Europe Standard Time" ;;
        UTC|Etc/UTC)
            echo "UTC" ;;
        *)
            log_warn "Unknown timezone mapping for '${linux_tz}', defaulting to 'China Standard Time'"
            echo "China Standard Time" ;;
    esac
}

# ---------------------------------------------------------------------------
# Locale mapping: Linux locale -> Windows locale string
# ---------------------------------------------------------------------------
_map_locale() {
    local linux_locale="$1"
    case "$linux_locale" in
        zh_CN*) echo "zh-CN" ;;
        zh_TW*) echo "zh-TW" ;;
        en_US*) echo "en-US" ;;
        en_GB*) echo "en-GB" ;;
        ja_JP*) echo "ja-JP" ;;
        ko_KR*) echo "ko-KR" ;;
        *)      echo "en-US" ;;
    esac
}

# ---------------------------------------------------------------------------
# Input locale mapping: Linux locale -> Windows input locale identifier
# ---------------------------------------------------------------------------
_map_input_locale() {
    local linux_locale="$1"
    case "$linux_locale" in
        zh_CN*) echo "0804:00000804" ;;
        zh_TW*) echo "0404:00000404" ;;
        en_US*) echo "0409:00000409" ;;
        en_GB*) echo "0809:00000809" ;;
        ja_JP*) echo "0411:00000411" ;;
        ko_KR*) echo "0412:00000412" ;;
        *)      echo "0409:00000409" ;;
    esac
}

# ---------------------------------------------------------------------------
# log_fatal - print error and exit (if not provided by common.sh)
# ---------------------------------------------------------------------------
if ! declare -f log_fatal &>/dev/null; then
    log_fatal() { log_error "$@"; exit 1; }
fi

# ---------------------------------------------------------------------------
# If executed directly (not sourced), run generate_windows with args
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <project_dir>" >&2
        exit 1
    fi
    generate_windows "$1"
fi
