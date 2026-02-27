#!/usr/bin/env bash
# bareignite-init.sh - Initialization script for BareIgnite Live USB/DVD boot
#
# Detects boot media type (USB vs DVD), sets up the BareIgnite environment,
# mounts data partitions, configures network, and displays a welcome banner.
# Runs as a systemd oneshot service early in boot.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BAREIGNITE_OPT="/opt/bareignite"
DATA_MOUNT="/mnt/bareignite-data"
USB_DATA_LABEL="BAREIGNITE"
LOG_FILE="/var/log/bareignite-init.log"

# Color codes
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_RED="\033[0;31m"
C_CYAN="\033[0;36m"

# ---------------------------------------------------------------------------
# Logging (writes to both console and log file)
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] $*" >> "$LOG_FILE"
    case "$level" in
        INFO)  printf "${C_GREEN}[INFO]${C_RESET}  %s\n" "$*" ;;
        WARN)  printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*" ;;
        ERROR) printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" ;;
        *)     printf "[%s] %s\n" "$level" "$*" ;;
    esac
}

# ---------------------------------------------------------------------------
# Detect boot media type
# ---------------------------------------------------------------------------
# Returns: "usb", "dvd", or "unknown"
detect_boot_media() {
    local boot_dev=""

    # Check kernel command line for root device or live media
    if [[ -f /proc/cmdline ]]; then
        local cmdline
        cmdline="$(cat /proc/cmdline)"

        # Typical live USB: root=live:LABEL=... or root=live:UUID=...
        if [[ "$cmdline" =~ root=live:LABEL=([^ ]+) ]]; then
            local label="${BASH_REMATCH[1]}"
            boot_dev="$(blkid -L "$label" 2>/dev/null || true)"
        elif [[ "$cmdline" =~ root=live:UUID=([^ ]+) ]]; then
            local uuid="${BASH_REMATCH[1]}"
            boot_dev="$(blkid -U "$uuid" 2>/dev/null || true)"
        elif [[ "$cmdline" =~ root=live:(/dev/[^ ]+) ]]; then
            boot_dev="${BASH_REMATCH[1]}"
        fi
    fi

    # Determine media type from device path
    if [[ -n "$boot_dev" ]]; then
        # Optical drives are typically /dev/sr* or /dev/cdrom
        if [[ "$boot_dev" == /dev/sr* || "$boot_dev" == /dev/cdrom* ]]; then
            echo "dvd"
            return 0
        fi

        # USB drives -- check if the parent device is removable
        local dev_name
        dev_name="$(basename "$boot_dev" | sed 's/[0-9]*$//')"
        if [[ -f "/sys/block/${dev_name}/removable" ]]; then
            local removable
            removable="$(cat "/sys/block/${dev_name}/removable")"
            if [[ "$removable" == "1" ]]; then
                echo "usb"
                return 0
            fi
        fi

        # Fallback: check device type via udevadm
        if command -v udevadm &>/dev/null; then
            local devtype
            devtype="$(udevadm info --query=property --name="$boot_dev" 2>/dev/null | grep -i 'ID_BUS=' || true)"
            if [[ "$devtype" == *usb* ]]; then
                echo "usb"
                return 0
            fi
        fi
    fi

    # Check for optical drive as fallback
    if [[ -b /dev/sr0 ]] && mountpoint -q /run/initramfs/live 2>/dev/null; then
        local live_dev
        live_dev="$(findmnt -n -o SOURCE /run/initramfs/live 2>/dev/null || true)"
        if [[ "$live_dev" == /dev/sr* ]]; then
            echo "dvd"
            return 0
        fi
    fi

    echo "unknown"
}

