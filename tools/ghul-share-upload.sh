#!/usr/bin/env bash
# GHUL Share Upload - Upload benchmark results to shared.ghul.run
# Handles identity management, signing, and session-based uploads

set -euo pipefail

API_BASE="https://shared.ghul.run"
# HOST_ID_FILE will be set by caller (from BASE directory)
USER_ID_FILE="${HOME}/.ghul_user_id.json"

# ---------- Identity Management ------------------------------------------------

ensure_user_identity() {
  # Ensure user identity file exists with user_id and key pair
  if [[ ! -f "$USER_ID_FILE" ]]; then
    echo "[GHUL] Creating user identity file: $USER_ID_FILE"
    
    # Generate random user_id (6 alphanumeric chars)
    USER_ID="$(openssl rand -hex 3 | head -c 6)"
    
    # Generate Ed25519 key pair for signing
    KEY_DIR="$(mktemp -d)"
    trap "rm -rf '$KEY_DIR'" EXIT
    
    openssl genpkey -algorithm Ed25519 -out "${KEY_DIR}/user_master.pem" 2>/dev/null || {
      # Fallback to RSA if Ed25519 not available
      openssl genrsa -out "${KEY_DIR}/user_master.pem" 2048 2>/dev/null || {
        echo "[GHUL] Error: Cannot generate key pair (openssl required)" >&2
        return 1
      }
    }
    
    # Extract public key
    USER_PUB="$(openssl pkey -in "${KEY_DIR}/user_master.pem" -pubout 2>/dev/null | base64 -w 0 2>/dev/null || base64 2>/dev/null)"
    USER_MASTER="$(cat "${KEY_DIR}/user_master.pem" | base64 -w 0 2>/dev/null || base64 2>/dev/null)"
    
    # Create user identity JSON
    jq -n \
      --arg user_id "$USER_ID" \
      --arg user_pub "$USER_PUB" \
      --arg user_master "$USER_MASTER" \
      '{
        user_id: $user_id,
        user_pub: $user_pub,
        user_master: $user_master
      }' > "$USER_ID_FILE"
    
    chmod 600 "$USER_ID_FILE"
    echo "[GHUL] User identity created: $USER_ID"
  fi
  
  # Read user identity
  if ! command -v jq >/dev/null 2>&1; then
    echo "[GHUL] Error: jq required for share upload" >&2
    return 1
  fi
  
  USER_ID="$(jq -r '.user_id // empty' "$USER_ID_FILE" 2>/dev/null || echo "")"
  USER_PUB="$(jq -r '.user_pub // empty' "$USER_ID_FILE" 2>/dev/null || echo "")"
  USER_MASTER="$(jq -r '.user_master // empty' "$USER_ID_FILE" 2>/dev/null || echo "")"
  
  if [[ -z "$USER_ID" || -z "$USER_PUB" || -z "$USER_MASTER" ]]; then
    echo "[GHUL] Error: Invalid user identity file" >&2
    return 1
  fi
  
  return 0
}

get_host_id() {
  # Read host_id from .ghul_host_id.json (try BASE first, then HOME)
  local host_id_file="${GHUL_BASE:-}/.ghul_host_id.json"
  if [[ ! -f "$host_id_file" ]]; then
    host_id_file="${HOME}/.ghul_host_id.json"
  fi
  
  if [[ ! -f "$host_id_file" ]]; then
    echo "[GHUL] Error: Host ID file not found (checked: ${GHUL_BASE:-}/.ghul_host_id.json and ${HOME}/.ghul_host_id.json)" >&2
    return 1
  fi
  
  if ! command -v jq >/dev/null 2>&1; then
    echo "[GHUL] Error: jq required for share upload" >&2
    return 1
  fi
  
  HOST_ID="$(jq -r '.id // empty' "$host_id_file" 2>/dev/null || echo "")"
  if [[ -z "$HOST_ID" || "$HOST_ID" == "missing" ]]; then
    echo "[GHUL] Error: Host ID not found in $host_id_file" >&2
    return 1
  fi
  
  return 0
}

# ---------- Signing Functions --------------------------------------------------

