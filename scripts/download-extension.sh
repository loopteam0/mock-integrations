#!/usr/bin/env bash
set -euo pipefail

DEST_DIR="${1:-./wiremock/extensions}"
EXT_VERSION="${WIREMOCK_STATE_EXTENSION_VERSION:-0.8.0}"
JAR_NAME="wiremock-state-extension-standalone-${EXT_VERSION}.jar"
MAVEN_URL="https://repo1.maven.org/maven2/org/wiremock/extensions/wiremock-state-extension-standalone/${EXT_VERSION}/${JAR_NAME}"
GITHUB_FALLBACK_URL="https://github.com/wiremock/wiremock-state-extension/releases/download/${EXT_VERSION}/${JAR_NAME}"

mkdir -p "${DEST_DIR}"

if [ -f "${DEST_DIR}/${JAR_NAME}" ] && [ -s "${DEST_DIR}/${JAR_NAME}" ]; then
  echo "[INFO] ${JAR_NAME} already exists in ${DEST_DIR}. Skipping download."
  exit 0
fi

echo "[INFO] Downloading ${JAR_NAME} from Maven Central (${MAVEN_URL})..."
if ! curl -fSL --retry 3 --retry-delay 2 -o "${DEST_DIR}/${JAR_NAME}" "${MAVEN_URL}"; then
  echo "[WARN] Maven Central download failed. Attempting GitHub Release fallback (${GITHUB_FALLBACK_URL})..."
  curl -fSL --retry 3 --retry-delay 2 -o "${DEST_DIR}/${JAR_NAME}" "${GITHUB_FALLBACK_URL}"
fi

if [ ! -s "${DEST_DIR}/${JAR_NAME}" ]; then
  echo "[ERROR] Downloaded file ${DEST_DIR}/${JAR_NAME} is empty or missing!" >&2
  exit 1
fi

echo "[INFO] Successfully downloaded ${JAR_NAME} to ${DEST_DIR}/${JAR_NAME}"
