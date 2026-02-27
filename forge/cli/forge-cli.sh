#!/usr/bin/env bash
# forge-cli.sh - BareIgnite Forge CLI client
#
# Interacts with the Forge API server to manage OS images, create build
# artifacts (USB/DVD/ISO), and check for component updates.
#
# Usage: forge-cli.sh <command> [options]
#
# Configuration:
#   FORGE_URL   Base URL of the Forge API (default: http://localhost:8000)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
FORGE_URL="${FORGE_URL:-http://localhost:8000}"
FORGE_TIMEOUT="${FORGE_TIMEOUT:-30}"       # Default curl timeout (seconds)
FORGE_LONG_TIMEOUT="${FORGE_LONG_TIMEOUT:-3600}"  # Timeout for long operations

# ---------------------------------------------------------------------------
# Color / formatting
# ---------------------------------------------------------------------------
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_CYAN="\033[0;36m"
C_BLUE="\033[0;34m"
C_DIM="\033[2m"

# Disable colors when stdout is not a terminal
if [[ ! -t 1 ]]; then
    C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BLUE="" C_DIM=""
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()  { printf "${C_GREEN}[+]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*" >&2; }
error() { printf "${C_RED}[-]${C_RESET} %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_deps() {
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            die "Required tool not found: ${cmd}. Install it and try again."
        fi
    done
}

# ---------------------------------------------------------------------------
# API call helpers
# ---------------------------------------------------------------------------
# api_get <endpoint> [extra_curl_args...]
api_get() {
    local endpoint="$1"; shift
    local url="${FORGE_URL}${endpoint}"
    local http_code body

    body="$(curl -sS --max-time "$FORGE_TIMEOUT" \
        -w '\n%{http_code}' \
        -H "Accept: application/json" \
        "$@" \
        "$url" 2>&1)" || {
        die "Failed to connect to Forge API at ${url}. Is the server running?"
    }

    http_code="$(echo "$body" | tail -1)"
    body="$(echo "$body" | sed '$d')"

    if [[ "$http_code" -ge 400 ]]; then
        local msg
        msg="$(echo "$body" | jq -r '.detail // .message // .error // "Unknown error"' 2>/dev/null || echo "$body")"
        die "API error (HTTP ${http_code}): ${msg}"
    fi

    echo "$body"
}

# api_post <endpoint> [json_body] [extra_curl_args...]
api_post() {
    local endpoint="$1"; shift
    local json_body="${1:-}"; shift 2>/dev/null || true
    local url="${FORGE_URL}${endpoint}"
    local http_code body

    local curl_args=(-sS --max-time "$FORGE_TIMEOUT" -H "Accept: application/json")

    if [[ -n "$json_body" ]]; then
        curl_args+=(-H "Content-Type: application/json" -d "$json_body")
    fi

    body="$(curl "${curl_args[@]}" \
        -w '\n%{http_code}' \
        "$@" \
        -X POST \
        "$url" 2>&1)" || {
        die "Failed to connect to Forge API at ${url}. Is the server running?"
    }

    http_code="$(echo "$body" | tail -1)"
    body="$(echo "$body" | sed '$d')"

    if [[ "$http_code" -ge 400 ]]; then
        local msg
        msg="$(echo "$body" | jq -r '.detail // .message // .error // "Unknown error"' 2>/dev/null || echo "$body")"
        die "API error (HTTP ${http_code}): ${msg}"
    fi

    echo "$body"
}

# api_post_file <endpoint> <field_name> <file_path>
api_post_file() {
    local endpoint="$1"
    local field="$2"
    local filepath="$3"
    local url="${FORGE_URL}${endpoint}"
    local http_code body

    body="$(curl -sS --max-time "$FORGE_LONG_TIMEOUT" \
        -w '\n%{http_code}' \
        -H "Accept: application/json" \
        -F "${field}=@${filepath}" \
        -X POST \
        "$url" 2>&1)" || {
        die "Failed to upload file to Forge API at ${url}"
    }

    http_code="$(echo "$body" | tail -1)"
    body="$(echo "$body" | sed '$d')"

    if [[ "$http_code" -ge 400 ]]; then
        local msg
        msg="$(echo "$body" | jq -r '.detail // .message // .error // "Unknown error"' 2>/dev/null || echo "$body")"
        die "API error (HTTP ${http_code}): ${msg}"
    fi

    echo "$body"
}