sign_file() {
  # Sign a file using the user's private key
  local file="$1"
  local sig_file="${file}.sig"
  
  if [[ ! -f "$file" ]]; then
    echo "[GHUL] Error: File not found for signing: $file" >&2
    return 1
  fi
  
  # Decode private key from base64
  local key_file="$(mktemp)"
  local decode_err
  decode_err="$(echo "$USER_MASTER" | base64 -d 2>&1 > "$key_file")"
  if [[ $? -ne 0 ]]; then
    echo "[GHUL] Error: Cannot decode private key: $decode_err" >&2
    rm -f "$key_file"
    return 1
  fi
  
  # Check if key file is valid
  if [[ ! -s "$key_file" ]]; then
    echo "[GHUL] Error: Decoded key file is empty" >&2
    rm -f "$key_file"
    return 1
  fi
  
  # Sign file with private key
  # For Ed25519: use pkeyutl (no explicit digest allowed)
  # For RSA: use dgst -sha256 -sign
  local sign_err
  local key_type
  key_type="$(openssl pkey -in "$key_file" -noout -text 2>/dev/null | head -1 | grep -o 'ED25519\|RSA' || echo "UNKNOWN")"
  
  if [[ "$key_type" == "ED25519" ]]; then
    # Ed25519: use pkeyutl (hashes internally)
    sign_err="$(openssl pkeyutl -sign -inkey "$key_file" -in "$file" -out "$sig_file" 2>&1)"
  else
    # RSA: use dgst with SHA256
    sign_err="$(openssl dgst -sha256 -sign "$key_file" -out "$sig_file" "$file" 2>&1)"
  fi
  
  if [[ $? -ne 0 ]]; then
    echo "[GHUL] Error: Signing failed ($key_type): $sign_err" >&2
    rm -f "$key_file" "$sig_file"
    return 1
  fi
  
  # Check if signature file was created
  if [[ ! -f "$sig_file" || ! -s "$sig_file" ]]; then
    echo "[GHUL] Error: Signature file not created or empty" >&2
    rm -f "$key_file" "$sig_file"
    return 1
  fi
  
  # Encode signature to base64
  local sig_b64
  sig_b64="$(base64 -w 0 "$sig_file" 2>/dev/null || base64 "$sig_file" 2>/dev/null)"
  if [[ -z "$sig_b64" ]]; then
    echo "[GHUL] Error: Failed to encode signature to base64" >&2
    rm -f "$key_file" "$sig_file"
    return 1
  fi
  
  rm -f "$key_file" "$sig_file"
  
  echo "$sig_b64"
}

# ---------- API Functions ------------------------------------------------------

api_handshake() {
  # Create upload session
  local run_stamp="$1"
  local hostname="$2"
  
  # Get hellfire and insane flags from environment (set by ghul-benchmark.sh)
  local hellfire_flag="${GHUL_HELLFIRE:-0}"
  local insane_flag="${GHUL_INSANE:-0}"
  local wimp_flag="${GHUL_WIMP:-0}"
  
  # Determine hellfire_mode: wimp, insane, or default
  local hellfire_mode="default"
  if [[ "$wimp_flag" -eq 1 ]]; then
    hellfire_mode="wimp"
  elif [[ "$insane_flag" -eq 1 ]]; then
    hellfire_mode="insane"
  elif [[ "$hellfire_flag" -eq 1 ]]; then
    hellfire_mode="default"
  fi
  
  local response
  response="$(curl -sS -X POST "${API_BASE}/handshake" \
    -H "Content-Type: application/json" \
    -d "{
      \"user_id\": \"${USER_ID}\",
      \"host_id\": \"${HOST_ID}\",
      \"hostname\": \"${hostname}\",
      \"run_stamp\": \"${run_stamp}\",
      \"share\": true,
      \"hellfire\": ${hellfire_flag},
      \"insane\": ${insane_flag},
      \"hellfire_mode\": \"${hellfire_mode}\",
      \"ghul_version\": \"${GHUL_VERSION:-0.3.2}\"
    }" 2>&1)"
  
  local status
  status="$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")"
  
  # Check for access-denied
  if [[ "$status" == "access-denied" ]]; then
    local reason
    reason="$(echo "$response" | jq -r '.error // "not ready for public participation"' 2>/dev/null || echo "not ready for public participation")"
    echo "[GHUL] Access denied: $reason" >&2
    echo "[GHUL] Uploads are currently restricted. Exit" >&2
    return 2  # Special exit code for access-denied
  fi
  
  local session_id
  session_id="$(echo "$response" | jq -r '.session_id // empty' 2>/dev/null || echo "")"
  
  if [[ -z "$session_id" ]]; then
    echo "[GHUL] Error: Handshake failed" >&2
    echo "$response" | jq . >&2 || echo "$response" >&2
    return 1
  fi
  
  echo "$session_id"
}

