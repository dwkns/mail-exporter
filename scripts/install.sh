#!/usr/bin/env bash
# MailExporter installer for macOS
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dwkns/mail-exporter/main/scripts/install.sh | bash
#   or from a clone: ./scripts/install.sh
set -euo pipefail

REPO="dwkns/mail-exporter"
APP_NAME="MailExporter.app"
DEST_DIR="/Applications"

echo "=== MailExporter Installer ==="

# 1. OS Check
OS="$(uname -s)"
if [[ "${OS}" != "Darwin" ]]; then
  echo "Error: MailExporter only runs on macOS." >&2
  exit 1
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "arm64" ]]; then
  echo "Note: MailExporter is optimized for Apple Silicon (arm64). Current machine: ${ARCH}."
fi

# 2. Check destination permissions
if [[ ! -w "${DEST_DIR}" ]]; then
  echo "Notice: ${DEST_DIR} is not writable directly. Using ~/Applications instead."
  DEST_DIR="${HOME}/Applications"
  mkdir -p "${DEST_DIR}"
fi

TMP_DIR="$(mktemp -d -t mailexporter-install-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ZIP_PATH="${TMP_DIR}/MailExporter-macOS-arm64.zip"

# 3. Obtain the application bundle
DOWNLOADED=0

# Option A: Check if running inside local repo with prebuilt app
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
LOCAL_APP="${SCRIPT_DIR}/../apps/MailExporter/MailExporter.app"
if [[ -d "${LOCAL_APP}" ]]; then
  echo "Found local build at ${LOCAL_APP}. Copying…"
  rm -rf "${DEST_DIR}/${APP_NAME}"
  cp -R "${LOCAL_APP}" "${DEST_DIR}/${APP_NAME}"
  DOWNLOADED=1
fi

# Option B: Use GitHub CLI (gh) if authenticated
if [[ "${DOWNLOADED}" -eq 0 ]] && command -v gh >/dev/null 2>&1; then
  echo "Checking for latest release via GitHub CLI…"
  if gh release download --repo "${REPO}" --pattern "MailExporter-*.zip" --dir "${TMP_DIR}" 2>/dev/null; then
    FOUND_ZIP="$(find "${TMP_DIR}" -name "MailExporter-*.zip" | head -1)"
    if [[ -n "${FOUND_ZIP}" ]]; then
      ZIP_PATH="${FOUND_ZIP}"
      DOWNLOADED=1
    fi
  fi
fi

# Option C: Direct download via GitHub API
if [[ "${DOWNLOADED}" -eq 0 ]]; then
  echo "Fetching latest release from GitHub (${REPO})…"
  AUTH_HEADER=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: token ${GITHUB_TOKEN}")
  elif [[ -n "${GH_TOKEN:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: token ${GH_TOKEN}")
  fi

  API_URL="https://api.github.com/repos/${REPO}/releases/latest"
  ASSET_URL="$(curl -fsSL "${AUTH_HEADER[@]}" "${API_URL}" 2>/dev/null | grep -o 'https://[^"]*MailExporter-[^"]*\.zip' | head -1 || true)"

  if [[ -n "${ASSET_URL}" ]]; then
    echo "Downloading ${ASSET_URL}…"
    curl -fsSL "${AUTH_HEADER[@]}" -o "${ZIP_PATH}" "${ASSET_URL}"
    DOWNLOADED=1
  fi
fi

if [[ "${DOWNLOADED}" -eq 0 ]]; then
  echo "No pre-built release package found on GitHub."
  echo "If you have cloned the repository, you can build from source by running:"
  echo "  ./apps/MailExporter/build.sh"
  exit 1
fi

if [[ -f "${ZIP_PATH}" ]]; then
  echo "Extracting ${APP_NAME} to ${DEST_DIR}…"
  rm -rf "${DEST_DIR}/${APP_NAME}"
  unzip -q -o "${ZIP_PATH}" -d "${DEST_DIR}"
fi

# 4. Remove Gatekeeper quarantine
echo "Configuring permissions (clearing Gatekeeper quarantine)…"
xattr -cr "${DEST_DIR}/${APP_NAME}" 2>/dev/null || true

# 5. Ensure iCloud storage directory exists
ICLOUD_DOCS="${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
if [[ -d "${ICLOUD_DOCS}" ]]; then
  mkdir -p "${ICLOUD_DOCS}/MailExporter"
  echo "iCloud storage directory prepared at: ${ICLOUD_DOCS}/MailExporter"
fi

echo ""
echo "========================================================"
echo "✓ MailExporter installed successfully to:"
echo "  ${DEST_DIR}/${APP_NAME}"
echo "========================================================"
echo ""
echo "REQUIRED FIRST-TIME SETUP (System Settings):"
echo "1. Full Disk Access:"
echo "   Open System Settings → Privacy & Security → Full Disk Access"
echo "   Enable MailExporter (so it can read ~/Library/Mail)"
echo ""
echo "2. Accessibility:"
echo "   Open System Settings → Privacy & Security → Accessibility"
echo "   Enable MailExporter (for rich Markdown draft formatting)"
echo ""
echo "Launch MailExporter anytime with:"
echo "  open ${DEST_DIR}/${APP_NAME}"
echo ""