# ---------------------------------------------------------------------------
# Pretty-print helpers
# ---------------------------------------------------------------------------
# Print a formatted table from JSON array
# print_table <json_array> <column_spec>
# column_spec: "header1:jq_expr1,header2:jq_expr2,..."
print_table() {
    local json="$1"
    local spec="$2"

    # Parse column specs
    IFS=',' read -ra cols <<< "$spec"
    local headers=()
    local exprs=()
    for col in "${cols[@]}"; do
        headers+=("${col%%:*}")
        exprs+=("${col#*:}")
    done

    # Print header
    local header_line=""
    local sep_line=""
    for h in "${headers[@]}"; do
        header_line+="$(printf "%-20s" "$h")"
        sep_line+="$(printf "%-20s" "--------------------")"
    done
    printf "${C_BOLD}%s${C_RESET}\n" "$header_line"
    printf "${C_DIM}%s${C_RESET}\n" "$sep_line"

    # Print rows
    local count
    count="$(echo "$json" | jq 'length')"
    for (( i=0; i<count; i++ )); do
        local row=""
        for expr in "${exprs[@]}"; do
            local val
            val="$(echo "$json" | jq -r ".[$i] | ${expr} // \"--\"" 2>/dev/null || echo "--")"
            row+="$(printf "%-20s" "$val")"
        done
        echo "$row"
    done

    printf "\n${C_DIM}Total: %d entries${C_RESET}\n" "$count"
}

# Format file size
format_size() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        printf "%.1fGB" "$(echo "scale=1; $bytes / 1073741824" | bc 2>/dev/null || echo 0)"
    elif (( bytes >= 1048576 )); then
        printf "%.1fMB" "$(echo "scale=1; $bytes / 1048576" | bc 2>/dev/null || echo 0)"
    elif (( bytes >= 1024 )); then
        printf "%.1fKB" "$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo 0)"
    else
        printf "%dB" "$bytes"
    fi
}

# Print a progress bar
print_progress() {
    local pct="$1"
    local label="${2:-}"
    local width=40
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    printf "\r  %s [" "$label"
    printf "${C_GREEN}%*s${C_RESET}" "$filled" | tr ' ' '#'
    printf "%*s" "$empty" | tr ' ' '-'
    printf "] %3d%%" "$pct"
}

# ---------------------------------------------------------------------------
# Command: images list
# ---------------------------------------------------------------------------
cmd_images_list() {
    info "Fetching image list from Forge..."
    local response
    response="$(api_get "/api/images")"

    local images
    images="$(echo "$response" | jq '.images // []')"

    local total cached
    total="$(echo "$response" | jq '.total // 0')"
    cached="$(echo "$response" | jq '.cached_count // 0')"

    echo ""
    printf "${C_BOLD}OS Images${C_RESET} (${cached}/${total} cached)\n"
    echo ""

    print_table "$images" \
        "ID:.id,Name:.name,Version:.version,Arch:.arch,Size:.size,Cached:.cached"
}

# ---------------------------------------------------------------------------
# Command: images pull
# ---------------------------------------------------------------------------
cmd_images_pull() {
    local os_id="${1:?'Usage: forge-cli images pull <os_id> [arch]'}"
    local arch="${2:-x86_64}"

    info "Requesting download: ${os_id} (${arch})..."

    local body
    body="$(jq -n --arg id "$os_id" --arg arch "$arch" \
        '{os_id: $id, arch: $arch}')"

    local response
    response="$(api_post "/api/images/pull" "$body")"

    local status
    status="$(echo "$response" | jq -r '.status // "unknown"')"
    info "Download status: ${status}"

    # Poll for progress if status is downloading
    if [[ "$status" == "downloading" || "$status" == "pending" ]]; then
        info "Monitoring download progress..."
        poll_download_progress "$os_id"
    else
        echo "$response" | jq .
    fi
}