# ---------------------------------------------------------------------------
# Setup for USB boot
# ---------------------------------------------------------------------------
# USB layout: partition 1 = EFI, partition 2 = rootfs, partition 3 = data
setup_usb() {
    log INFO "Boot media: USB drive"

    # Find the data partition (partition 3 or labeled BAREIGNITE)
    local data_part=""

    # Try by label first
    data_part="$(blkid -L "$USB_DATA_LABEL" 2>/dev/null || true)"

    if [[ -z "$data_part" ]]; then
        # Try to find by partition number: look at the boot device parent
        local boot_dev=""
        if [[ -f /proc/cmdline ]]; then
            local cmdline
            cmdline="$(cat /proc/cmdline)"
            if [[ "$cmdline" =~ root=live:LABEL=([^ ]+) ]]; then
                boot_dev="$(blkid -L "${BASH_REMATCH[1]}" 2>/dev/null || true)"
            fi
        fi

        if [[ -n "$boot_dev" ]]; then
            # Get parent disk (strip partition number)
            local parent_disk
            parent_disk="$(echo "$boot_dev" | sed 's/[0-9]*$//')"
            # Data partition is partition 3
            if [[ -b "${parent_disk}3" ]]; then
                data_part="${parent_disk}3"
            elif [[ -b "${parent_disk}p3" ]]; then
                data_part="${parent_disk}p3"
            fi
        fi
    fi

    if [[ -z "$data_part" ]]; then
        log WARN "Data partition not found. BareIgnite data may not be available."
        log WARN "Expected label '${USB_DATA_LABEL}' or third partition on USB device."
        return 1
    fi

    log INFO "Found data partition: ${data_part}"

    # Mount the data partition
    mkdir -p "$DATA_MOUNT"
    if ! mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        mount "$data_part" "$DATA_MOUNT" \
            || { log ERROR "Failed to mount data partition ${data_part}"; return 1; }
        log INFO "Mounted data partition at ${DATA_MOUNT}"
    else
        log INFO "Data partition already mounted at ${DATA_MOUNT}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Setup for DVD boot
# ---------------------------------------------------------------------------
setup_dvd() {
    log INFO "Boot media: DVD"
    mkdir -p "$DATA_MOUNT"

    # Check if this is a multi-disc set
    local live_mount="/run/initramfs/live"
    local manifest=""

    # Look for manifest on the live media
    if [[ -f "${live_mount}/manifest.txt" ]]; then
        manifest="${live_mount}/manifest.txt"
    elif [[ -f "/mnt/bareignite-data/manifest.txt" ]]; then
        manifest="/mnt/bareignite-data/manifest.txt"
    fi

    if [[ -n "$manifest" ]]; then
        local total_discs=1
        if grep -q 'total_discs=' "$manifest" 2>/dev/null; then
            total_discs="$(grep 'total_discs=' "$manifest" | head -1 | sed 's/.*total_discs=//' | tr -d '[:space:]')"
        fi

        if (( total_discs > 1 )); then
            log INFO "Multi-disc set detected (${total_discs} discs)"
            # Copy manifest to data mount for media-loader.service
            cp "$manifest" "${DATA_MOUNT}/manifest.txt" 2>/dev/null || true
            log INFO "Media loader service will handle remaining discs."
            # Media-loader.service will be triggered by ConditionPathExists
        else
            log INFO "Single-disc set. Copying data from disc..."
            # Copy everything from disc to data directory
            if [[ -d "${live_mount}/bareignite" ]]; then
                cp -a "${live_mount}/bareignite/." "$DATA_MOUNT/" 2>/dev/null || true
                log INFO "Copied BareIgnite data from disc"
            fi
        fi
    else
        log WARN "No manifest found. Single-disc mode assumed."
        # For single disc, data should be on the disc itself
        if [[ -d "${live_mount}/bareignite" ]]; then
            cp -a "${live_mount}/bareignite/." "$DATA_MOUNT/" 2>/dev/null || true
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Setup BareIgnite environment
# ---------------------------------------------------------------------------
setup_environment() {
    log INFO "Setting up BareIgnite environment..."

    # Create symlink: /opt/bareignite -> data location
    if [[ -d "${DATA_MOUNT}/BareIgnite" ]]; then
        # Data directory contains the full project tree
        if [[ -L "$BAREIGNITE_OPT" ]]; then
            rm -f "$BAREIGNITE_OPT"
        elif [[ -d "$BAREIGNITE_OPT" && ! "$(ls -A "$BAREIGNITE_OPT" 2>/dev/null)" ]]; then
            rmdir "$BAREIGNITE_OPT" 2>/dev/null || true
        fi
        ln -sf "${DATA_MOUNT}/BareIgnite" "$BAREIGNITE_OPT"
        log INFO "Symlinked ${BAREIGNITE_OPT} -> ${DATA_MOUNT}/BareIgnite"
    elif [[ -f "${DATA_MOUNT}/bareignite.sh" ]]; then
        # Data directory IS the project root
        if [[ -L "$BAREIGNITE_OPT" ]]; then
            rm -f "$BAREIGNITE_OPT"
        elif [[ -d "$BAREIGNITE_OPT" && ! "$(ls -A "$BAREIGNITE_OPT" 2>/dev/null)" ]]; then
            rmdir "$BAREIGNITE_OPT" 2>/dev/null || true
        fi
        ln -sf "$DATA_MOUNT" "$BAREIGNITE_OPT"
        log INFO "Symlinked ${BAREIGNITE_OPT} -> ${DATA_MOUNT}"
    else
        log WARN "BareIgnite project tree not found in ${DATA_MOUNT}"
        mkdir -p "$BAREIGNITE_OPT"
    fi

    # Configure PATH
    local profile_file="/etc/profile.d/bareignite.sh"
    cat > "$profile_file" <<'PROFILE'
# BareIgnite environment
export BAREIGNITE_ROOT="/opt/bareignite"
export PATH="${BAREIGNITE_ROOT}:${BAREIGNITE_ROOT}/tools/bin:${PATH}"
PROFILE
    chmod 644 "$profile_file"
    log INFO "Configured PATH via ${profile_file}"

    # Also export for current session
    export BAREIGNITE_ROOT="$BAREIGNITE_OPT"
    export PATH="${BAREIGNITE_OPT}:${BAREIGNITE_OPT}/tools/bin:${PATH}"
}

# ---------------------------------------------------------------------------
# Configure network interfaces
# ---------------------------------------------------------------------------
setup_network() {
    log INFO "Configuring network interfaces..."

    # Bring up all Ethernet interfaces
    local iface
    for iface_path in /sys/class/net/*/type; do
        local iface_dir
        iface_dir="$(dirname "$iface_path")"
        iface="$(basename "$iface_dir")"

        # Skip loopback and virtual interfaces
        [[ "$iface" == "lo" ]] && continue
        [[ "$iface" == veth* ]] && continue
        [[ "$iface" == docker* ]] && continue
        [[ "$iface" == br-* ]] && continue

        # Check if it is a physical Ethernet device (type 1)
        local iface_type
        iface_type="$(cat "$iface_path" 2>/dev/null || echo "")"
        [[ "$iface_type" != "1" ]] && continue

        # Bring up the interface
        if ip link show "$iface" | grep -q 'state DOWN'; then
            ip link set "$iface" up 2>/dev/null || true
            log INFO "  Brought up interface: ${iface}"
        fi
    done

    # Wait briefly for link negotiation
    sleep 2

    # If no interface has an IP, try DHCP on the first available one
    local has_ip=false
    for iface_path in /sys/class/net/*/type; do
        local iface_dir
        iface_dir="$(dirname "$iface_path")"
        iface="$(basename "$iface_dir")"
        [[ "$iface" == "lo" ]] && continue

        if ip addr show "$iface" 2>/dev/null | grep -q 'inet '; then
            has_ip=true
            local ip_addr
            ip_addr="$(ip addr show "$iface" | grep 'inet ' | awk '{print $2}' | head -1)"
            log INFO "  Interface ${iface} has IP: ${ip_addr}"
        fi
    done

    if [[ "$has_ip" == "false" ]]; then
        log WARN "No interface has an IP address."
        log WARN "BareIgnite will need a static IP configured before provisioning."
        log WARN "Use: nmcli con mod <connection> ipv4.method manual ipv4.addr <ip/prefix>"
    fi
}

# ---------------------------------------------------------------------------
# Display welcome banner
# ---------------------------------------------------------------------------
show_banner() {
    local version="unknown"
    if [[ -f "${BAREIGNITE_OPT}/VERSION" ]]; then
        version="$(cat "${BAREIGNITE_OPT}/VERSION" | tr -d '[:space:]')"
    fi

    cat <<BANNER

${C_BOLD}${C_CYAN}========================================================${C_RESET}
${C_BOLD}${C_CYAN}     ____                  ___            _ __       ${C_RESET}
${C_BOLD}${C_CYAN}    / __ )____ _________  /  _/____ ___  (_) /____  ${C_RESET}
${C_BOLD}${C_CYAN}   / __  / __ \`/ ___/ _ \  / / / __ \`/ __ \/ / __/ _ \ ${C_RESET}
${C_BOLD}${C_CYAN}  / /_/ / /_/ / /  /  __// / / /_/ / / / / / /_/  __/ ${C_RESET}
${C_BOLD}${C_CYAN} /_____/\__,_/_/   \___/___/\__, /_/ /_/_/\__/\___/  ${C_RESET}
${C_BOLD}${C_CYAN}                            /____/                    ${C_RESET}
${C_BOLD}${C_CYAN}========================================================${C_RESET}
${C_BOLD}  Offline Bare Metal Server Provisioning  v${version}${C_RESET}
${C_CYAN}========================================================${C_RESET}

  ${C_BOLD}Quick Start:${C_RESET}
    1. Verify network:    ${C_GREEN}ip addr${C_RESET}
    2. Configure IP:      ${C_GREEN}nmcli con mod <conn> ipv4.method manual ipv4.addr <ip/prefix>${C_RESET}
    3. Validate spec:     ${C_GREEN}bareignite.sh validate <project>${C_RESET}
    4. Generate configs:  ${C_GREEN}bareignite.sh generate <project>${C_RESET}
    5. Start services:    ${C_GREEN}bareignite.sh start <project>${C_RESET}
    6. Monitor progress:  ${C_GREEN}bareignite.sh monitor <project>${C_RESET}

  ${C_BOLD}Data directory:${C_RESET}  ${DATA_MOUNT}
  ${C_BOLD}BareIgnite root:${C_RESET} ${BAREIGNITE_OPT}

  For help: ${C_GREEN}bareignite.sh --help${C_RESET}

BANNER
}

# ---------------------------------------------------------------------------
# Auto-start BareIgnite (if configured)
# ---------------------------------------------------------------------------
check_autostart() {
    local autostart_file="${DATA_MOUNT}/.autostart"
    if [[ -f "$autostart_file" ]]; then
        local project
        project="$(cat "$autostart_file" | tr -d '[:space:]')"
        if [[ -n "$project" ]]; then
            log INFO "Auto-start configured for project: ${project}"
            log INFO "Starting BareIgnite in 10 seconds... (Press Ctrl+C to cancel)"
            sleep 10
            exec "${BAREIGNITE_OPT}/bareignite.sh" start "$project"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== BareIgnite Init $(date) ===" >> "$LOG_FILE"

    log INFO "BareIgnite initialization starting..."

    # Detect boot media
    local media_type
    media_type="$(detect_boot_media)"
    log INFO "Detected boot media type: ${media_type}"

    # Setup based on media type
    case "$media_type" in
        usb)
            setup_usb
            ;;
        dvd)
            setup_dvd
            ;;
        *)
            log WARN "Could not determine boot media type."
            log WARN "Attempting USB setup as fallback..."
            setup_usb || setup_dvd || log ERROR "Failed to set up data partition."
            ;;
    esac

    # Setup environment
    setup_environment

    # Setup network
    setup_network

    # Show welcome banner
    show_banner

    # Check for auto-start
    check_autostart

    log INFO "BareIgnite initialization complete."
}

main "$@"
