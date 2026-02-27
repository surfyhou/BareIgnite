#!/usr/bin/env bash
# network-utils.sh - IPv4 network calculation utilities
#
# Source guard
[[ -n "${_BAREIGNITE_NETWORK_UTILS_LOADED:-}" ]] && return 0
_BAREIGNITE_NETWORK_UTILS_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# validate_ip <ip>
# Return 0 if <ip> is a valid IPv4 address (dotted-quad, each octet 0-255).
# ---------------------------------------------------------------------------
validate_ip() {
    local ip="$1"
    local IFS='.'
    # shellcheck disable=SC2206
    local octets=($ip)

    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        # Must be a non-empty integer with no leading zeros (except "0" itself)
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [[ "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
        # Reject leading zeros (e.g. "01")
        if [[ "${#octet}" -gt 1 && "${octet:0:1}" == "0" ]]; then
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# validate_cidr <cidr>
# Return 0 if <cidr> is a valid notation like 192.168.1.0/24.
# ---------------------------------------------------------------------------
validate_cidr() {
    local cidr="$1"
    local ip prefix

    [[ "$cidr" == */* ]] || return 1
    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    validate_ip "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    [[ "$prefix" -ge 0 && "$prefix" -le 32 ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Internal: IP ↔ integer helpers
# ---------------------------------------------------------------------------
_ip_to_int() {
    local ip="$1"
    local IFS='.'
    # shellcheck disable=SC2206
    local o=($ip)
    echo $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))
}

_int_to_ip() {
    local int="$1"
    echo "$(( (int >> 24) & 255 )).$(( (int >> 16) & 255 )).$(( (int >> 8) & 255 )).$(( int & 255 ))"
}

_prefix_to_mask_int() {
    local prefix="$1"
    if [[ "$prefix" -eq 0 ]]; then
        echo 0
    else
        echo $(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
    fi
}

# ---------------------------------------------------------------------------
# cidr_to_netmask <prefix>
# Convert CIDR prefix length to dotted-quad netmask.
# Example: cidr_to_netmask 24  →  255.255.255.0
# ---------------------------------------------------------------------------
cidr_to_netmask() {
    local prefix="$1"
    local mask_int
    mask_int="$(_prefix_to_mask_int "$prefix")"
    _int_to_ip "$mask_int"
}

# ---------------------------------------------------------------------------
# netmask_to_cidr <netmask>
# Convert dotted-quad netmask to CIDR prefix length.
# Example: netmask_to_cidr 255.255.255.0  →  24
# ---------------------------------------------------------------------------
netmask_to_cidr() {
    local mask="$1"
    local mask_int
    mask_int="$(_ip_to_int "$mask")"

    local bits=0
    local bit=$(( 1 << 31 ))
    while [[ $(( mask_int & bit )) -ne 0 && $bits -lt 32 ]]; do
        (( bits++ )) || true
        bit=$(( bit >> 1 ))
    done
    echo "$bits"
}

# ---------------------------------------------------------------------------
# get_network_address <ip> <prefix>
# Compute the network address from an IP and CIDR prefix.
# Example: get_network_address 192.168.1.100 24  →  192.168.1.0
# ---------------------------------------------------------------------------
get_network_address() {
    local ip="$1"
    local prefix="$2"
    local ip_int mask_int net_int
    ip_int="$(_ip_to_int "$ip")"
    mask_int="$(_prefix_to_mask_int "$prefix")"
    net_int=$(( ip_int & mask_int ))
    _int_to_ip "$net_int"
}

# ---------------------------------------------------------------------------
# get_broadcast_address <ip> <prefix>
# Compute the broadcast address from an IP and CIDR prefix.
# Example: get_broadcast_address 192.168.1.100 24  →  192.168.1.255
# ---------------------------------------------------------------------------
get_broadcast_address() {
    local ip="$1"
    local prefix="$2"
    local ip_int mask_int bcast_int
    ip_int="$(_ip_to_int "$ip")"
    mask_int="$(_prefix_to_mask_int "$prefix")"
    bcast_int=$(( (ip_int & mask_int) | (~mask_int & 0xFFFFFFFF) ))
    _int_to_ip "$bcast_int"
}

# ---------------------------------------------------------------------------
# ip_in_subnet <ip> <subnet_cidr>
# Return 0 if <ip> belongs to <subnet_cidr>.
# Example: ip_in_subnet 192.168.1.50 192.168.1.0/24
# ---------------------------------------------------------------------------
ip_in_subnet() {
    local ip="$1"
    local cidr="$2"
    local subnet_ip="${cidr%/*}"
    local prefix="${cidr#*/}"

    local ip_int subnet_int mask_int
    ip_int="$(_ip_to_int "$ip")"
    subnet_int="$(_ip_to_int "$subnet_ip")"
    mask_int="$(_prefix_to_mask_int "$prefix")"

    [[ $(( ip_int & mask_int )) -eq $(( subnet_int & mask_int )) ]]
}
