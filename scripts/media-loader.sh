#!/usr/bin/env bash
# media-loader.sh - DVD disc swapping/loading script for Live USB environment
#
# Reads a manifest from Disc 1 (already loaded during boot), then guides the
# user through inserting remaining discs one by one, copying their contents
# to /mnt/bareignite-data/ with verification.
#
# Usage: media-loader.sh [--data-dir <path>] [--manifest <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DATA_DIR="${BAREIGNITE_DATA_DIR:-/mnt/bareignite-data}"
MANIFEST_FILE=""
OPTICAL_DEV=""
MOUNT_POINT="/mnt/bareignite-disc"
POLL_INTERVAL=2        # seconds between disc detection polls
POLL_TIMEOUT=300       # max seconds to wait for a disc
COPY_BLOCK_SIZE="1M"   # dd block size for copying

# Accumulated counters
TOTAL_COPIED_BYTES=0
TOTAL_EXPECTED_BYTES=0

# ---------------------------------------------------------------------------
# Color helpers (extend common.sh palette for interactive use)
# ---------------------------------------------------------------------------
_COLOR_BOLD="\033[1m"
_COLOR_BLUE="\033[0;34m"
_COLOR_MAGENTA="\033[0;35m"

if [[ ! -t 1 ]]; then
    _COLOR_BOLD="" _COLOR_BLUE="" _COLOR_MAGENTA=""
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data-dir)
                DATA_DIR="$2"; shift 2 ;;
            --manifest)
                MANIFEST_FILE="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $(basename "$0") [--data-dir <path>] [--manifest <path>]"
                echo ""
                echo "Load BareIgnite data from multi-disc DVD set."
                echo ""
                echo "Options:"
                echo "  --data-dir <path>   Destination directory (default: /mnt/bareignite-data)"
                echo "  --manifest <path>   Path to manifest.txt (default: auto-detect on disc)"
                exit 0
                ;;
            *)
                die "Unknown option: $1" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Detect optical drive
# ---------------------------------------------------------------------------
detect_optical_drive() {
    local candidates=(/dev/sr0 /dev/cdrom /dev/dvd)
    for dev in "${candidates[@]}"; do
        if [[ -b "$dev" ]]; then
            OPTICAL_DEV="$dev"
            log_info "Detected optical drive: ${OPTICAL_DEV}"
            return 0
        fi
    done
    die "No optical drive detected. Checked: ${candidates[*]}"
}

# ---------------------------------------------------------------------------
# Mount / unmount helpers
# ---------------------------------------------------------------------------
mount_disc() {
    ensure_dir "$MOUNT_POINT"
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_debug "Disc already mounted at ${MOUNT_POINT}, unmounting first"
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    mount -o ro "$OPTICAL_DEV" "$MOUNT_POINT" \
        || die "Failed to mount ${OPTICAL_DEV} at ${MOUNT_POINT}"
    log_debug "Mounted ${OPTICAL_DEV} at ${MOUNT_POINT}"
}

unmount_disc() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" \
            || log_warn "Failed to unmount ${MOUNT_POINT}"
    fi
}

eject_disc() {
    unmount_disc
    if command -v eject &>/dev/null; then
        eject "$OPTICAL_DEV" 2>/dev/null || log_warn "Eject command failed"
    else
        log_warn "'eject' command not found; please remove disc manually"
    fi
}

# ---------------------------------------------------------------------------
# Wait for a disc to be inserted and detected
# ---------------------------------------------------------------------------
wait_for_disc() {
    local waited=0
    log_debug "Waiting for disc in ${OPTICAL_DEV}..."
    while (( waited < POLL_TIMEOUT )); do
        # Try to read the device; a disc is present if blockdev succeeds
        if blockdev --getsize64 "$OPTICAL_DEV" &>/dev/null; then
            # Give the drive a moment to spin up
            sleep 1
            return 0
        fi
        sleep "$POLL_INTERVAL"
        waited=$(( waited + POLL_INTERVAL ))
    done
    die "Timed out waiting for disc after ${POLL_TIMEOUT}s"
}

