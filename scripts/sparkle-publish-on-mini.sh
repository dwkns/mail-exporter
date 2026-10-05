#!/usr/bin/env bash
# Publish a Developer ID + EdDSA-signed Sparkle update.
# Run ONLY on dwkns-mini-m1. Never copy the private key off this Mac.
set -euo pipefail

TAG="${1:?usage: sparkle-publish-on-mini.sh vX.Y.Z}"
[[ "${TAG}" == v* ]] || TAG="v${TAG}"

HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
if [[ "${HOST}" != *mini-m1* && "${HOST}" != *mini* ]]; then
  echo "error: this script must run on dwkns-mini-m1 (host is ${HOST})." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q 'Developer ID Application: Darrell Wilkins'; then
  echo "error: Developer ID Application for Darrell Wilkins is not in this keychain." >&2
  exit 1
fi

REPO="dwkns/mail-exporter"
IDENTITY="Developer ID Application: Darrell Wilkins (LD2427W529)"
SUPPORT="${HOME}/Library/Application Support/MailExporter"
PRIV="${SPARKLE_ED_KEY_FILE:-${SUPPORT}/sparkle-ed25519-private.txt}"
TOOLS="${SUPPORT}/sparkle-tools"
ARCHIVES="${SUPPORT}/sparkle-archives"
ENTITLEMENTS_HELPER=""

if [[ ! -f "${PRIV}" ]]; then
  echo "error: Sparkle EdDSA private key missing at ${PRIV}" >&2
  echo "Generate it on this Mini only (never copy it to a laptop)." >&2
  exit 1
fi

if [[ ! -x "${TOOLS}/bin/generate_appcast" || ! -x "${TOOLS}/bin/sign_update" ]]; then
  echo "error: Sparkle tools missing under ${TOOLS}. Extract Sparkle-2.9.6.tar.xz there." >&2
  exit 1
fi

WORKDIR="$(mktemp -d -t mailexporter-sparkle-XXXXXX)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

echo "Downloading CI helper-only zip for ${TAG}…"
gh release download "${TAG}" -R "${REPO}" -p "MailExporter-macOS-arm64.zip" -D "${WORKDIR}" --clobber

ZIP="${WORKDIR}/MailExporter-macOS-arm64.zip"
[[ -f "${ZIP}" ]] || { echo "error: CI zip not on ${TAG}" >&2; exit 1; }

ditto -x -k "${ZIP}" "${WORKDIR}/extract"
APP="${WORKDIR}/extract/MailExporter.app"
[[ -d "${APP}" ]] || { echo "error: zip did not contain MailExporter.app" >&2; exit 1; }

# Prefer the repo helper-only entitlements if this script is run from a clone.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../apps/MailExporter/MailExporter.entitlements" ]]; then
  ENTITLEMENTS_HELPER="${SCRIPT_DIR}/../apps/MailExporter/MailExporter.entitlements"
fi

sign() {
  local target="$1"
  [[ -e "${target}" ]] || return 0
  if [[ -n "${ENTITLEMENTS_HELPER}" ]]; then
    codesign --force --sign "${IDENTITY}" --options runtime --timestamp \
      --entitlements "${ENTITLEMENTS_HELPER}" "${target}"
  else
    codesign --force --sign "${IDENTITY}" --options runtime --timestamp "${target}"
  fi
}

echo "Re-signing with ${IDENTITY} (helper-only entitlements)…"
HELPER="${APP}/Contents/Resources/MailExporterEngine"
if [[ -d "${HELPER}" ]]; then
  while IFS= read -r -d '' f; do
    sign "$f" || true
  done < <(find "${HELPER}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -name 'MailExporterEngine' \) -print0)
  sign "${HELPER}/MailExporterEngine" || true
fi

FW="${APP}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${FW}" ]]; then
  sign "${FW}/Versions/B/XPCServices/Downloader.xpc"
  sign "${FW}/Versions/B/XPCServices/Installer.xpc"
  sign "${FW}/Versions/B/Updater.app"
  sign "${FW}/Versions/B/Autoupdate"
  sign "${FW}/Versions/B/Sparkle"
  sign "${FW}"
fi

sign "${APP}/Contents/MacOS/MailExporter"
if [[ -n "${ENTITLEMENTS_HELPER}" ]]; then
  codesign --force --sign "${IDENTITY}" --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS_HELPER}" "${APP}"
else
  codesign --force --sign "${IDENTITY}" --options runtime --timestamp "${APP}"
fi

codesign --verify --deep --strict --verbose=2 "${APP}"

PROFILE="${NOTARYTOOL_PROFILE:-MailExporter}"
SUBMIT_ZIP="${WORKDIR}/MailExporter-notarize.zip"
ditto -c -k --keepParent "${APP}" "${SUBMIT_ZIP}"
if xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
  echo "Notarizing with keychain profile ${PROFILE}…"
  xcrun notarytool submit "${SUBMIT_ZIP}" --keychain-profile "${PROFILE}" --wait
  xcrun stapler staple "${APP}"
else
  echo "warning: no notarytool profile '${PROFILE}'." >&2
  echo "On this Mini, once: xcrun notarytool store-credentials ${PROFILE} --apple-id … --team-id LD2427W529" >&2
  echo "Continuing with Developer ID signature only (Gatekeeper may warn)." >&2
fi

SIGNED_ZIP="${WORKDIR}/MailExporter-macOS-arm64-sparkle.zip"
rm -f "${SIGNED_ZIP}"
ditto -c -k --keepParent "${APP}" "${SIGNED_ZIP}"

echo "Signing Sparkle enclosure (EdDSA key file on this Mini; not printed)…"
"${TOOLS}/bin/sign_update" --ed-key-file "${PRIV}" -p "${SIGNED_ZIP}" >/dev/null

mkdir -p "${ARCHIVES}"
rm -f "${ARCHIVES}"/*.zip "${ARCHIVES}/appcast.xml"
cp "${SIGNED_ZIP}" "${ARCHIVES}/MailExporter-macOS-arm64-sparkle.zip"

NOTES="${ARCHIVES}/MailExporter-macOS-arm64-sparkle.md"
gh release view "${TAG}" -R "${REPO}" --json body -q .body > "${NOTES}" || true

"${TOOLS}/bin/generate_appcast" \
  --ed-key-file "${PRIV}" \
  --download-url-prefix "https://github.com/dwkns/mail-exporter/releases/download/${TAG}/" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --embed-release-notes \
  --link "https://github.com/dwkns/mail-exporter/releases/tag/${TAG}" \
  -o "${ARCHIVES}/appcast.xml" \
  "${ARCHIVES}"

[[ -f "${ARCHIVES}/appcast.xml" ]] || { echo "error: generate_appcast did not write appcast.xml" >&2; exit 1; }

echo "Uploading Sparkle zip + appcast.xml to ${TAG} (CI helper-only zip is left in place)…"
gh release upload "${TAG}" \
  "${ARCHIVES}/MailExporter-macOS-arm64-sparkle.zip" \
  "${ARCHIVES}/appcast.xml" \
  --repo "${REPO}" \
  --clobber

echo "Sparkle feed: https://github.com/${REPO}/releases/latest/download/appcast.xml"
echo "Done. Private key stayed on ${HOST}."