# Poll download progress until completion
poll_download_progress() {
    local os_id="$1"
    local prev_pct=-1

    while true; do
        sleep 2
        local response
        response="$(api_get "/api/images/${os_id}/progress" 2>/dev/null || echo '{}')"

        local status pct
        status="$(echo "$response" | jq -r '.status // "unknown"')"
        pct="$(echo "$response" | jq -r '.progress // 0' | cut -d. -f1)"

        case "$status" in
            downloading)
                if [[ "$pct" != "$prev_pct" ]]; then
                    print_progress "$pct" "Downloading"
                    prev_pct="$pct"
                fi
                ;;
            verifying)
                printf "\r"
                info "Verifying checksum..."
                ;;
            completed)
                printf "\n"
                info "Download complete!"
                echo "$response" | jq '{os_id, status, size: .downloaded_bytes}'
                return 0
                ;;
            failed)
                printf "\n"
                local err
                err="$(echo "$response" | jq -r '.error // "Unknown error"')"
                die "Download failed: ${err}"
                ;;
            *)
                # Unknown status, show raw response
                echo "$response" | jq . 2>/dev/null || echo "$response"
                return 0
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Command: images import
# ---------------------------------------------------------------------------
cmd_images_import() {
    local filepath="${1:?'Usage: forge-cli images import <path> [--os-id <id>] [--name <name>] [--version <ver>] [--arch <arch>] [--family <family>]'}"
    shift

    # Parse optional flags
    local os_id="" name="" version="" arch="x86_64" family="rhel"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --os-id)  os_id="$2"; shift 2 ;;
            --name)   name="$2"; shift 2 ;;
            --version) version="$2"; shift 2 ;;
            --arch)   arch="$2"; shift 2 ;;
            --family) family="$2"; shift 2 ;;
            *) die "Unknown option for import: $1" ;;
        esac
    done

    [[ ! -f "$filepath" ]] && die "File not found: ${filepath}"

    info "Importing image: ${filepath}"

    local body
    body="$(jq -n \
        --arg path "$filepath" \
        --arg os_id "$os_id" \
        --arg name "$name" \
        --arg version "$version" \
        --arg arch "$arch" \
        --arg family "$family" \
        '{file_path: $path, os_id: $os_id, name: $name, version: $version, arch: $arch, family: $family}')"

    local response
    response="$(api_post "/api/images/import" "$body")"

    info "Import result:"
    echo "$response" | jq .
}

# ---------------------------------------------------------------------------
# Command: images check-updates
# ---------------------------------------------------------------------------
cmd_images_check_updates() {
    info "Checking for image updates..."
    local response
    response="$(api_get "/api/images/check-updates")"

    local updates
    updates="$(echo "$response" | jq '[.[] | select(.update_available == true)]' 2>/dev/null \
        || echo "$response" | jq '.' 2>/dev/null || echo "$response")"

    local count
    count="$(echo "$updates" | jq 'length' 2>/dev/null || echo 0)"

    if [[ "$count" -gt 0 ]]; then
        printf "\n${C_YELLOW}${C_BOLD}%d update(s) available:${C_RESET}\n\n" "$count"
        print_table "$updates" \
            "ID:.id,Current:.current_version,Latest:.latest_version,Name:.name"
    else
        info "All images are up to date."
    fi
}

# ---------------------------------------------------------------------------
# Command: build
# ---------------------------------------------------------------------------
cmd_build() {
    # Parse build options
    local os_list="" arch_list="" media_type="usb" target_size=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --os)     os_list="$2"; shift 2 ;;
            --arch)   arch_list="$2"; shift 2 ;;
            --media)  media_type="$2"; shift 2 ;;
            --size)   target_size="$2"; shift 2 ;;
            *) die "Unknown build option: $1" ;;
        esac
    done

    [[ -z "$os_list" ]] && die "Usage: forge-cli build --os <os1,os2,...> [--arch <arch1,arch2,...>] [--media <usb|dvd|data>] [--size <bytes>]"

    info "Creating build job..."
    info "  OS:    ${os_list}"
    info "  Arch:  ${arch_list:-x86_64}"
    info "  Media: ${media_type}"
    [[ -n "$target_size" ]] && info "  Size:  ${target_size}"

    # Convert comma-separated to JSON arrays
    local os_json arch_json
    os_json="$(echo "$os_list" | jq -R 'split(",")')"
    arch_json="$(echo "${arch_list:-x86_64}" | jq -R 'split(",")')"

    local body
    if [[ -n "$target_size" ]]; then
        body="$(jq -n \
            --argjson os "$os_json" \
            --argjson arch "$arch_json" \
            --arg media "$media_type" \
            --argjson size "$target_size" \
            '{os_list: $os, arch_list: $arch, media_type: $media, target_size: $size}')"
    else
        body="$(jq -n \
            --argjson os "$os_json" \
            --argjson arch "$arch_json" \
            --arg media "$media_type" \
            '{os_list: $os, arch_list: $arch, media_type: $media}')"
    fi

    local response
    response="$(api_post "/api/builds" "$body")"

    local build_id status
    build_id="$(echo "$response" | jq -r '.id // "unknown"')"
    status="$(echo "$response" | jq -r '.status // "unknown"')"

    info "Build job created: ${build_id} (status: ${status})"

    # If job is running/pending, poll for progress
    if [[ "$status" == "pending" || "$status" == "running" ]]; then
        info "Monitoring build progress..."
        poll_build_progress "$build_id"
    else
        echo "$response" | jq .
    fi
}