api_step() {
  # Advance session to next step
  local session_id="$1"
  local step="$2"
  local timestamp="$3"
  
  local response
  response="$(curl -sS -X POST "${API_BASE}/step" \
    -H "Content-Type: application/json" \
    -d "{
      \"session_id\": \"${session_id}\",
      \"step\": \"${step}\",
      \"timestamp\": ${timestamp}
    }" 2>&1)"
  
  local status
  status="$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")"
  
  if [[ "$status" != "ok" ]]; then
    echo "[GHUL] Error: Step failed" >&2
    echo "$response" | jq . >&2 || echo "$response" >&2
    return 1
  fi
  
  return 0
}

api_upload() {
  # Upload file with signature
  local session_id="$1"
  local file="$2"
  
  if [[ ! -f "$file" ]]; then
    echo "[GHUL] Error: File not found: $file" >&2
    return 1
  fi
  
  # Sign file
  local signature
  signature="$(sign_file "$file")" || return 1
  
  # Upload file with signature in metadata
  local response
  response="$(curl -sS -X POST "${API_BASE}/upload" \
    -F "session_id=${session_id}" \
    -F "file=@${file}" \
    -F "signature=${signature}" \
    -F "user_id=${USER_ID}" \
    -F "user_pub=${USER_PUB}" \
    2>&1)"
  
  local status
  status="$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")"
  
  if [[ "$status" != "ok" ]]; then
    echo "[GHUL] Error: Upload failed" >&2
    echo "$response" | jq . >&2 || echo "$response" >&2
    return 1
  fi
  
  local stored_as
  stored_as="$(echo "$response" | jq -r '.stored_as // empty' 2>/dev/null || echo "")"
  echo "[GHUL] Uploaded: $stored_as"
  
  return 0
}

api_finalize() {
  # Finalize session (mark as completed)
  local session_id="$1"
  
  local response
  response="$(curl -sS -X POST "${API_BASE}/finalize" \
    -H "Content-Type: application/json" \
    -d "{
      \"session_id\": \"${session_id}\"
    }" 2>&1)"
  
  local status
  status="$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")"
  
  if [[ "$status" != "ok" ]]; then
    echo "[GHUL] Error: Finalize failed" >&2
    echo "$response" | jq . >&2 || echo "$response" >&2
    return 1
  fi
  
  echo "[GHUL] Session finalized"
  
  return 0
}

# ---------- Step Notification Function -----------------------------------------

ghul_notify_step() {
  # Notify server that a phase completed (called from ghul-benchmark.sh during run)
  local step="$1"
  local timestamp="${2:-$(date +%s)}"
  
  if [[ -z "${GHUL_SESSION_ID:-}" ]]; then
    return 0  # No active session, skip silently
  fi
  
  if ! command -v curl >/dev/null 2>&1; then
    return 0  # Skip if curl not available
  fi
  
  local response
  response="$(curl -sS -X POST "${API_BASE}/step" \
    -H "Content-Type: application/json" \
    -d "{
      \"session_id\": \"${GHUL_SESSION_ID}\",
      \"step\": \"${step}\",
      \"timestamp\": ${timestamp}
    }" 2>&1)"
  
  local status
  status="$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")"
  
  if [[ "$status" == "ok" ]]; then
    local next_step
    next_step="$(echo "$response" | jq -r '.next_step // empty' 2>/dev/null || echo "")"
    echo "[GHUL] ${step^} run finished. Timestamp sent..."
    echo "[API] Timestamp accepted (next: ${next_step})"
  else
    local error
    error="$(echo "$response" | jq -r '.error // "unknown"' 2>/dev/null || echo "unknown")"
    if [[ "$error" == "timestamp_not_monotonic" ]]; then
      echo "[GHUL] ${step^} run finished. Timestamp sent..."
      echo "[API] ⚠️  Timestamp suspicious (not monotonic)"
    else
      echo "[GHUL] ${step^} run finished. Timestamp sent..."
      echo "[API] ⚠️  Error: $error"
    fi
  fi
  
  return 0
}

