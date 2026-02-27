#!/usr/bin/env bash
# build.sh - BareIgnite Live USB/ISO builder
#
# Creates a bootable Live USB image or ISO containing Rocky 9 minimal
# with all BareIgnite dependencies pre-installed, plus optional data
# (OS images, projects).
#
# Usage:
#   build.sh --type usb --output /path/to/output.img [--data-dir /path/to/data]
#   build.sh --type iso --output /path/to/output.iso [--data-dir /path/to/data]
#   build.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAREIGNITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common library if available (may not be when building from scratch)
if [[ -f "${BAREIGNITE_ROOT}/scripts/lib/common.sh" ]]; then
    source "${BAREIGNITE_ROOT}/scripts/lib/common.sh"
else
    # Minimal logging fallback
    log_info()  { printf "\033[0;32m[INFO]\033[0m  %s\n" "$*"; }
    log_warn()  { printf "\033[0;33m[WARN]\033[0m  %s\n" "$*" >&2; }
    log_error() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; }
    die()       { log_error "$@"; exit 1; }
    ensure_dir() { mkdir -p "$1" || die "Failed to create directory: $1"; }
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BUILD_TYPE=""               # usb or iso
OUTPUT_PATH=""              # Output file path
DATA_DIR=""                 # Optional: BareIgnite data to include
BASE_ISO=""                 # Optional: Pre-built Rocky Live ISO to customize
KICKSTART="${SCRIPT_DIR}/kickstart/liveusb.ks"
WORK_DIR=""                 # Temporary working directory (auto-created)
KEEP_WORK=false             # Keep working directory after build

# USB partition sizes
EFI_SIZE_MB=600
ROOTFS_SIZE_MB=4096
# DATA partition fills the rest

# ISO settings
ISO_LABEL="BareIgnite"
ISO_VOLID="BareIgnite-Live"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
BareIgnite Live USB/ISO Builder

Usage: $(basename "$0") [options]

Options:
  --type <usb|iso>          Build type (required)
  --output <path>           Output file path (required)
  --data-dir <path>         BareIgnite data directory to include (images, projects)
  --base-iso <path>         Pre-built Rocky 9 Live ISO to customize (skip building from scratch)
  --kickstart <path>        Custom kickstart file (default: kickstart/liveusb.ks)
  --work-dir <path>         Working directory (default: auto-created in /tmp)
  --keep-work               Keep working directory after build
  -h, --help                Show this help message

Examples:
  # Build a Live ISO from scratch
  $(basename "$0") --type iso --output /tmp/bareignite-live.iso

  # Build a USB image with data included
  $(basename "$0") --type usb --output /tmp/bareignite.img --data-dir /path/to/data

  # Customize an existing Rocky Live ISO
  $(basename "$0") --type iso --output /tmp/bareignite.iso --base-iso Rocky-9-Live-x86_64.iso

After building a USB image, write it with:
  dd if=bareignite.img of=/dev/sdX bs=4M status=progress conv=fsync

EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                BUILD_TYPE="$2"; shift 2 ;;
            --output)
                OUTPUT_PATH="$2"; shift 2 ;;
            --data-dir)
                DATA_DIR="$2"; shift 2 ;;
            --base-iso)
                BASE_ISO="$2"; shift 2 ;;
            --kickstart)
                KICKSTART="$2"; shift 2 ;;
            --work-dir)
                WORK_DIR="$2"; shift 2 ;;
            --keep-work)
                KEEP_WORK=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "Unknown option: $1 (use --help for usage)" ;;
        esac
    done

    # Validate required arguments
    [[ -z "$BUILD_TYPE" ]] && die "Missing required option: --type (usb|iso)"
    [[ -z "$OUTPUT_PATH" ]] && die "Missing required option: --output <path>"

    case "$BUILD_TYPE" in
        usb|iso) ;;
        *) die "Invalid build type: ${BUILD_TYPE}. Must be 'usb' or 'iso'" ;;
    esac

    if [[ -n "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
        die "Data directory not found: ${DATA_DIR}"
    fi

    if [[ -n "$BASE_ISO" && ! -f "$BASE_ISO" ]]; then
        die "Base ISO not found: ${BASE_ISO}"
    fi

    if [[ ! -f "$KICKSTART" ]]; then
        die "Kickstart file not found: ${KICKSTART}"
    fi
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_build_deps() {
    log_info "Checking build dependencies..."

    local required_tools=()

    case "$BUILD_TYPE" in
        iso)
            required_tools=(xorriso mkisofs isohybrid)
            ;;
        usb)
            required_tools=(parted mkfs.vfat mkfs.ext4 grub2-install losetup)
            ;;
    esac

    # Common tools
    required_tools+=(cp rsync mount umount)

    local missing=()
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    # mkisofs might be provided by genisoimage
    if [[ " ${missing[*]} " == *" mkisofs "* ]]; then
        if command -v genisoimage &>/dev/null; then
            missing=("${missing[@]/mkisofs}")
        fi
    fi

    # isohybrid might be in syslinux-utils
    if [[ " ${missing[*]} " == *" isohybrid "* ]]; then
        # isohybrid is optional for ISO builds
        log_warn "isohybrid not found; ISO may not be USB-bootable directly"
        missing=("${missing[@]/isohybrid}")
    fi

    # Clean empty entries
    local real_missing=()
    for m in "${missing[@]}"; do
        [[ -n "$m" ]] && real_missing+=("$m")
    done

    if [[ ${#real_missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${real_missing[*]}
Install them with: dnf install -y xorriso syslinux dosfstools e2fsprogs parted grub2-efi-x64"
    fi

    log_info "All build dependencies satisfied"
}

# ---------------------------------------------------------------------------
# Setup working directory
# ---------------------------------------------------------------------------
setup_workdir() {
    if [[ -z "$WORK_DIR" ]]; then
        WORK_DIR="$(mktemp -d /tmp/bareignite-build.XXXXXX)"
    else
        ensure_dir "$WORK_DIR"
    fi
    log_info "Working directory: ${WORK_DIR}"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    # Unmount any loop devices
    if [[ -n "${LOOP_DEV:-}" ]]; then
        umount "${WORK_DIR}/mnt/efi" 2>/dev/null || true
        umount "${WORK_DIR}/mnt/rootfs" 2>/dev/null || true
        umount "${WORK_DIR}/mnt/data" 2>/dev/null || true
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi

    # Unmount ISO working mounts
    umount "${WORK_DIR}/mnt/iso" 2>/dev/null || true

    if [[ "$KEEP_WORK" == "false" && -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
        log_info "Cleaning up working directory..."
        rm -rf "$WORK_DIR"
    elif [[ "$KEEP_WORK" == "true" ]]; then
        log_info "Keeping working directory: ${WORK_DIR}"
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_error "Build failed with exit code ${exit_code}"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Prepare BareIgnite overlay
# ---------------------------------------------------------------------------
prepare_overlay() {
    local overlay_dir="${WORK_DIR}/overlay"
    ensure_dir "$overlay_dir"

    log_info "Preparing BareIgnite overlay..."

    # Copy overlay files
    local src_overlay="${SCRIPT_DIR}/overlay"
    if [[ -d "$src_overlay" ]]; then
        cp -a "$src_overlay/." "$overlay_dir/"
        log_info "  Copied overlay files from ${src_overlay}"
    fi

    # Copy core scripts
    if [[ -d "${BAREIGNITE_ROOT}/scripts" ]]; then
        ensure_dir "${overlay_dir}/scripts"
        cp -a "${BAREIGNITE_ROOT}/scripts/." "${overlay_dir}/scripts/"
        log_info "  Copied scripts"
    fi

    # Copy main CLI
    if [[ -f "${BAREIGNITE_ROOT}/bareignite.sh" ]]; then
        cp "${BAREIGNITE_ROOT}/bareignite.sh" "${overlay_dir}/"
        chmod +x "${overlay_dir}/bareignite.sh"
    fi

    # Copy VERSION
    if [[ -f "${BAREIGNITE_ROOT}/VERSION" ]]; then
        cp "${BAREIGNITE_ROOT}/VERSION" "${overlay_dir}/"
    fi

    # Copy templates
    if [[ -d "${BAREIGNITE_ROOT}/templates" ]]; then
        ensure_dir "${overlay_dir}/templates"
        cp -a "${BAREIGNITE_ROOT}/templates/." "${overlay_dir}/templates/"
        log_info "  Copied templates"
    fi

    # Copy conf
    if [[ -d "${BAREIGNITE_ROOT}/conf" ]]; then
        ensure_dir "${overlay_dir}/conf"
        cp -a "${BAREIGNITE_ROOT}/conf/." "${overlay_dir}/conf/"
        log_info "  Copied configuration"
    fi

    # Copy PXE files
    if [[ -d "${BAREIGNITE_ROOT}/pxe" ]]; then
        ensure_dir "${overlay_dir}/pxe"
        cp -a "${BAREIGNITE_ROOT}/pxe/." "${overlay_dir}/pxe/"
        log_info "  Copied PXE files"
    fi

    # Copy tools
    if [[ -d "${BAREIGNITE_ROOT}/tools" ]]; then
        ensure_dir "${overlay_dir}/tools"
        cp -a "${BAREIGNITE_ROOT}/tools/." "${overlay_dir}/tools/"
        log_info "  Copied tools"
    fi

    # Copy ansible roles
    if [[ -d "${BAREIGNITE_ROOT}/ansible" ]]; then
        ensure_dir "${overlay_dir}/ansible"
        cp -a "${BAREIGNITE_ROOT}/ansible/." "${overlay_dir}/ansible/"
        log_info "  Copied Ansible roles"
    fi

    # Copy forge CLI
    if [[ -d "${BAREIGNITE_ROOT}/forge/cli" ]]; then
        ensure_dir "${overlay_dir}/forge/cli"
        cp -a "${BAREIGNITE_ROOT}/forge/cli/." "${overlay_dir}/forge/cli/"
        log_info "  Copied Forge CLI"
    fi

    echo "$overlay_dir"
}

# ---------------------------------------------------------------------------
# Build ISO
# ---------------------------------------------------------------------------
build_iso() {
    log_info "Building BareIgnite Live ISO..."

    local iso_root="${WORK_DIR}/iso-root"
    ensure_dir "$iso_root"

    local overlay_dir
    overlay_dir="$(prepare_overlay)"

    if [[ -n "$BASE_ISO" ]]; then
        # --- Customize existing Rocky Live ISO ---
        build_iso_from_base "$iso_root" "$overlay_dir"
    else
        # --- Build from scratch using livemedia-creator ---
        build_iso_from_scratch "$iso_root" "$overlay_dir"
    fi

    log_info "ISO build complete: ${OUTPUT_PATH}"
    print_iso_info
}

# ---------------------------------------------------------------------------
# Build ISO from pre-built base
# ---------------------------------------------------------------------------
build_iso_from_base() {
    local iso_root="$1"
    local overlay_dir="$2"

    log_info "Customizing base ISO: ${BASE_ISO}"

    # Mount the base ISO
    local base_mount="${WORK_DIR}/mnt/iso"
    ensure_dir "$base_mount"
    mount -o loop,ro "$BASE_ISO" "$base_mount" \
        || die "Failed to mount base ISO"

    # Copy base ISO contents
    log_info "Copying base ISO contents..."
    rsync -a "$base_mount/" "$iso_root/" \
        || die "Failed to copy base ISO contents"

    # Add BareIgnite overlay
    local overlay_dest="${iso_root}/bareignite-overlay"
    ensure_dir "$overlay_dest"
    cp -a "$overlay_dir/." "$overlay_dest/"
    log_info "Added BareIgnite overlay"

    # Add data directory if specified
    if [[ -n "$DATA_DIR" ]]; then
        log_info "Adding data directory..."
        local data_dest="${iso_root}/bareignite-data"
        ensure_dir "$data_dest"
        rsync -a --info=progress2 "$DATA_DIR/" "$data_dest/"
        log_info "Data directory added"
    fi

    # Unmount base ISO
    umount "$base_mount"

    # Create the new ISO
    log_info "Creating ISO image..."
    create_bootable_iso "$iso_root"
}

# ---------------------------------------------------------------------------
# Build ISO from scratch using livemedia-creator or mock
# ---------------------------------------------------------------------------
build_iso_from_scratch() {
    local iso_root="$1"
    local overlay_dir="$2"

    # Check for livemedia-creator
    if command -v livemedia-creator &>/dev/null; then
        log_info "Building Live image with livemedia-creator..."
        log_info "This may take 15-30 minutes..."

        # Prepare a modified kickstart that includes our overlay
        local modified_ks="${WORK_DIR}/liveusb-modified.ks"
        cp "$KICKSTART" "$modified_ks"

        # Run livemedia-creator
        local resultdir="${WORK_DIR}/livemedia-result"
        ensure_dir "$resultdir"

        livemedia-creator \
            --ks="$modified_ks" \
            --no-virt \
            --resultdir="$resultdir" \
            --project="BareIgnite" \
            --releasever="9" \
            --make-iso \
            --iso-only \
            --iso-name="bareignite-live.iso" \
            --volid="$ISO_VOLID" \
            --title="BareIgnite Live" \
            2>&1 | tee "${WORK_DIR}/livemedia-creator.log" \
            || die "livemedia-creator failed. Check ${WORK_DIR}/livemedia-creator.log"

        # The output ISO needs further customization to add overlay
        local base="${resultdir}/bareignite-live.iso"
        if [[ -f "$base" ]]; then
            BASE_ISO="$base"
            build_iso_from_base "$iso_root" "$overlay_dir"
        else
            die "livemedia-creator did not produce expected output"
        fi
    else
        # Fallback: create a manual ISO structure
        log_warn "livemedia-creator not found. Building manual ISO structure."
        log_warn "Install lorax: dnf install -y lorax"
        log_warn "Creating a data-only ISO with BareIgnite files..."

        build_data_iso "$iso_root" "$overlay_dir"
    fi
}

# ---------------------------------------------------------------------------
# Build a data-only ISO (fallback when livemedia-creator unavailable)
# ---------------------------------------------------------------------------
build_data_iso() {
    local iso_root="$1"
    local overlay_dir="$2"

    log_info "Creating BareIgnite data ISO..."

    # Copy overlay (BareIgnite project files)
    local bi_dest="${iso_root}/BareIgnite"
    ensure_dir "$bi_dest"
    cp -a "$overlay_dir/." "$bi_dest/"

    # Copy kickstart for reference
    ensure_dir "${iso_root}/kickstart"
    cp "$KICKSTART" "${iso_root}/kickstart/"

    # Add data directory if specified
    if [[ -n "$DATA_DIR" ]]; then
        log_info "Adding data directory..."
        rsync -a --info=progress2 "$DATA_DIR/" "${bi_dest}/"
        log_info "Data directory added"
    fi

    # Create a README on the ISO
    cat > "${iso_root}/README.txt" <<'README'
BareIgnite - Offline Bare Metal Server Provisioning
====================================================

This disc contains BareIgnite project files and OS images.

To use with a Live USB:
  1. Boot from BareIgnite Live USB
  2. Insert this disc
  3. The media-loader will automatically detect and copy files

To install BareIgnite on an existing Rocky 9 system:
  1. Mount this disc: mount /dev/sr0 /mnt
  2. Copy files: cp -a /mnt/BareIgnite /opt/bareignite
  3. Run: /opt/bareignite/bareignite.sh --help
README

    # Create the ISO
    create_bootable_iso "$iso_root"
}

# ---------------------------------------------------------------------------
# Create bootable ISO using xorriso
# ---------------------------------------------------------------------------
create_bootable_iso() {
    local iso_root="$1"

    log_info "Creating bootable ISO: ${OUTPUT_PATH}..."

    # Ensure parent directory exists
    ensure_dir "$(dirname "$OUTPUT_PATH")"

    # Check for EFI boot files in the ISO root
    local efi_boot_args=()
    if [[ -d "${iso_root}/EFI" ]]; then
        # Create EFI boot image if not present
        if [[ ! -f "${iso_root}/images/efiboot.img" ]]; then
            log_info "Creating EFI boot image..."
            ensure_dir "${iso_root}/images"

            local efi_img="${iso_root}/images/efiboot.img"
            dd if=/dev/zero of="$efi_img" bs=1M count=10 2>/dev/null
            mkfs.vfat "$efi_img" >/dev/null
            local efi_mnt="${WORK_DIR}/mnt/efi-img"
            ensure_dir "$efi_mnt"
            mount -o loop "$efi_img" "$efi_mnt"
            ensure_dir "${efi_mnt}/EFI/BOOT"
            cp -a "${iso_root}/EFI/BOOT/." "${efi_mnt}/EFI/BOOT/" 2>/dev/null || true
            umount "$efi_mnt"
        fi

        efi_boot_args=(
            -eltorito-alt-boot
            -e images/efiboot.img
            -no-emul-boot
        )
    fi

    # Check for BIOS boot (isolinux)
    local bios_boot_args=()
    if [[ -f "${iso_root}/isolinux/isolinux.bin" ]]; then
        bios_boot_args=(
            -b isolinux/isolinux.bin
            -c isolinux/boot.cat
            -no-emul-boot
            -boot-load-size 4
            -boot-info-table
        )
    fi

    # Prefer xorriso, fallback to mkisofs/genisoimage
    if command -v xorriso &>/dev/null; then
        xorriso -as mkisofs \
            -V "$ISO_VOLID" \
            -R -J \
            "${bios_boot_args[@]}" \
            "${efi_boot_args[@]}" \
            -o "$OUTPUT_PATH" \
            "$iso_root" \
            2>&1 || die "xorriso failed"
    elif command -v mkisofs &>/dev/null; then
        mkisofs \
            -V "$ISO_VOLID" \
            -R -J \
            "${bios_boot_args[@]}" \
            "${efi_boot_args[@]}" \
            -o "$OUTPUT_PATH" \
            "$iso_root" \
            2>&1 || die "mkisofs failed"
    elif command -v genisoimage &>/dev/null; then
        genisoimage \
            -V "$ISO_VOLID" \
            -R -J \
            "${bios_boot_args[@]}" \
            "${efi_boot_args[@]}" \
            -o "$OUTPUT_PATH" \
            "$iso_root" \
            2>&1 || die "genisoimage failed"
    else
        die "No ISO creation tool found (xorriso, mkisofs, or genisoimage)"
    fi

    # Make ISO hybrid-bootable for USB if isohybrid is available
    if command -v isohybrid &>/dev/null && [[ ${#bios_boot_args[@]} -gt 0 ]]; then
        log_info "Making ISO hybrid-bootable (USB)..."
        isohybrid --uefi "$OUTPUT_PATH" 2>/dev/null || \
        isohybrid "$OUTPUT_PATH" 2>/dev/null || \
        log_warn "isohybrid failed; ISO may not be directly USB-bootable"
    fi

    local iso_size
    iso_size="$(stat -c%s "$OUTPUT_PATH" 2>/dev/null || stat -f%z "$OUTPUT_PATH" 2>/dev/null || echo 0)"
    log_info "ISO created: ${OUTPUT_PATH} ($(numfmt --to=iec-i --suffix=B "$iso_size" 2>/dev/null || echo "${iso_size} bytes"))"
}

# ---------------------------------------------------------------------------
# Build USB image
# ---------------------------------------------------------------------------
LOOP_DEV=""

build_usb() {
    log_info "Building BareIgnite USB image..."

    local overlay_dir
    overlay_dir="$(prepare_overlay)"

    # Calculate image size
    local data_size_mb=0
    if [[ -n "$DATA_DIR" ]]; then
        data_size_mb=$(( $(du -sm "$DATA_DIR" | awk '{print $1}') + 512 ))  # +512MB buffer
        log_info "Data directory size: ~${data_size_mb}MB"
    else
        data_size_mb=1024  # 1GB minimum for data partition
    fi

    local total_size_mb=$(( EFI_SIZE_MB + ROOTFS_SIZE_MB + data_size_mb + 64 ))  # +64MB alignment
    log_info "Total image size: ~${total_size_mb}MB"

    # Ensure parent directory exists
    ensure_dir "$(dirname "$OUTPUT_PATH")"

    # Create disk image file
    log_info "Creating disk image: ${OUTPUT_PATH}"
    dd if=/dev/zero of="$OUTPUT_PATH" bs=1M count="$total_size_mb" status=progress 2>&1 \
        || die "Failed to create disk image"

    # Setup loop device
    LOOP_DEV="$(losetup --find --show "$OUTPUT_PATH")" \
        || die "Failed to setup loop device"
    log_info "Loop device: ${LOOP_DEV}"

    # Create partition table (GPT for UEFI support)
    log_info "Creating partition table..."
    parted -s "$LOOP_DEV" mklabel gpt

    # Partition 1: EFI System Partition (FAT32)
    parted -s "$LOOP_DEV" mkpart primary fat32 1MiB "${EFI_SIZE_MB}MiB"
    parted -s "$LOOP_DEV" set 1 esp on

    # Partition 2: Root filesystem (ext4)
    local rootfs_end=$(( EFI_SIZE_MB + ROOTFS_SIZE_MB ))
    parted -s "$LOOP_DEV" mkpart primary ext4 "${EFI_SIZE_MB}MiB" "${rootfs_end}MiB"

    # Partition 3: Data partition (ext4, rest of disk)
    parted -s "$LOOP_DEV" mkpart primary ext4 "${rootfs_end}MiB" 100%

    # Refresh partition table
    partprobe "$LOOP_DEV" 2>/dev/null || true
    sleep 1

    # Determine partition device naming
    local part_prefix="${LOOP_DEV}"
    if [[ "$LOOP_DEV" == *loop* ]]; then
        part_prefix="${LOOP_DEV}p"
    fi

    local efi_part="${part_prefix}1"
    local rootfs_part="${part_prefix}2"
    local data_part="${part_prefix}3"

    # Wait for partition devices
    local wait_count=0
    while [[ ! -b "$efi_part" && $wait_count -lt 10 ]]; do
        sleep 1
        wait_count=$(( wait_count + 1 ))
        partprobe "$LOOP_DEV" 2>/dev/null || true
    done

    [[ -b "$efi_part" ]] || die "Partition device ${efi_part} not found"

    # Format partitions
    log_info "Formatting partitions..."
    mkfs.vfat -F 32 -n "EFI" "$efi_part" || die "Failed to format EFI partition"
    mkfs.ext4 -L "BareIgnite" "$rootfs_part" || die "Failed to format rootfs partition"
    mkfs.ext4 -L "BAREIGNITE" "$data_part" || die "Failed to format data partition"

    # Mount partitions
    local mnt_efi="${WORK_DIR}/mnt/efi"
    local mnt_rootfs="${WORK_DIR}/mnt/rootfs"
    local mnt_data="${WORK_DIR}/mnt/data"
    ensure_dir "$mnt_efi" "$mnt_rootfs" "$mnt_data"

    mount "$efi_part" "$mnt_efi" || die "Failed to mount EFI partition"
    mount "$rootfs_part" "$mnt_rootfs" || die "Failed to mount rootfs partition"
    mount "$data_part" "$mnt_data" || die "Failed to mount data partition"

    # --- Populate EFI partition ---
    log_info "Setting up EFI boot..."
    setup_efi_boot "$mnt_efi" "$mnt_rootfs"

    # --- Populate rootfs ---
    log_info "Setting up root filesystem..."
    setup_rootfs "$mnt_rootfs" "$overlay_dir"

    # --- Populate data partition ---
    log_info "Setting up data partition..."
    setup_data_partition "$mnt_data" "$overlay_dir"

    # --- Install GRUB ---
    log_info "Installing GRUB bootloader..."
    install_grub "$mnt_efi" "$mnt_rootfs"

    # Sync and unmount
    log_info "Syncing and unmounting..."
    sync
    umount "$mnt_data"
    umount "$mnt_rootfs"
    umount "$mnt_efi"

    # Detach loop device
    losetup -d "$LOOP_DEV"
    LOOP_DEV=""

    log_info "USB image build complete: ${OUTPUT_PATH}"
    print_usb_info
}

# ---------------------------------------------------------------------------
# Setup EFI boot structure
# ---------------------------------------------------------------------------
setup_efi_boot() {
    local efi_mount="$1"
    local rootfs_mount="$2"

    ensure_dir "${efi_mount}/EFI/BOOT"

    # Copy EFI bootloaders
    local shim_src="/boot/efi/EFI/rocky/shimx64.efi"
    local grub_src="/boot/efi/EFI/rocky/grubx64.efi"

    if [[ -f "$shim_src" ]]; then
        cp "$shim_src" "${efi_mount}/EFI/BOOT/BOOTX64.EFI"
        log_info "  Copied shimx64.efi -> BOOTX64.EFI"
    elif [[ -f "/usr/lib/shim/shimx64.efi" ]]; then
        cp "/usr/lib/shim/shimx64.efi" "${efi_mount}/EFI/BOOT/BOOTX64.EFI"
    else
        log_warn "  shimx64.efi not found; UEFI Secure Boot may not work"
        # Try to use grubx64.efi directly as BOOTX64.EFI
        if [[ -f "$grub_src" ]]; then
            cp "$grub_src" "${efi_mount}/EFI/BOOT/BOOTX64.EFI"
        fi
    fi

    if [[ -f "$grub_src" ]]; then
        cp "$grub_src" "${efi_mount}/EFI/BOOT/grubx64.efi"
        log_info "  Copied grubx64.efi"
    elif [[ -f "/usr/lib/grub/x86_64-efi/grub.efi" ]]; then
        cp "/usr/lib/grub/x86_64-efi/grub.efi" "${efi_mount}/EFI/BOOT/grubx64.efi"
    else
        log_warn "  grubx64.efi not found"
    fi

    # Create GRUB configuration
    cat > "${efi_mount}/EFI/BOOT/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=5

menuentry "BareIgnite Live" --class os {
    search --no-floppy --label BareIgnite --set root
    linux /boot/vmlinuz root=live:LABEL=BareIgnite rd.live.image quiet
    initrd /boot/initramfs.img
}

menuentry "BareIgnite Live (Debug)" --class os {
    search --no-floppy --label BareIgnite --set root
    linux /boot/vmlinuz root=live:LABEL=BareIgnite rd.live.image rd.debug console=tty0
    initrd /boot/initramfs.img
}
GRUBCFG

    log_info "  EFI boot structure created"
}

# ---------------------------------------------------------------------------
# Setup root filesystem (minimal -- for live image)
# ---------------------------------------------------------------------------
setup_rootfs() {
    local rootfs_mount="$1"
    local overlay_dir="$2"

    # If we have a base ISO, extract the squashfs/live image
    if [[ -n "$BASE_ISO" ]]; then
        log_info "  Extracting live image from base ISO..."
        local iso_mnt="${WORK_DIR}/mnt/iso"
        ensure_dir "$iso_mnt"
        mount -o loop,ro "$BASE_ISO" "$iso_mnt" 2>/dev/null || true

        # Copy the squashfs image and kernel
        if [[ -d "${iso_mnt}/LiveOS" ]]; then
            ensure_dir "${rootfs_mount}/LiveOS"
            cp -a "${iso_mnt}/LiveOS/." "${rootfs_mount}/LiveOS/"
            log_info "  Copied LiveOS"
        fi

        if [[ -d "${iso_mnt}/images" ]]; then
            ensure_dir "${rootfs_mount}/images"
            cp -a "${iso_mnt}/images/." "${rootfs_mount}/images/"
        fi

        # Copy kernel and initramfs
        local boot_dir="${rootfs_mount}/boot"
        ensure_dir "$boot_dir"

        if [[ -d "${iso_mnt}/isolinux" ]]; then
            cp "${iso_mnt}/isolinux/vmlinuz" "${boot_dir}/vmlinuz" 2>/dev/null || true
            cp "${iso_mnt}/isolinux/initrd.img" "${boot_dir}/initramfs.img" 2>/dev/null || true
        fi

        # Look for kernel in images/pxeboot
        if [[ -d "${iso_mnt}/images/pxeboot" ]]; then
            cp "${iso_mnt}/images/pxeboot/vmlinuz" "${boot_dir}/vmlinuz" 2>/dev/null || true
            cp "${iso_mnt}/images/pxeboot/initrd.img" "${boot_dir}/initramfs.img" 2>/dev/null || true
        fi

        umount "$iso_mnt" 2>/dev/null || true
    else
        log_warn "  No base ISO; rootfs will need manual population"
        log_warn "  Use --base-iso to provide a Rocky 9 Live ISO"

        # Create minimal structure
        ensure_dir "${rootfs_mount}/boot"
        ensure_dir "${rootfs_mount}/LiveOS"
    fi

    # Add BareIgnite overlay to rootfs (so it's available even without data partition)
    local bi_root="${rootfs_mount}/opt/bareignite"
    ensure_dir "$bi_root"
    cp -a "$overlay_dir/." "$bi_root/"
    chmod +x "${bi_root}/bareignite.sh" 2>/dev/null || true
    chmod +x "${bi_root}/liveusb/overlay/bareignite-init.sh" 2>/dev/null || true

    # Add systemd service files
    ensure_dir "${rootfs_mount}/etc/systemd/system"
    if [[ -f "${overlay_dir}/bareignite-init.service" ]]; then
        cp "${overlay_dir}/bareignite-init.service" "${rootfs_mount}/etc/systemd/system/"
    fi
    if [[ -f "${overlay_dir}/media-loader.service" ]]; then
        cp "${overlay_dir}/media-loader.service" "${rootfs_mount}/etc/systemd/system/"
    fi

    # Enable services (create symlinks)
    ensure_dir "${rootfs_mount}/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/bareignite-init.service \
        "${rootfs_mount}/etc/systemd/system/multi-user.target.wants/bareignite-init.service" 2>/dev/null || true

    log_info "  Root filesystem prepared"
}

# ---------------------------------------------------------------------------
# Setup data partition
# ---------------------------------------------------------------------------
setup_data_partition() {
    local data_mount="$1"
    local overlay_dir="$2"

    # Copy BareIgnite project files
    local bi_dest="${data_mount}/BareIgnite"
    ensure_dir "$bi_dest"
    cp -a "$overlay_dir/." "$bi_dest/"
    log_info "  Copied BareIgnite project to data partition"

    # Copy user data if specified
    if [[ -n "$DATA_DIR" ]]; then
        log_info "  Copying data directory (this may take a while)..."
        rsync -a --info=progress2 "$DATA_DIR/" "$bi_dest/" 2>&1
        log_info "  Data copied to data partition"
    fi

    # Create directory structure for projects and images
    ensure_dir "${bi_dest}/projects"
    ensure_dir "${bi_dest}/images"

    log_info "  Data partition prepared"
}

# ---------------------------------------------------------------------------
# Install GRUB bootloader
# ---------------------------------------------------------------------------
install_grub() {
    local efi_mount="$1"
    local rootfs_mount="$2"

    # GRUB config is already in EFI partition from setup_efi_boot
    # For BIOS boot, install syslinux MBR if available

    if [[ -n "${LOOP_DEV:-}" ]]; then
        # Install syslinux MBR for BIOS boot
        local mbr_bin="/usr/share/syslinux/gptmbr.bin"
        if [[ -f "$mbr_bin" ]]; then
            dd if="$mbr_bin" of="$LOOP_DEV" bs=440 count=1 conv=notrunc 2>/dev/null || true
            log_info "  Installed syslinux GPT MBR"
        else
            mbr_bin="/usr/share/syslinux/mbr.bin"
            if [[ -f "$mbr_bin" ]]; then
                dd if="$mbr_bin" of="$LOOP_DEV" bs=440 count=1 conv=notrunc 2>/dev/null || true
                log_info "  Installed syslinux MBR"
            else
                log_warn "  syslinux MBR not found; BIOS boot may not work"
            fi
        fi

        # Create syslinux config for BIOS boot
        ensure_dir "${rootfs_mount}/boot/syslinux"
        cat > "${rootfs_mount}/boot/syslinux/syslinux.cfg" <<'SYSLINUX'
DEFAULT bareignite
TIMEOUT 50
PROMPT 1

LABEL bareignite
    MENU LABEL BareIgnite Live
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initramfs.img root=live:LABEL=BareIgnite rd.live.image quiet

LABEL debug
    MENU LABEL BareIgnite Live (Debug)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initramfs.img root=live:LABEL=BareIgnite rd.live.image rd.debug console=tty0
SYSLINUX
        log_info "  Created syslinux configuration"
    fi

    log_info "  Bootloader installation complete"
}

# ---------------------------------------------------------------------------
# Print info after ISO build
# ---------------------------------------------------------------------------
print_iso_info() {
    local size
    size="$(stat -c%s "$OUTPUT_PATH" 2>/dev/null || stat -f%z "$OUTPUT_PATH" 2>/dev/null || echo 0)"
    local size_hr
    size_hr="$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes")"

    echo ""
    echo "========================================"
    echo "  BareIgnite Live ISO Built"
    echo "========================================"
    echo ""
    echo "  Output:  ${OUTPUT_PATH}"
    echo "  Size:    ${size_hr}"
    echo ""
    echo "  To burn to DVD:"
    echo "    growisofs -Z /dev/sr0=${OUTPUT_PATH}"
    echo ""
    echo "  To write to USB (if hybrid):"
    echo "    dd if=${OUTPUT_PATH} of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
    echo "  To test in a VM:"
    echo "    qemu-system-x86_64 -cdrom ${OUTPUT_PATH} -m 4096 -enable-kvm"
    echo ""
}

# ---------------------------------------------------------------------------
# Print info after USB build
# ---------------------------------------------------------------------------
print_usb_info() {
    local size
    size="$(stat -c%s "$OUTPUT_PATH" 2>/dev/null || stat -f%z "$OUTPUT_PATH" 2>/dev/null || echo 0)"
    local size_hr
    size_hr="$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes")"

    echo ""
    echo "========================================"
    echo "  BareIgnite USB Image Built"
    echo "========================================"
    echo ""
    echo "  Output:  ${OUTPUT_PATH}"
    echo "  Size:    ${size_hr}"
    echo ""
    echo "  Layout:"
    echo "    Part 1: EFI System (FAT32, ${EFI_SIZE_MB}MB)"
    echo "    Part 2: Root FS (ext4, ${ROOTFS_SIZE_MB}MB)"
    echo "    Part 3: Data (ext4, remainder)"
    echo ""
    echo "  To write to USB drive:"
    echo "    WARNING: This will DESTROY all data on the target device!"
    echo ""
    echo "    # Identify your USB device (usually /dev/sdb or /dev/sdc)"
    echo "    lsblk"
    echo ""
    echo "    # Write the image (replace /dev/sdX with your device)"
    echo "    dd if=${OUTPUT_PATH} of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
    echo "    # Sync and safely eject"
    echo "    sync"
    echo "    eject /dev/sdX"
    echo ""
    echo "  To test in a VM:"
    echo "    qemu-system-x86_64 -drive file=${OUTPUT_PATH},format=raw -m 4096 -enable-kvm"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo ""
    echo "========================================"
    echo "  BareIgnite Live Media Builder"
    echo "========================================"
    echo "  Type:    ${BUILD_TYPE}"
    echo "  Output:  ${OUTPUT_PATH}"
    [[ -n "$DATA_DIR" ]] && echo "  Data:    ${DATA_DIR}"
    [[ -n "$BASE_ISO" ]] && echo "  Base:    ${BASE_ISO}"
    echo "========================================"
    echo ""

    # Must be root for mount/losetup operations
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root (for mount, losetup, etc.)"
    fi

    check_build_deps
    setup_workdir

    case "$BUILD_TYPE" in
        iso) build_iso ;;
        usb) build_usb ;;
    esac

    log_info "Build complete!"
}

main "$@"