# ---------------------------------------------------------------------------
# Command: build status
# ---------------------------------------------------------------------------
cmd_build_status() {
    local build_id="${1:?'Usage: forge-cli build status <build_id>'}"

    info "Fetching build status: ${build_id}"
    local response
    response="$(api_get "/api/builds/${build_id}")"

    local status progress
    status="$(echo "$response" | jq -r '.status // "unknown"')"
    progress="$(echo "$response" | jq -r '.progress // 0')"

    printf "\n${C_BOLD}Build: %s${C_RESET}\n" "$build_id"
    printf "  Status:   %s\n" "$(colorize_status "$status")"
    printf "  Progress: %.1f%%\n" "$progress"

    # Show output files if completed
    if [[ "$status" == "completed" ]]; then
        local files
        files="$(echo "$response" | jq -r '.output_files[]? // .output_path // "N/A"')"
        printf "  Output:   %s\n" "$files"
    elif [[ "$status" == "failed" ]]; then
        local err
        err="$(echo "$response" | jq -r '.error // "Unknown"')"
        printf "  Error:    %s\n" "$err"
    fi

    # Show build log (last 5 entries)
    local log_count
    log_count="$(echo "$response" | jq '.log | length' 2>/dev/null || echo 0)"
    if (( log_count > 0 )); then
        echo ""
        printf "${C_DIM}Recent log entries:${C_RESET}\n"
        echo "$response" | jq -r '.log[-5:][]' 2>/dev/null | while IFS= read -r line; do
            printf "  ${C_DIM}%s${C_RESET}\n" "$line"
        done
    fi
    echo ""
}

# Poll build progress
poll_build_progress() {
    local build_id="$1"
    local prev_pct=-1

    while true; do
        sleep 3
        local response
        response="$(api_get "/api/builds/${build_id}" 2>/dev/null || echo '{}')"

        local status pct
        status="$(echo "$response" | jq -r '.status // "unknown"')"
        pct="$(echo "$response" | jq -r '.progress // 0' | cut -d. -f1)"

        case "$status" in
            running)
                if [[ "$pct" != "$prev_pct" ]]; then
                    print_progress "$pct" "Building"
                    prev_pct="$pct"
                fi
                ;;
            completed)
                printf "\n"
                info "Build complete!"
                local output
                output="$(echo "$response" | jq -r '.output_path // .output_files[0] // "N/A"')"
                info "Output: ${output}"
                return 0
                ;;
            failed)
                printf "\n"
                local err
                err="$(echo "$response" | jq -r '.error // "Unknown error"')"
                die "Build failed: ${err}"
                ;;
            pending)
                printf "\r  Waiting for build to start..."
                ;;
            *)
                printf "\n"
                echo "$response" | jq . 2>/dev/null || echo "$response"
                return 0
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Command: build list
# ---------------------------------------------------------------------------
cmd_build_list() {
    info "Fetching build list..."
    local response
    response="$(api_get "/api/builds")"

    local builds
    builds="$(echo "$response" | jq '.builds // []')"

    echo ""
    printf "${C_BOLD}Build Jobs${C_RESET}\n"
    echo ""

    print_table "$builds" \
        "ID:.id,Status:.status,Media:.media_type,Progress:.progress,Created:.created_at"
}

# ---------------------------------------------------------------------------
# Command: update check
# ---------------------------------------------------------------------------
cmd_update_check() {
    info "Checking for component updates..."
    local response
    response="$(api_post "/api/components/check")"

    local total updates_avail
    total="$(echo "$response" | jq '.total // 0')"
    updates_avail="$(echo "$response" | jq '.updates_available // 0')"

    echo ""
    printf "${C_BOLD}Component Update Check${C_RESET}\n"
    printf "  Total components: %d\n" "$total"

    if (( updates_avail > 0 )); then
        printf "  ${C_YELLOW}Updates available: %d${C_RESET}\n" "$updates_avail"
    else
        printf "  ${C_GREEN}All components up to date${C_RESET}\n"
    fi
    echo ""

    local components
    components="$(echo "$response" | jq '.components // []')"

    print_table "$components" \
        "Name:.name,Category:.category,Current:.current_version,Latest:.latest_version,Update:.update_available"
}