# ---------- Session Initialization ---------------------------------------------

ghul_init_share_session() {
  # Initialize upload session (called at start of benchmark)
  local run_stamp="$1"
  local hostname="$2"
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "[GHUL] Share upload requested"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Check prerequisites
  if ! command -v curl >/dev/null 2>&1; then
    echo "[GHUL] Warning: curl not available, share upload disabled" >&2
    return 1
  fi
  
  if ! command -v openssl >/dev/null 2>&1; then
    echo "[GHUL] Warning: openssl not available, share upload disabled" >&2
    return 1
  fi
  
  # Ensure identity files exist
  ensure_user_identity || return 1
  get_host_id || return 1
  
  echo "[GHUL] User ID: ${USER_ID}"
  echo "[GHUL] Host ID: ${HOST_ID}"
  echo ""
  
  # Create session
  echo "[GHUL] Creating upload session..."
  local session_id
  session_id="$(api_handshake "$run_stamp" "$hostname")"
  local handshake_result=$?
  
  if [[ $handshake_result -eq 2 ]]; then
    # Access denied - abort benchmark
    echo "[GHUL] Uploads are currently restricted. Exit" >&2
    return 2  # Special exit code for access-denied
  elif [[ $handshake_result -ne 0 ]]; then
    return 1
  fi
  
  echo "[GHUL] Session created: $session_id"
  echo ""
  
  # Export session ID for step notifications
  export GHUL_SESSION_ID="$session_id"
  export GHUL_USER_ID="$USER_ID"
  export GHUL_HOST_ID="$HOST_ID"
  export GHUL_USER_PUB="$USER_PUB"
  export GHUL_USER_MASTER="$USER_MASTER"
  
  return 0
}

# ---------- Main Upload Function -----------------------------------------------

ghul_upload_results() {
  # Main function called from ghul-benchmark.sh at the end
  # Session should already be initialized and steps already sent
  local benchmark_file="$1"
  local sensors_file="$2"
  
  if [[ -z "${GHUL_SESSION_ID:-}" ]]; then
    echo "[GHUL] Warning: No active session, skipping upload" >&2
    return 1
  fi
  
  echo ""
  echo "[GHUL] Uploading results..."
  echo ""
  
  # Upload benchmark JSON
  if [[ -f "$benchmark_file" ]]; then
    echo "[GHUL] Uploading benchmark results..."
    api_upload "${GHUL_SESSION_ID}" "$benchmark_file" || return 1
    echo ""
  fi
  
  # Upload sensors JSONL
  if [[ -f "$sensors_file" ]]; then
    echo "[GHUL] Uploading sensor data..."
    api_upload "${GHUL_SESSION_ID}" "$sensors_file" || return 1
    echo ""
  fi
  
  # Note: Session will be finalized after Hellfire uploads (if any)
  # If no Hellfire tests are planned, finalize will be called separately
  
  echo "[GHUL] Benchmark upload complete!"
  echo ""
  
  return 0
}

ghul_upload_hellfire_file() {
  # Upload a single Hellfire file (sensor log)
  local file="$1"
  
  if [[ -z "${GHUL_SESSION_ID:-}" ]]; then
    echo "[GHUL] Warning: No active session, skipping upload" >&2
    return 1
  fi
  
  if [[ ! -f "$file" ]]; then
    echo "[GHUL] Warning: File not found: $file" >&2
    return 1
  fi
  
  api_upload "${GHUL_SESSION_ID}" "$file" || return 1
  
  return 0
}

