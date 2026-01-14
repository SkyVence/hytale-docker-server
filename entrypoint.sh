#!/usr/bin/env bash
set -euo pipefail

# Hytale entrypoint
# - If server files already exist: optionally check for update (via CHECK_FOR_UPDATE).
#   If update found -> extract & replace artifacts and start the server.
# - If server files do not exist: run initial setup (download, extract, start).
#
# Environment variables:
# - SERVER_DIR (default: /server)
# - DOWNLOADER_BIN (default: /app/hytale-downloader)
# - CREDENTIALS_FILE (either absolute path or path relative to SERVER_DIR)
# - CHECK_FOR_UPDATE (set to "true"/"1"/"yes" to enable update checks)
# - KEEP_ZIP (set to "true" to keep downloaded zip files)
#
# Designed for maintainability: small functions, single place for config.

SERVER_DIR="${SERVER_DIR:-/server}"
JAR_NAME="HytaleServer.jar"
ASSETS_NAME="Assets.zip"
JAR_PATH="${SERVER_DIR}/${JAR_NAME}"
ASSETS_PATH="${SERVER_DIR}/${ASSETS_NAME}"

DOWNLOADER_BIN="${DOWNLOADER_BIN:-/app/hytale-downloader}"
TMP_CRED="/tmp/hytale_credentials.json"
EXTRACT_DIR="${EXTRACT_DIR:-/tmp/hytale_extract}"
KEEP_ZIP="${KEEP_ZIP:-false}"
CHECK_FOR_UPDATE="${CHECK_FOR_UPDATE:-false}"

