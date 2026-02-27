#!/usr/bin/env bash
# os-detection.sh - OS identification and property look-up
#
# Source guard
[[ -n "${_BAREIGNITE_OS_DETECTION_LOADED:-}" ]] && return 0
_BAREIGNITE_OS_DETECTION_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# OS property tables
# Each supported OS id maps to:  family|version|install_method|template_dir|iso_pattern|uefi_only
# ---------------------------------------------------------------------------
declare -gA _OS_PROPS

_OS_PROPS=(
    # RHEL family -- kickstart
    [rocky8]="rhel|8|kickstart|kickstart|Rocky-8*.iso|false"
    [rocky9]="rhel|9|kickstart|kickstart|Rocky-9*.iso|false"
    [centos7]="rhel|7|kickstart|kickstart|CentOS-7*.iso|false"
    [rhel7]="rhel|7|kickstart|kickstart|rhel-server-7*.iso|false"
    [rhel8]="rhel|8|kickstart|kickstart|rhel-8*.iso|false"
    [rhel9]="rhel|9|kickstart|kickstart|rhel-9*.iso|false"
    [kylin-v10]="rhel|10|kickstart|kickstart|Kylin-Server-V10*.iso|false"
    [neokylin]="rhel|7|kickstart|kickstart|NeoKylin*.iso|false"
    [uos]="rhel|20|kickstart|kickstart|UnionTech-OS-Server*.iso|false"

    # Debian family -- autoinstall (Subiquity)
    [ubuntu2004]="debian|20.04|autoinstall|autoinstall|ubuntu-20.04*.iso|false"
    [ubuntu2204]="debian|22.04|autoinstall|autoinstall|ubuntu-22.04*.iso|false"
    [ubuntu2404]="debian|24.04|autoinstall|autoinstall|ubuntu-24.04*.iso|false"

    # ESXi -- esxi-kickstart (UEFI only)
    [esxi7]="esxi|7|esxi-kickstart|esxi|VMware-VMvisor-Installer-7*.iso|true"
    [esxi8]="esxi|8|esxi-kickstart|esxi|VMware-VMvisor-Installer-8*.iso|true"

    # Windows -- WinPE via iPXE + wimboot
    [win2019]="windows|2019|winpe|windows|Win*2019*.iso|false"
    [win2022]="windows|2022|winpe|windows|Win*2022*.iso|false"
)

# ---------------------------------------------------------------------------
# Internal helper
# ---------------------------------------------------------------------------
# _os_field <os_id> <field_index>
_os_field() {
    local os_id="$1"
    local idx="$2"
    local entry="${_OS_PROPS[$os_id]:-}"

    if [[ -z "$entry" ]]; then
        echo ""
        return 1
    fi

    echo "$entry" | cut -d'|' -f"$idx"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# get_os_family <os_id>
# Returns: rhel, debian, esxi, windows
get_os_family() { _os_field "$1" 1; }

# get_os_version <os_id>
# Returns human-readable version string (e.g. 9, 22.04)
get_os_version() { _os_field "$1" 2; }

# get_install_method <os_id>
# Returns: kickstart, autoinstall, esxi-kickstart, winpe
get_install_method() { _os_field "$1" 3; }

# get_os_template_dir <os_id>
# Returns subdirectory name under templates/
get_os_template_dir() { _os_field "$1" 4; }

# get_os_iso_pattern <os_id>
# Returns glob pattern to match the ISO filename
get_os_iso_pattern() { _os_field "$1" 5; }

# is_uefi_only <os_id>
# Returns 0 (true) if the OS supports UEFI boot only.
is_uefi_only() {
    local val
    val="$(_os_field "$1" 6)"
    [[ "$val" == "true" ]]
}

# is_known_os <os_id>
# Returns 0 if the OS id is recognized.
is_known_os() {
    [[ -n "${_OS_PROPS[$1]:-}" ]]
}

# list_known_os
# Print all known OS identifiers, one per line.
list_known_os() {
    local os_id
    for os_id in "${!_OS_PROPS[@]}"; do
        echo "$os_id"
    done | sort
}
