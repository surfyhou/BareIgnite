#!/usr/bin/env bash
# validate-spec.sh - Validate a BareIgnite spec file
#
# Usage: validate-spec.sh <spec_file>
#
# Checks required fields, value validity, duplicate IPs/MACs, and OS support.
# Exits 0 on success, 1 on any validation failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/spec-parser.sh"
source "${SCRIPT_DIR}/lib/mac-utils.sh"
source "${SCRIPT_DIR}/lib/network-utils.sh"
source "${SCRIPT_DIR}/lib/os-detection.sh"

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
ERRORS=0
WARNINGS=0

pass() {
    log_info "  PASS  $*"
}

fail() {
    log_error "  FAIL  $*"
    (( ERRORS++ )) || true
}

warn() {
    log_warn "  WARN  $*"
    (( WARNINGS++ )) || true
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") <spec_file>"
    echo ""
    echo "Validate a BareIgnite specification file (YAML or JSON)."
    exit 1
}

# ---------------------------------------------------------------------------
# Main validation logic
# ---------------------------------------------------------------------------
validate_spec() {
    local spec_file="$1"

    if [[ ! -f "$spec_file" ]]; then
        die "Spec file not found: $spec_file"
    fi

    local format
    format="$(detect_spec_format "$spec_file")"
    log_info "Validating spec file: $spec_file (format: $format)"
    echo ""

    # ------ Project section ------
    log_info "--- Project ---"
    local project_name
    project_name="$(spec_get "$spec_file" '.project.name')"
    if [[ -n "$project_name" ]]; then
        pass "project.name = $project_name"
    else
        fail "project.name is required"
    fi

    # ------ Network / IPMI section ------
    log_info "--- Network (IPMI) ---"

    local ipmi_subnet ipmi_gateway ipmi_dhcp_range ipmi_dns
    ipmi_subnet="$(spec_get "$spec_file" '.network.ipmi.subnet')"
    ipmi_gateway="$(spec_get "$spec_file" '.network.ipmi.gateway')"
    ipmi_dhcp_range="$(spec_get "$spec_file" '.network.ipmi.dhcp_range')"
    ipmi_dns="$(spec_get "$spec_file" '.network.ipmi.dns')"

    # subnet
    if [[ -n "$ipmi_subnet" ]]; then
        if validate_cidr "$ipmi_subnet"; then
            pass "network.ipmi.subnet = $ipmi_subnet"
        else
            fail "network.ipmi.subnet is not a valid CIDR: $ipmi_subnet"
        fi
    else
        fail "network.ipmi.subnet is required"
    fi

    # gateway
    if [[ -n "$ipmi_gateway" ]]; then
        if validate_ip "$ipmi_gateway"; then
            pass "network.ipmi.gateway = $ipmi_gateway"
        else
            fail "network.ipmi.gateway is not a valid IP: $ipmi_gateway"
        fi
    else
        warn "network.ipmi.gateway is not set"
    fi

    # dhcp_range
    if [[ -n "$ipmi_dhcp_range" ]]; then
        # Expect format: start-end or start,end
        local range_start range_end
        range_start="$(echo "$ipmi_dhcp_range" | tr ',' '-' | cut -d'-' -f1)"
        range_end="$(echo "$ipmi_dhcp_range" | tr ',' '-' | cut -d'-' -f2)"
        if validate_ip "$range_start" && validate_ip "$range_end"; then
            pass "network.ipmi.dhcp_range = $ipmi_dhcp_range"
        else
            fail "network.ipmi.dhcp_range is invalid: $ipmi_dhcp_range"
        fi
    else
        fail "network.ipmi.dhcp_range is required"
    fi

    # dns
    if [[ -n "$ipmi_dns" ]]; then
        if validate_ip "$ipmi_dns"; then
            pass "network.ipmi.dns = $ipmi_dns"
        else
            fail "network.ipmi.dns is not a valid IP: $ipmi_dns"
        fi
    else
        warn "network.ipmi.dns is not set"
    fi

    # ------ Data networks (optional) ------
    local data_net_len
    data_net_len="$(spec_get_length "$spec_file" '.network.data // []')"
    if [[ "$data_net_len" -gt 0 ]]; then
        log_info "--- Network (Data) ---"
        local i
        for (( i=0; i<data_net_len; i++ )); do
            local dn_name dn_subnet
            dn_name="$(spec_get "$spec_file" ".network.data[$i].name")"
            dn_subnet="$(spec_get "$spec_file" ".network.data[$i].subnet")"
            if [[ -n "$dn_subnet" ]] && validate_cidr "$dn_subnet"; then
                pass "network.data[$i] ($dn_name) subnet=$dn_subnet"
            else
                fail "network.data[$i] ($dn_name) has invalid subnet: $dn_subnet"
            fi
        done
    fi

    # ------ os_catalog (optional) ------
    local catalog_len
    catalog_len="$(spec_get_length "$spec_file" '.os_catalog // []')"
    if [[ "$catalog_len" -gt 0 ]]; then
        log_info "--- OS Catalog ---"
        local i
        for (( i=0; i<catalog_len; i++ )); do
            local cat_id cat_family cat_method cat_iso
            cat_id="$(spec_get "$spec_file" ".os_catalog[$i].id")"
            cat_family="$(spec_get "$spec_file" ".os_catalog[$i].family")"
            cat_method="$(spec_get "$spec_file" ".os_catalog[$i].method")"
            cat_iso="$(spec_get "$spec_file" ".os_catalog[$i].iso_path")"

            if [[ -z "$cat_id" ]]; then
                fail "os_catalog[$i].id is required"
                continue
            fi

            if [[ -n "$cat_family" ]]; then
                pass "os_catalog[$i] ($cat_id) family=$cat_family"
            else
                fail "os_catalog[$i] ($cat_id) family is required"
            fi

            if [[ -n "$cat_method" ]]; then
                pass "os_catalog[$i] ($cat_id) method=$cat_method"
            else
                fail "os_catalog[$i] ($cat_id) method is required"
            fi

            if [[ -n "$cat_iso" ]]; then
                pass "os_catalog[$i] ($cat_id) iso_path=$cat_iso"
            else
                warn "os_catalog[$i] ($cat_id) iso_path is not set"
            fi
        done
    fi

    # ------ Servers section ------
    log_info "--- Servers ---"
    local server_count
    server_count="$(spec_get_length "$spec_file" '.servers')"
    if [[ "$server_count" -eq 0 || -z "$server_count" ]]; then
        fail "servers[] array is required and must not be empty"
    else
        pass "servers[] contains $server_count server(s)"
    fi

    # Track duplicates
    declare -A seen_ips
    declare -A seen_macs

    local s
    for (( s=0; s<server_count; s++ )); do
        local srv_name srv_os srv_pxe_mac srv_arch srv_boot
        srv_name="$(spec_get "$spec_file" ".servers[$s].name")"
        srv_os="$(spec_get "$spec_file" ".servers[$s].os")"
        srv_pxe_mac="$(spec_get "$spec_file" ".servers[$s].mac_addresses.pxe_boot")"
        srv_arch="$(spec_get "$spec_file" ".servers[$s].arch")"
        srv_boot="$(spec_get "$spec_file" ".servers[$s].boot_mode")"

        echo ""
        log_info "  Server [$s]: ${srv_name:-<unnamed>}"

        # name
        if [[ -n "$srv_name" ]]; then
            pass "name = $srv_name"
        else
            fail "servers[$s].name is required"
        fi

        # os
        if [[ -n "$srv_os" ]]; then
            if is_known_os "$srv_os"; then
                pass "os = $srv_os (family=$(get_os_family "$srv_os"), method=$(get_install_method "$srv_os"))"
            else
                fail "os = $srv_os is not a recognized OS identifier"
            fi
        else
            fail "servers[$s].os is required"
        fi

        # pxe_boot MAC
        if [[ -n "$srv_pxe_mac" ]]; then
            if validate_mac "$srv_pxe_mac"; then
                local norm_mac
                norm_mac="$(normalize_mac "$srv_pxe_mac")"
                if [[ -n "${seen_macs[$norm_mac]:-}" ]]; then
                    fail "servers[$s].mac_addresses.pxe_boot ($norm_mac) duplicates ${seen_macs[$norm_mac]}"
                else
                    seen_macs[$norm_mac]="$srv_name"
                    pass "mac_addresses.pxe_boot = $norm_mac"
                fi
            else
                fail "servers[$s].mac_addresses.pxe_boot is not a valid MAC: $srv_pxe_mac"
            fi
        else
            fail "servers[$s].mac_addresses.pxe_boot is required"
        fi

        # Additional MACs (ipmi, data, etc.) - check for duplicates
        local extra_mac_keys
        extra_mac_keys="$(spec_get_object "$spec_file" ".servers[$s].mac_addresses" 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)"
        for mk in $extra_mac_keys; do
            [[ "$mk" == "pxe_boot" ]] && continue
            local emac
            emac="$(spec_get "$spec_file" ".servers[$s].mac_addresses.${mk}")"
            if [[ -n "$emac" ]] && validate_mac "$emac"; then
                local enorm
                enorm="$(normalize_mac "$emac")"
                if [[ -n "${seen_macs[$enorm]:-}" ]]; then
                    fail "servers[$s].mac_addresses.${mk} ($enorm) duplicates ${seen_macs[$enorm]}"
                else
                    seen_macs[$enorm]="$srv_name/$mk"
                fi
            fi
        done

        # Check boot_mode vs OS
        if [[ -n "$srv_os" ]] && is_known_os "$srv_os" && is_uefi_only "$srv_os"; then
            if [[ -n "$srv_boot" && "$srv_boot" != "uefi" ]]; then
                fail "servers[$s].boot_mode=$srv_boot but $srv_os requires UEFI"
            fi
        fi

        # Validate static IPs if present - IPMI
        local ipmi_ip
        ipmi_ip="$(spec_get "$spec_file" ".servers[$s].ipmi.ip")"
        if [[ -n "$ipmi_ip" ]]; then
            if validate_ip "$ipmi_ip"; then
                if [[ -n "${seen_ips[$ipmi_ip]:-}" ]]; then
                    fail "servers[$s].ipmi.ip ($ipmi_ip) duplicates ${seen_ips[$ipmi_ip]}"
                else
                    seen_ips[$ipmi_ip]="$srv_name/ipmi"
                    pass "ipmi.ip = $ipmi_ip"
                fi
            else
                fail "servers[$s].ipmi.ip is not a valid IP: $ipmi_ip"
            fi
        fi

        # Validate data network IPs
        local dn_len
        dn_len="$(spec_get_length "$spec_file" ".servers[$s].networks // []")"
        local d
        for (( d=0; d<dn_len; d++ )); do
            local dip dnet_name
            dip="$(spec_get "$spec_file" ".servers[$s].networks[$d].ip")"
            dnet_name="$(spec_get "$spec_file" ".servers[$s].networks[$d].name")"
            if [[ -n "$dip" ]]; then
                if validate_ip "$dip"; then
                    if [[ -n "${seen_ips[$dip]:-}" ]]; then
                        fail "servers[$s].networks[$d] ($dnet_name) ip=$dip duplicates ${seen_ips[$dip]}"
                    else
                        seen_ips[$dip]="$srv_name/$dnet_name"
                        pass "network $dnet_name ip = $dip"
                    fi
                else
                    fail "servers[$s].networks[$d] ($dnet_name) ip is not valid: $dip"
                fi
            fi
        done
    done

    # ------ Summary ------
    echo ""
    echo "========================================"
    if [[ $ERRORS -eq 0 ]]; then
        log_info "Validation PASSED ($WARNINGS warning(s))"
        return 0
    else
        log_error "Validation FAILED: $ERRORS error(s), $WARNINGS warning(s)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    usage
fi

validate_spec "$1"
