#!/usr/bin/env bash
# callback-server.sh -- Lightweight HTTP callback listener for install completions
# Usage: callback-server.sh <project_dir>
#
# Listens on CALLBACK_PORT (default 8888) using socat.
# Target servers hit:  GET /callback?server=HOSTNAME&status=STATUS
#
# For each request the handler:
#   - Logs the event to callbacks.log
#   - Delegates to on-install-complete.sh to update status.json
#   - Returns HTTP 200 with a confirmation body
#
# socat forks a child for each connection; the handler script
# (callback-handler.sh) is generated at startup and executed via EXEC.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---------------------------------------------------------------------------
# Arguments & environment
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    die "Usage: $(basename "$0") <project_dir>"
fi

PROJECT_DIR="$(get_project_dir "$1")"
set_project_paths "$PROJECT_DIR"
CALLBACK_PORT="${CALLBACK_PORT:-8888}"

CALLBACKS_LOG="${LOGS_DIR}/callbacks.log"
HANDLER_SCRIPT="${PROJECT_DIR}/pids/callback-handler.sh"
ON_COMPLETE="${SCRIPT_DIR}/on-install-complete.sh"

ensure_dir "$LOGS_DIR"
ensure_dir "$(dirname "$HANDLER_SCRIPT")"

check_dependencies socat

# ---------------------------------------------------------------------------
# Generate the per-request handler script
# ---------------------------------------------------------------------------
# socat EXEC runs this script for every inbound TCP connection.
# stdin/stdout are connected to the socket.
# The script reads the HTTP request line, extracts query parameters,
# delegates to on-install-complete.sh, and writes an HTTP response.

cat > "$HANDLER_SCRIPT" <<'HANDLER_EOF'
#!/usr/bin/env bash
# Auto-generated callback handler -- do not edit manually.
# Executed by socat for each inbound connection.

set -euo pipefail

PROJECT_DIR="__PROJECT_DIR__"
CALLBACKS_LOG="__CALLBACKS_LOG__"
ON_COMPLETE="__ON_COMPLETE__"

# Read the HTTP request line (e.g., "GET /callback?server=foo&status=success HTTP/1.1")
read -r request_line || true

# Also consume remaining headers (until blank line) so the socket is clean
while IFS= read -r header_line; do
    header_line="${header_line%%$'\r'}"
    [[ -z "$header_line" ]] && break
done

# Strip trailing CR from the request line
request_line="${request_line%%$'\r'}"

# Extract the query string from the request URI
uri=""
if [[ "$request_line" =~ ^[A-Z]+\ ([^\ ]+) ]]; then
    uri="${BASH_REMATCH[1]}"
fi
query_string="${uri#*\?}"

# Parse server= and status= parameters
server=""
status=""
IFS='&' read -ra params <<< "$query_string"
for param in "${params[@]}"; do
    key="${param%%=*}"
    val="${param#*=}"
    case "$key" in
        server) server="$val" ;;
        status) status="$val" ;;
    esac
done

# Timestamp
now="$(date '+%Y-%m-%d %H:%M:%S')"

# Log the callback
echo "[${now}] server=${server:-unknown} status=${status:-unknown} uri=${uri}" \
    >> "$CALLBACKS_LOG"

# Invoke the on-install-complete hook (if server name is present)
hook_output=""
if [[ -n "$server" && -x "$ON_COMPLETE" ]]; then
    hook_output="$(bash "$ON_COMPLETE" "$PROJECT_DIR" "$server" "${status:-unknown}" 2>&1)" || true
fi

# Build HTTP response
body="Received: server=${server:-unknown}, status=${status:-unknown}"
if [[ -n "$hook_output" ]]; then
    body="${body}\n${hook_output}"
fi
body_length=${#body}

printf "HTTP/1.1 200 OK\r\n"
printf "Content-Type: text/plain\r\n"
printf "Content-Length: %d\r\n" "$body_length"
printf "Connection: close\r\n"
printf "\r\n"
printf "%s" "$body"
HANDLER_EOF

# Replace placeholders with actual paths
sed -i.bak \
    -e "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
    -e "s|__CALLBACKS_LOG__|${CALLBACKS_LOG}|g" \
    -e "s|__ON_COMPLETE__|${ON_COMPLETE}|g" \
    "$HANDLER_SCRIPT"
rm -f "${HANDLER_SCRIPT}.bak"
chmod +x "$HANDLER_SCRIPT"

# ---------------------------------------------------------------------------
# Start socat listener
# ---------------------------------------------------------------------------
log_info "Callback server starting on port ${CALLBACK_PORT}..."
log_info "Handler script: ${HANDLER_SCRIPT}"
log_info "Log file: ${CALLBACKS_LOG}"

# socat forks a child for each connection (fork), allows address reuse
# (reuseaddr), and runs the handler script for each connection (EXEC).
exec socat \
    "TCP-LISTEN:${CALLBACK_PORT},fork,reuseaddr" \
    "EXEC:${HANDLER_SCRIPT}"
