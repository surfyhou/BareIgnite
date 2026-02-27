#!/usr/bin/env bash
# mac-utils.sh - MAC address manipulation utilities
#
# Source guard
[[ -n "${_BAREIGNITE_MAC_UTILS_LOADED:-}" ]] && return 0
_BAREIGNITE_MAC_UTILS_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# validate_mac <mac>
# Return 0 if <mac> looks like a valid MAC address (any common separator).
# Accepts: aa:bb:cc:dd:ee:ff, AA-BB-CC-DD-EE-FF, aabb.ccdd.eeff, aabbccddeeff
# ---------------------------------------------------------------------------
validate_mac() {
    local mac="$1"

    # Strip common separators and lowercase
    local stripped
    stripped="$(echo "$mac" | tr -d ':.-' | tr '[:upper:]' '[:lower:]')"

    # Must be exactly 12 hex characters
    if [[ "$stripped" =~ ^[0-9a-f]{12}$ ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# normalize_mac <mac>
# Output lowercase colon-separated format: aa:bb:cc:dd:ee:ff
# ---------------------------------------------------------------------------
normalize_mac() {
    local mac="$1"
    local stripped
    stripped="$(echo "$mac" | tr -d ':.-' | tr '[:upper:]' '[:lower:]')"

    if [[ ! "$stripped" =~ ^[0-9a-f]{12}$ ]]; then
        echo "ERROR: invalid MAC address: $mac" >&2
        return 1
    fi

    printf '%s\n' "${stripped:0:2}:${stripped:2:2}:${stripped:4:2}:${stripped:6:2}:${stripped:8:2}:${stripped:10:2}"
}

# ---------------------------------------------------------------------------
# mac_to_pxelinux <mac>
# Convert to PXELINUX config filename: 01-aa-bb-cc-dd-ee-ff
# The leading 01 denotes Ethernet (ARP type 1).
# ---------------------------------------------------------------------------
mac_to_pxelinux() {
    local mac
    mac="$(normalize_mac "$1")" || return 1
    # Replace colons with dashes and prepend 01-
    echo "01-${mac//:/-}"
}

# ---------------------------------------------------------------------------
# mac_to_grub <mac>
# Convert to GRUB per-host config filename: grub.cfg-01-aa-bb-cc-dd-ee-ff
# ---------------------------------------------------------------------------
mac_to_grub() {
    local pxe_name
    pxe_name="$(mac_to_pxelinux "$1")" || return 1
    echo "grub.cfg-${pxe_name}"
}

# ---------------------------------------------------------------------------
# mac_to_dnsmasq <mac>
# Format suitable for dnsmasq dhcp-host entry: aa:bb:cc:dd:ee:ff
# (same as normalize_mac, provided for semantic clarity)
# ---------------------------------------------------------------------------
mac_to_dnsmasq() {
    normalize_mac "$1"
}
