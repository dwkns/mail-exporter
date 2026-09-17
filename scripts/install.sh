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

OS="$(uname -s)"
if [[ "${OS}" != "Darwin" ]]; then
  echo "Error: MailExporter only runs on macOS." >&2
  exit 1
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "arm64" ]]; then
  echo "Note: MailExporter is optimized for Apple Silicon (arm64). Current machine: ${ARCH}."
fi

if [[ ! -w "${DEST_DIR}" ]]; then
  echo "Notice: ${DEST_DIR} is not writable directly. Using ~/Applications instead."
  DEST_DIR="${HOME}/Applications"
  mkdir -p "${DEST_DIR}"
fi

TMP_DIR="$(mktemp -d -t mailexporter-install-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ZIP_PATH="${TMP_DIR}/MailExporter-macOS-arm64.zip"
SUM_PATH="${TMP_DIR}/MailExporter-macOS-arm64.zip.sha256"
DOWNLOADED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
LOCAL_APP="${SCRIPT_DIR}/../apps/MailExporter/MailExporter.app"
if [[ -d "${LOCAL_APP}" ]]; then
  echo "Found local build at ${LOCAL_APP}. Copying…"
  rm -rf "${DEST_DIR}/${APP_NAME}"
  cp -R "${LOCAL_APP}" "${DEST_DIR}/${APP_NAME}"
  DOWNLOADED=2
fi

AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: token ${GITHUB_TOKEN}")
elif [[ -n "${GH_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: token ${GH_TOKEN}")
fi

download_release_zip() {
  local zip_url="" sum_url=""
  if command -v gh >/dev/null 2>&1; then
    echo "Checking for latest release via GitHub CLI…"
    if gh release download --repo "${REPO}" --pattern "MailExporter-*.zip*" --dir "${TMP_DIR}" 2>/dev/null; then
      FOUND_ZIP="$(find "${TMP_DIR}" -name "MailExporter-*.zip" ! -name "*.sha256" | head -1)"
      FOUND_SUM="$(find "${TMP_DIR}" -name "MailExporter-*.sha256" | head -1)"
      if [[ -n "${FOUND_ZIP}" ]]; then
        ZIP_PATH="${FOUND_ZIP}"
        if [[ -n "${FOUND_SUM}" ]]; then
          SUM_PATH="${FOUND_SUM}"
        fi
        DOWNLOADED=1
        return 0
      fi
    fi
  fi

  echo "Fetching latest release from GitHub (${REPO})…"
  API_URL="https://api.github.com/repos/${REPO}/releases/latest"
  local json
  json="$(curl -fsSL "${AUTH_HEADER[@]}" "${API_URL}" 2>/dev/null || true)"
  zip_url="$(printf '%s' "${json}" | grep -o 'https://[^"]*MailExporter-[^"]*\.zip' | grep -v sha256 | head -1 || true)"
  sum_url="$(printf '%s' "${json}" | grep -o 'https://[^"]*MailExporter-[^"]*\.sha256' | head -1 || true)"
  if [[ -n "${zip_url}" ]]; then
    echo "Downloading ${zip_url}…"
    curl -fsSL "${AUTH_HEADER[@]}" -o "${ZIP_PATH}" "${zip_url}"
    if [[ -n "${sum_url}" ]]; then
      curl -fsSL "${AUTH_HEADER[@]}" -o "${SUM_PATH}" "${sum_url}" || true
    fi
    DOWNLOADED=1
  fi
}

if [[ "${DOWNLOADED}" -eq 0 ]]; then
  download_release_zip
fi

if [[ "${DOWNLOADED}" -eq 0 ]]; then
  echo "No pre-built release package found on GitHub."
  echo "If you have cloned the repository, you can build from source by running:"
  echo "  ./apps/MailExporter/build.sh"
  exit 1
fi

if [[ "${DOWNLOADED}" -eq 1 && -f "${ZIP_PATH}" ]]; then
  if [[ -f "${SUM_PATH}" ]]; then
    echo "Verifying SHA-256…"
    expected="$(awk '{print $1}' "${SUM_PATH}" | head -1)"
    actual="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
    if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
      echo "Checksum mismatch. Refusing to install." >&2
      echo "expected: ${expected}" >&2
      echo "actual:   ${actual}" >&2
      exit 1
    fi
  else
    echo "Warning: no .sha256 file next to the zip; continuing without a checksum." >&2
  fi
  echo "Extracting ${APP_NAME} to ${DEST_DIR}…"
  rm -rf "${DEST_DIR}/${APP_NAME}"
  unzip -q -o "${ZIP_PATH}" -d "${DEST_DIR}"
fi

echo "Verifying code signature…"
if ! codesign --verify --deep --strict "${DEST_DIR}/${APP_NAME}" 2>/dev/null; then
  echo "Warning: codesign --verify failed. The zip may be ad-hoc signed." >&2
  codesign --verify --verbose=2 "${DEST_DIR}/${APP_NAME}" 2>&1 | tail -8 || true
fi

echo "iCloud: jobs.json syncs via the app ubiquity container when iCloud is enabled."

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
