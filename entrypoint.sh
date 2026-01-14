#!/bin/bash
set -euo pipefail

# Hytale entrypoint: if server files already exist, start immediately.
# Otherwise, download using provided credentials, set up, and start.

SERVER_DIR="/server"
JAR_PATH="${SERVER_DIR}/HytaleServer.jar"
ASSETS_PATH="${SERVER_DIR}/Assets.zip"
DOWNLOADER_BIN="/app/hytale-downloader"

ensure_server_started() {
  cd "${SERVER_DIR}"
  echo "Starting Hytale Server..."
  # Use exec to hand over the PID to Java for proper signal handling and console access
  exec java -jar "${JAR_PATH}" --assets "${ASSETS_PATH}"
}

# 1) If server files already exist, skip everything and run
if [[ -f "${JAR_PATH}" && -f "${ASSETS_PATH}" ]]; then
  echo "Server files found. Skipping setup."
  ensure_server_started
fi

echo "Server files not found. Beginning setup..."

# 2) Validate prerequisites
if [[ -z "${CREDENTIALS_FILE:-}" ]]; then
  echo "Error: CREDENTIALS_FILE environment variable is not set."
  exit 1
fi

CRED_SOURCE="${SERVER_DIR}/${CREDENTIALS_FILE}"
if [[ ! -f "${CRED_SOURCE}" ]]; then
  echo "Error: Credentials file not found at ${CRED_SOURCE}"
  exit 1
fi

if [[ ! -x "${DOWNLOADER_BIN}" ]]; then
  echo "Error: Downloader binary not found or not executable at ${DOWNLOADER_BIN}"
  exit 1
fi

# 3) Use a writable temp copy of credentials (read-only mounts can fail for session writes)
TMP_CRED="/tmp/hytale_credentials.json"
cp "${CRED_SOURCE}" "${TMP_CRED}"
chmod 600 "${TMP_CRED}"

echo "Downloading Hytale server files..."
"${DOWNLOADER_BIN}" -credentials-path "${TMP_CRED}"

# 4) Find the newest zip produced by the downloader under /server
DOWNLOADED_ZIP="$(ls -t "${SERVER_DIR}"/*.zip 2>/dev/null | head -n 1 || true)"

if [[ -z "${DOWNLOADED_ZIP}" ]]; then
  echo "Error: No zip file found after download."
  exit 1
fi

# Validate zip before extraction
if ! unzip -tq "${DOWNLOADED_ZIP}" >/dev/null 2>&1; then
  echo "Error: Downloaded zip appears invalid or corrupted: ${DOWNLOADED_ZIP}"
  exit 1
fi

echo "Extracting ${DOWNLOADED_ZIP}..."
EXTRACT_DIR="/tmp/hytale_extract"
mkdir -p "${EXTRACT_DIR}"
unzip -o "${DOWNLOADED_ZIP}" -d "${EXTRACT_DIR}"

# 5) Copy required artifacts to /server
echo "Locating HytaleServer.jar..."
if [[ -f "${EXTRACT_DIR}/server/HytaleServer.jar" ]]; then
  cp "${EXTRACT_DIR}/server/HytaleServer.jar" "${JAR_PATH}"
elif [[ -f "${EXTRACT_DIR}/HytaleServer.jar" ]]; then
  cp "${EXTRACT_DIR}/HytaleServer.jar" "${JAR_PATH}"
else
  JAR_FOUND="$(find "${EXTRACT_DIR}" -type f -name 'HytaleServer.jar' | head -n 1 || true)"
  if [[ -n "${JAR_FOUND}" ]]; then
    cp "${JAR_FOUND}" "${JAR_PATH}"
  else
    echo "Error: HytaleServer.jar not found in extracted contents."
    exit 1
  fi
fi

echo "Locating Assets.zip..."
if [[ -f "${EXTRACT_DIR}/Assets.zip" ]]; then
  cp "${EXTRACT_DIR}/Assets.zip" "${ASSETS_PATH}"
else
  ASSETS_FOUND="$(find "${EXTRACT_DIR}" -type f -name 'Assets.zip' | head -n 1 || true)"
  if [[ -n "${ASSETS_FOUND}" ]]; then
    cp "${ASSETS_FOUND}" "${ASSETS_PATH}"
  else
    echo "Error: Assets.zip not found in extracted contents."
    exit 1
  fi
fi

# 6) Cleanup temporary files
echo "Cleaning up temporary files..."
rm -rf "${EXTRACT_DIR}"
rm -f "${TMP_CRED}"

# Optionally remove the downloaded zip to keep the volume clean
# Comment out the next line if you'd like to retain the original zip.
rm -f "${DOWNLOADED_ZIP}"

# 7) Start the server
ensure_server_started