# ---------------------------------------------------------------------------
# Command: update apply
# ---------------------------------------------------------------------------
cmd_update_apply() {
    info "Applying component updates..."
    local response
    response="$(api_post "/api/components/update")"

    local status
    status="$(echo "$response" | jq -r '.status // "unknown"')"

    if [[ "$status" == "completed" || "$status" == "success" ]]; then
        info "Updates applied successfully."
    else
        warn "Update status: ${status}"
    fi

    echo "$response" | jq .
}

# ---------------------------------------------------------------------------
# Status colorization
# ---------------------------------------------------------------------------
colorize_status() {
    local status="$1"
    case "$status" in
        completed|success)
            printf "${C_GREEN}%s${C_RESET}" "$status" ;;
        failed|error)
            printf "${C_RED}%s${C_RESET}" "$status" ;;
        running|downloading)
            printf "${C_CYAN}%s${C_RESET}" "$status" ;;
        pending)
            printf "${C_YELLOW}%s${C_RESET}" "$status" ;;
        *)
            echo "$status" ;;
    esac
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
show_help() {
    cat <<EOF
${C_BOLD}BareIgnite Forge CLI${C_RESET}

Usage: $(basename "$0") <command> [options]

${C_BOLD}Image Commands:${C_RESET}
  images list                           List all available OS images
  images pull <os_id> [arch]            Download an OS image
  images import <path> [options]        Import a local ISO file
    --os-id <id>                          OS identifier
    --name <name>                         Human-readable name
    --version <ver>                       Version string
    --arch <arch>                         Architecture (default: x86_64)
    --family <family>                     OS family (default: rhel)
  images check-updates                  Check for image updates

${C_BOLD}Build Commands:${C_RESET}
  build --os <list> [options]           Create a build job
    --os <os1,os2,...>                    OS images to include (required)
    --arch <arch1,arch2,...>              Target architectures (default: x86_64)
    --media <usb|dvd|data>               Output media type (default: usb)
    --size <bytes>                        Target media size
  build status <id>                     Show build job status
  build list                            List all build jobs

${C_BOLD}Update Commands:${C_RESET}
  update check                          Check for component updates
  update apply                          Apply available updates

${C_BOLD}Configuration:${C_RESET}
  FORGE_URL          Forge API URL (default: http://localhost:8000)
  FORGE_TIMEOUT      API timeout in seconds (default: 30)

${C_BOLD}Examples:${C_RESET}
  $(basename "$0") images list
  $(basename "$0") images pull rocky9 x86_64
  $(basename "$0") build --os rocky9,ubuntu2204 --arch x86_64 --media dvd
  $(basename "$0") build status abc123
  $(basename "$0") update check

EOF
}

# ---------------------------------------------------------------------------
# Main command dispatcher
# ---------------------------------------------------------------------------
main() {
    check_deps

    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local command="$1"; shift

    case "$command" in
        images)
            local subcmd="${1:-list}"; shift 2>/dev/null || true
            case "$subcmd" in
                list)           cmd_images_list ;;
                pull)           cmd_images_pull "$@" ;;
                import)         cmd_images_import "$@" ;;
                check-updates)  cmd_images_check_updates ;;
                *)              die "Unknown images subcommand: ${subcmd}. Use: list, pull, import, check-updates" ;;
            esac
            ;;
        build)
            local subcmd="${1:-}"
            case "$subcmd" in
                status)  shift; cmd_build_status "$@" ;;
                list)    cmd_build_list ;;
                --*)     cmd_build "$subcmd" "$@" ;;
                "")      die "Usage: forge-cli build --os <list> [options] | build status <id> | build list" ;;
                *)       die "Unknown build subcommand: ${subcmd}. Use: status, list, or --os to start a build" ;;
            esac
            ;;
        update)
            local subcmd="${1:?'Usage: forge-cli update <check|apply>'}"; shift
            case "$subcmd" in
                check)  cmd_update_check ;;
                apply)  cmd_update_apply ;;
                *)      die "Unknown update subcommand: ${subcmd}. Use: check, apply" ;;
            esac
            ;;
        -h|--help|help)
            show_help
            ;;
        *)
            die "Unknown command: ${command}. Use --help for usage."
            ;;
    esac
}

main "$@"