# ---------------------------------------------------------------------------
# Parse manifest file
# ---------------------------------------------------------------------------
# Manifest format (manifest.txt on Disc 1):
#   # BareIgnite Multi-Disc Manifest
#   # total_discs=4
#   # total_size=12500000000
#   disc:1
#   sha256:abcdef1234567890  images/rocky/9/x86_64/Rocky-9.5-x86_64-dvd.iso
#   sha256:1234567890abcdef  images/ubuntu/2204/x86_64/ubuntu-22.04.4-live-server-amd64.iso
#   disc:2
#   sha256:fedcba0987654321  images/esxi/8/VMware-VMvisor-Installer-8.0-x86_64.iso
#   ...
#
# Returns variables: TOTAL_DISCS, TOTAL_SIZE_BYTES, DISC_FILES (associative array)
declare -A DISC_FILES       # disc_number -> newline-separated "sha256:checksum  path"
declare -A DISC_LABELS      # disc_number -> comma-separated short file names
TOTAL_DISCS=0
TOTAL_SIZE_BYTES=0

parse_manifest() {
    local manifest_path="$1"
    if [[ ! -f "$manifest_path" ]]; then
        die "Manifest file not found: ${manifest_path}"
    fi

    local current_disc=0
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Parse header comments
        if [[ "$line" == \#* ]]; then
            if [[ "$line" =~ total_discs=([0-9]+) ]]; then
                TOTAL_DISCS="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ total_size=([0-9]+) ]]; then
                TOTAL_SIZE_BYTES="${BASH_REMATCH[1]}"
                TOTAL_EXPECTED_BYTES="$TOTAL_SIZE_BYTES"
            fi
            continue
        fi

        # Disc separator
        if [[ "$line" =~ ^disc:([0-9]+)$ ]]; then
            current_disc="${BASH_REMATCH[1]}"
            continue
        fi

        # File entry: sha256:checksum  path
        if [[ "$line" =~ ^sha256:([a-f0-9]+)[[:space:]]+(.+)$ ]]; then
            local checksum="${BASH_REMATCH[1]}"
            local filepath="${BASH_REMATCH[2]}"

            if [[ -n "${DISC_FILES[$current_disc]:-}" ]]; then
                DISC_FILES[$current_disc]+=$'\n'"sha256:${checksum}  ${filepath}"
            else
                DISC_FILES[$current_disc]="sha256:${checksum}  ${filepath}"
            fi

            # Build short label
            local short_name
            short_name="$(basename "$filepath")"
            if [[ -n "${DISC_LABELS[$current_disc]:-}" ]]; then
                DISC_LABELS[$current_disc]+=", ${short_name}"
            else
                DISC_LABELS[$current_disc]="$short_name"
            fi
        fi
    done < "$manifest_path"

    if [[ "$TOTAL_DISCS" -eq 0 ]]; then
        die "Invalid manifest: total_discs not specified or is 0"
    fi

    log_info "Manifest loaded: ${TOTAL_DISCS} disc(s), $(format_bytes "$TOTAL_SIZE_BYTES") total"
}

# ---------------------------------------------------------------------------
# Format bytes to human-readable
# ---------------------------------------------------------------------------
format_bytes() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        printf "%.1fGB" "$(echo "scale=1; $bytes / 1073741824" | bc 2>/dev/null || echo "0")"
    elif (( bytes >= 1048576 )); then
        printf "%.1fMB" "$(echo "scale=1; $bytes / 1048576" | bc 2>/dev/null || echo "0")"
    elif (( bytes >= 1024 )); then
        printf "%.1fKB" "$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "0")"
    else
        printf "%dB" "$bytes"
    fi
}

# ---------------------------------------------------------------------------
# Verify disc identity
# ---------------------------------------------------------------------------
# Check that the disc contains a .disc_id file matching the expected disc number
verify_disc_identity() {
    local expected_disc="$1"
    local disc_id_file="${MOUNT_POINT}/.disc_id"

    if [[ -f "$disc_id_file" ]]; then
        local found_disc
        found_disc="$(cat "$disc_id_file" | tr -d '[:space:]')"
        if [[ "$found_disc" != "$expected_disc" ]]; then
            log_error "Wrong disc inserted! Expected Disc ${expected_disc}, found Disc ${found_disc}."
            return 1
        fi
        log_debug "Disc identity verified: Disc ${expected_disc}"
        return 0
    fi

    # No disc ID file -- check by content presence
    log_warn "No .disc_id file on disc; verifying by file presence..."
    local entries="${DISC_FILES[$expected_disc]:-}"
    if [[ -z "$entries" ]]; then
        log_warn "No files expected for disc ${expected_disc} in manifest"
        return 0
    fi

    local first_file
    first_file="$(echo "$entries" | head -1 | awk '{print $2}')"
    if [[ -f "${MOUNT_POINT}/${first_file}" ]]; then
        log_debug "First expected file found on disc: ${first_file}"
        return 0
    else
        log_error "Expected file not found on disc: ${first_file}"
        log_error "This may be the wrong disc."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Check available disk space
# ---------------------------------------------------------------------------
check_disk_space() {
    local required_bytes="$1"
    local dest_dir="$2"

    ensure_dir "$dest_dir"

    local available_kb
    available_kb="$(df -k "$dest_dir" | tail -1 | awk '{print $4}')"
    local available_bytes=$(( available_kb * 1024 ))

    if (( available_bytes < required_bytes )); then
        local avail_hr
        avail_hr="$(format_bytes "$available_bytes")"
        local req_hr
        req_hr="$(format_bytes "$required_bytes")"
        die "Insufficient disk space. Available: ${avail_hr}, Required: ${req_hr}"
    fi

    log_debug "Disk space OK: $(format_bytes "$available_bytes") available"
}

# ---------------------------------------------------------------------------
# Copy files from disc to data directory with progress
# ---------------------------------------------------------------------------
copy_disc_contents() {
    local disc_num="$1"
    local entries="${DISC_FILES[$disc_num]:-}"

    if [[ -z "$entries" ]]; then
        log_warn "No files listed for disc ${disc_num} in manifest"
        return 0
    fi

    local file_count=0
    local file_total
    file_total="$(echo "$entries" | wc -l | tr -d ' ')"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local checksum filepath
        checksum="$(echo "$entry" | awk '{print $1}' | sed 's/^sha256://')"
        filepath="$(echo "$entry" | awk '{print $2}')"

        file_count=$(( file_count + 1 ))
        local src="${MOUNT_POINT}/${filepath}"
        local dst="${DATA_DIR}/${filepath}"

        if [[ ! -f "$src" ]]; then
            log_error "File not found on disc: ${filepath}"
            return 1
        fi

        # Create destination directory
        ensure_dir "$(dirname "$dst")"

        # Get file size for progress
        local file_size
        file_size="$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)"

        printf "${_COLOR_CYAN}  [%d/%d]${_COLOR_RESET} Copying: %s (%s)\n" \
            "$file_count" "$file_total" "$(basename "$filepath")" "$(format_bytes "$file_size")"

        # Copy with progress -- prefer pv if available, fallback to dd
        if command -v pv &>/dev/null; then
            pv -pterab "$src" > "$dst"
        else
            dd if="$src" of="$dst" bs="$COPY_BLOCK_SIZE" status=progress 2>&1
        fi

        # Verify checksum
        printf "  Verifying checksum... "
        local actual_checksum
        actual_checksum="$(sha256sum "$dst" | awk '{print $1}')"
        if [[ "$actual_checksum" != "$checksum" ]]; then
            printf "${_COLOR_RED}FAILED${_COLOR_RESET}\n"
            log_error "Checksum mismatch for ${filepath}"
            log_error "  Expected: ${checksum}"
            log_error "  Got:      ${actual_checksum}"
            rm -f "$dst"
            return 1
        fi
        printf "${_COLOR_GREEN}OK${_COLOR_RESET}\n"

        TOTAL_COPIED_BYTES=$(( TOTAL_COPIED_BYTES + file_size ))

    done <<< "$entries"

    log_info "Disc ${disc_num} files copied successfully"
}

# ---------------------------------------------------------------------------
# Show progress summary
# ---------------------------------------------------------------------------
show_progress() {
    local disc_num="$1"
    local total_discs="$2"

    local copied_hr
    copied_hr="$(format_bytes "$TOTAL_COPIED_BYTES")"
    local total_hr
    total_hr="$(format_bytes "$TOTAL_EXPECTED_BYTES")"

    echo ""
    printf "${_COLOR_BOLD}${_COLOR_GREEN}"
    printf "  Disc %d/%d loaded" "$disc_num" "$total_discs"
    if (( TOTAL_EXPECTED_BYTES > 0 )); then
        local pct=$(( TOTAL_COPIED_BYTES * 100 / TOTAL_EXPECTED_BYTES ))
        printf ", %s/%s copied (%d%%)" "$copied_hr" "$total_hr" "$pct"
    else
        printf ", %s copied" "$copied_hr"
    fi
    printf "${_COLOR_RESET}\n"
    echo ""
}

# ---------------------------------------------------------------------------
# Prompt user to insert a disc
# ---------------------------------------------------------------------------
prompt_insert_disc() {
    local disc_num="$1"
    local label="${DISC_LABELS[$disc_num]:-unknown contents}"

    echo ""
    print_separator "="
    printf "${_COLOR_BOLD}${_COLOR_MAGENTA}"
    printf "  Please insert Disc %d of %d" "$disc_num" "$TOTAL_DISCS"
    printf "${_COLOR_RESET}\n"
    printf "${_COLOR_BLUE}  Contains: %s${_COLOR_RESET}\n" "$label"
    print_separator "="
    echo ""

    printf "  Press ${_COLOR_BOLD}[Enter]${_COLOR_RESET} after inserting the disc..."
    read -r
}

# ---------------------------------------------------------------------------
# Load a single disc (mount, verify, copy, unmount, eject)
# ---------------------------------------------------------------------------
load_single_disc() {
    local disc_num="$1"
    local max_retries=3
    local attempt=0

    while (( attempt < max_retries )); do
        attempt=$(( attempt + 1 ))

        # Wait for disc to be detected
        log_info "Waiting for disc to be detected..."
        wait_for_disc

        # Mount
        mount_disc

        # Verify identity
        if ! verify_disc_identity "$disc_num"; then
            eject_disc
            if (( attempt < max_retries )); then
                log_warn "Attempt ${attempt}/${max_retries}. Please insert the correct disc."
                prompt_insert_disc "$disc_num"
                continue
            else
                die "Failed to load correct disc after ${max_retries} attempts."
            fi
        fi

        # Copy contents
        if ! copy_disc_contents "$disc_num"; then
            eject_disc
            if (( attempt < max_retries )); then
                log_warn "Copy failed. Retrying (attempt ${attempt}/${max_retries})..."
                prompt_insert_disc "$disc_num"
                continue
            else
                die "Failed to copy disc ${disc_num} after ${max_retries} attempts."
            fi
        fi

        # Success
        unmount_disc
        eject_disc
        show_progress "$disc_num" "$TOTAL_DISCS"
        return 0
    done
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
    unmount_disc 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo ""
    printf "${_COLOR_BOLD}========================================${_COLOR_RESET}\n"
    printf "${_COLOR_BOLD}  BareIgnite Multi-Disc Media Loader${_COLOR_RESET}\n"
    printf "${_COLOR_BOLD}========================================${_COLOR_RESET}\n"
    echo ""

    # Detect optical drive
    detect_optical_drive

    # Ensure data directory exists
    ensure_dir "$DATA_DIR"

    # Locate manifest
    if [[ -z "$MANIFEST_FILE" ]]; then
        # Try common locations: already on data dir (Disc 1 pre-loaded), or mount Disc 1
        if [[ -f "${DATA_DIR}/manifest.txt" ]]; then
            MANIFEST_FILE="${DATA_DIR}/manifest.txt"
            log_info "Found manifest at ${MANIFEST_FILE}"
        else
            # Disc 1 might still be in the drive
            log_info "Attempting to read manifest from current disc..."
            mount_disc
            if [[ -f "${MOUNT_POINT}/manifest.txt" ]]; then
                cp "${MOUNT_POINT}/manifest.txt" "${DATA_DIR}/manifest.txt"
                MANIFEST_FILE="${DATA_DIR}/manifest.txt"
                log_info "Copied manifest from disc to ${MANIFEST_FILE}"

                # Also copy Disc 1 contents while it is mounted
                log_info "Loading Disc 1 contents..."
                # Parse manifest first to know what is on Disc 1
                parse_manifest "$MANIFEST_FILE"

                if [[ -n "${DISC_FILES[1]:-}" ]]; then
                    copy_disc_contents 1
                    show_progress 1 "$TOTAL_DISCS"
                fi

                unmount_disc
                eject_disc

                # Skip Disc 1 in the main loop since we already loaded it
                local start_disc=2
            else
                unmount_disc
                die "No manifest.txt found. Is this a BareIgnite disc set?"
            fi
        fi
    fi

    # Parse manifest if not already parsed
    if [[ "$TOTAL_DISCS" -eq 0 ]]; then
        parse_manifest "$MANIFEST_FILE"
    fi

    # Determine starting disc (Disc 1 is often already loaded)
    local start_disc="${start_disc:-2}"

    if [[ -n "${DISC_FILES[1]:-}" && "$start_disc" -eq 2 ]]; then
        # Check if Disc 1 files are already present
        local disc1_done=true
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local fpath
            fpath="$(echo "$entry" | awk '{print $2}')"
            if [[ ! -f "${DATA_DIR}/${fpath}" ]]; then
                disc1_done=false
                break
            fi
        done <<< "${DISC_FILES[1]:-}"

        if [[ "$disc1_done" == "false" ]]; then
            log_info "Disc 1 files not yet loaded."
            start_disc=1
        else
            log_info "Disc 1 files already present, starting from Disc 2."
        fi
    fi

    # Check for single-disc case
    if (( TOTAL_DISCS == 1 && start_disc > 1 )); then
        log_info "Single-disc set, all data already loaded."
        printf "\n${_COLOR_BOLD}${_COLOR_GREEN}  All disc data loaded successfully!${_COLOR_RESET}\n\n"
        exit 0
    fi

    # Check disk space before starting
    if (( TOTAL_SIZE_BYTES > 0 )); then
        check_disk_space "$TOTAL_SIZE_BYTES" "$DATA_DIR"
    fi

    # Load remaining discs
    for (( disc = start_disc; disc <= TOTAL_DISCS; disc++ )); do
        prompt_insert_disc "$disc"
        load_single_disc "$disc"
    done

    # Final message
    echo ""
    print_separator "="
    printf "${_COLOR_BOLD}${_COLOR_GREEN}"
    printf "  All %d disc(s) loaded successfully!" "$TOTAL_DISCS"
    printf "${_COLOR_RESET}\n"
    printf "  Data directory: %s\n" "$DATA_DIR"
    printf "  Total copied: %s\n" "$(format_bytes "$TOTAL_COPIED_BYTES")"
    print_separator "="
    echo ""

    log_info "Media loading complete. You can now run bareignite.sh"
}

main "$@"