# Logging helpers
log() { printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
info()  { log "[INFO] $*"; }
warn()  { log "[WARN] $*"; }
error() { log "[ERROR] $*"; }
die()   { error "$*"; exit 1; }

# Utility: check if a string value is truthy
is_truthy() {
  local v="${1:-}"
  case "${v,,}" in
    1|true|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

# Ensure the server is started (exec to hand PID to java)
ensure_server_started() {
  cd "${SERVER_DIR}"
  info "Starting Hytale Server..."
  exec java -jar "${JAR_PATH}" --assets "${ASSETS_PATH}"
}

# Find the newest zip in SERVER_DIR (by mtime)
find_latest_zip() {
  ls -t "${SERVER_DIR}"/*.zip 2>/dev/null | head -n1 || true
}

# Validate a zip file
verify_zip() {
  local z="$1"
  if ! unzip -tq "$z" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Extract a zip to EXTRACT_DIR (clears extract dir first)
extract_zip() {
  local z="$1"
  rm -rf "${EXTRACT_DIR}"
  mkdir -p "${EXTRACT_DIR}"
  unzip -o "$z" -d "${EXTRACT_DIR}"
}

# Copy artifacts from extract dir to server dir, using temp files & atomic move
copy_artifacts() {
  mkdir -p "${SERVER_DIR}"

  # Locate JAR
  local jar_found
  if [[ -f "${EXTRACT_DIR}/server/${JAR_NAME}" ]]; then
    jar_found="${EXTRACT_DIR}/server/${JAR_NAME}"
  elif [[ -f "${EXTRACT_DIR}/${JAR_NAME}" ]]; then
    jar_found="${EXTRACT_DIR}/${JAR_NAME}"
  else
    jar_found="$(find "${EXTRACT_DIR}" -type f -name "${JAR_NAME}" | head -n1 || true)"
  fi

  if [[ -z "${jar_found}" ]]; then
    die "HytaleServer.jar not found in extracted contents."
  fi

  local tmp_jar="${JAR_PATH}.tmp.$$"
  cp -f "${jar_found}" "${tmp_jar}"
  mv -f "${tmp_jar}" "${JAR_PATH}"
  info "Installed ${JAR_NAME} -> ${JAR_PATH}"

  # Locate Assets.zip
  local assets_found
  if [[ -f "${EXTRACT_DIR}/${ASSETS_NAME}" ]]; then
    assets_found="${EXTRACT_DIR}/${ASSETS_NAME}"
  else
    assets_found="$(find "${EXTRACT_DIR}" -type f -name "${ASSETS_NAME}" | head -n1 || true)"
  fi

  if [[ -z "${assets_found}" ]]; then
    die "Assets.zip not found in extracted contents."
  fi

  local tmp_assets="${ASSETS_PATH}.tmp.$$"
  cp -f "${assets_found}" "${tmp_assets}"
  mv -f "${tmp_assets}" "${ASSETS_PATH}"
  info "Installed ${ASSETS_NAME} -> ${ASSETS_PATH}"
}

# Cleanup temp files (extract dir, tmp credentials)
cleanup() {
  rm -rf "${EXTRACT_DIR}" || true
  rm -f "${TMP_CRED}" || true
}
trap cleanup EXIT

# Helper to resolve credentials source path (absolute or relative to SERVER_DIR)
resolve_credentials_source() {
  if [[ -z "${CREDENTIALS_FILE:-}" ]]; then
    echo ""
    return
  fi
  if [[ "${CREDENTIALS_FILE}" = /* ]]; then
    echo "${CREDENTIALS_FILE}"
  else
    echo "${SERVER_DIR}/${CREDENTIALS_FILE}"
  fi
}

# Prepare temporary credentials file for downloader
prepare_tmp_credentials() {
  local src
  src="$(resolve_credentials_source)"
  if [[ -z "${src}" ]]; then
    die "CREDENTIALS_FILE environment variable is not set."
  fi
  if [[ ! -f "${src}" ]]; then
    die "Credentials file not found at ${src}"
  fi
  cp "${src}" "${TMP_CRED}"
  chmod 600 "${TMP_CRED}"
  info "Temporary credentials prepared."
}

# Process a zip: verify, extract, copy artifacts, optionally remove zip
process_zip() {
  local zip="$1"
  if [[ -z "${zip}" ]]; then
    die "No zip specified for processing."
  fi
  info "Verifying ${zip}..."
  if ! verify_zip "${zip}"; then
    die "Downloaded zip appears invalid or corrupted: ${zip}"
  fi

  info "Extracting ${zip}..."
  extract_zip "${zip}"

  info "Copying artifacts..."
  copy_artifacts

  # Optionally remove the zip to keep the volume clean
  if ! is_truthy "${KEEP_ZIP}"; then
    info "Removing ${zip} (KEEP_ZIP != true)"
    rm -f "${zip}" || true
  else
    info "Keeping ${zip} (KEEP_ZIP == true)"
  fi

  # Clear extract dir (trap will also attempt this)
  rm -rf "${EXTRACT_DIR}" || true
}

# Validate downloader binary
validate_downloader() {
  if [[ ! -x "${DOWNLOADER_BIN}" ]]; then
    die "Downloader binary not found or not executable at ${DOWNLOADER_BIN}"
  fi
}

# Run downloader check-update, return 0 if a new zip appeared
run_check_update() {
  validate_downloader
  local prev
  prev="$(find_latest_zip || true)"
  info "Running check-update..."
  if "${DOWNLOADER_BIN}" -check-update; then
    info "check-update executed."
  else
    warn "check-update failed without credentials; trying with credentials if available."
    # If check-update fails without credentials and we have credentials, try again with them
    if [[ -n "${CREDENTIALS_FILE:-}" ]]; then
      prepare_tmp_credentials
      if "${DOWNLOADER_BIN}" -check-update -credentials-path "${TMP_CRED}"; then
        info "check-update executed with credentials."
      else
        warn "check-update still failed even with credentials."
      fi
    fi
  fi

  local post
  post="$(find_latest_zip || true)"

  if [[ -n "${post}" && "${post}" != "${prev}" ]]; then
    info "New zip detected: ${post}"
    # return zip path via stdout for convenience
    echo "${post}"
    return 0
  fi

  info "No new zip detected."
  return 1
}

# Initial setup (download using credentials and process latest zip)
initial_setup() {
  info "Beginning initial setup..."
  validate_downloader
  prepare_tmp_credentials

  info "Downloading Hytale server files..."
  "${DOWNLOADER_BIN}" -credentials-path "${TMP_CRED}"

  local downloaded
  downloaded="$(find_latest_zip || true)"
  if [[ -z "${downloaded}" ]]; then
    die "Error: No zip file found after download."
  fi

  process_zip "${downloaded}"
  rm -f "${TMP_CRED}" || true
}

# Script main flow

# 1) If server files exist, possibly check for updates, otherwise start
if [[ -f "${JAR_PATH}" && -f "${ASSETS_PATH}" ]]; then
  info "Server files found. ${JAR_NAME} and ${ASSETS_NAME} are present."
  if is_truthy "${CHECK_FOR_UPDATE}"; then
    info "CHECK_FOR_UPDATE set; attempting update check."
    # If check-update yields a new zip, process it; then start server
    if new_zip="$(run_check_update)"; then
      info "Processing update from ${new_zip}..."
      process_zip "${new_zip}"
      info "Update processed; starting server."
      ensure_server_started
    else
      info "No update; starting existing server."
      ensure_server_started
    fi
  else
    info "CHECK_FOR_UPDATE is false/empty; starting existing server."
    ensure_server_started
  fi
fi

# 2) Server files do not exist -> initial setup
info "Server files not found. Performing initial setup."
initial_setup

info "Setup complete; starting server."
ensure_server_started
