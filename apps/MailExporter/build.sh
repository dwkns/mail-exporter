#!/usr/bin/env bash
# Build a self-contained, signed MailExporter.app (UI + bundled engine).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${ROOT}/../.." && pwd)"
APP="${ROOT}/MailExporter.app"
BIN="${APP}/Contents/MacOS/MailExporter"
SRC="${ROOT}/Sources"
VENV="${REPO}/.venv"
PYI_DIST="${ROOT}/build/engine-dist"
PYI_WORK="${ROOT}/build/engine-work"
HELPER_DIR="${APP}/Contents/Resources"

# Prefer Apple Development identity when available (stable for Full Disk Access)
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development:'; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
  else
    SIGN_IDENTITY="-"
  fi
fi

echo "Signing identity: ${SIGN_IDENTITY}"

RG_VERSION="15.2.0"
VENDOR_RG_DIR="${ROOT}/vendor/rg"
VENDOR_RG="${VENDOR_RG_DIR}/rg"
ensure_bundled_rg() {
  local arch tarball url tmp
  arch="$(uname -m)"
  case "${arch}" in
    arm64|aarch64) tarball="ripgrep-${RG_VERSION}-aarch64-apple-darwin.tar.gz" ;;
    x86_64) tarball="ripgrep-${RG_VERSION}-x86_64-apple-darwin.tar.gz" ;;
    *) echo "Unsupported arch for bundled rg: ${arch}" >&2; exit 1 ;;
  esac
  url="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${tarball}"
  if [[ -x "${VENDOR_RG}" ]]; then
    echo "Using cached ripgrep at ${VENDOR_RG}"
    return
  fi
  echo "Downloading ripgrep ${RG_VERSION} (${arch})…"
  mkdir -p "${VENDOR_RG_DIR}" "${ROOT}/build"
  tmp="${ROOT}/build/${tarball}"
  curl -fsSL -o "${tmp}" "${url}"
  tar -xzf "${tmp}" -C "${ROOT}/build"
  # Archive contains ripgrep-VERSION-TRIPLE/rg
  local extracted
  extracted="$(find "${ROOT}/build" -maxdepth 2 -type f -name rg | head -1)"
  if [[ -z "${extracted}" ]]; then
    echo "Failed to extract rg from ${tarball}" >&2
    exit 1
  fi
  cp "${extracted}" "${VENDOR_RG}"
  chmod +x "${VENDOR_RG}"
  echo "Vendored ripgrep → ${VENDOR_RG}"
}
ensure_bundled_rg

if [[ ! -x "${VENV}/bin/pyinstaller" ]]; then
  echo "Creating venv + PyInstaller…"
  PYTHON_BIN="$(command -v python3 || true)"
  if [[ -z "${PYTHON_BIN}" ]]; then
    echo "python3 is required to build the engine" >&2
    exit 1
  fi
  "${PYTHON_BIN}" -m venv "${VENV}"
  "${VENV}/bin/pip" install -q pyinstaller -r "${REPO}/requirements-dev.txt"
fi

# Determine version and build number
if [[ -n "${APP_VERSION:-}" ]]; then
  VERSION="${APP_VERSION#v}"
else
  LATEST_TAG="$(git -C "${REPO}" describe --tags --abbrev=0 2>/dev/null || echo "v1.1.0")"
  BASE_VERSION="${LATEST_TAG#v}"
  COMMITS_SINCE="$(git -C "${REPO}" rev-list --count "${LATEST_TAG}..HEAD" 2>/dev/null || echo "0")"

  IFS='.' read -r MAJOR MINOR PATCH_BASE <<< "${BASE_VERSION}"
  MAJOR="${MAJOR:-1}"
  MINOR="${MINOR:-1}"
  PATCH_BASE="${PATCH_BASE:-0}"
  PATCH=$(( PATCH_BASE + COMMITS_SINCE ))
  VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

BUILD_NUMBER="$(git -C "${REPO}" rev-list --count HEAD 2>/dev/null || echo "1")"
echo "Building MailExporter v${VERSION} (build ${BUILD_NUMBER})…"

rm -rf "${APP}" "${PYI_DIST}" "${PYI_WORK}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${HELPER_DIR}" "${ROOT}/build"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>MailExporter</string>
  <key>CFBundleDisplayName</key>
  <string>MailExporter</string>
  <key>CFBundleIdentifier</key>
  <string>com.dwkns.MailExporter</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleExecutable</key>
  <string>MailExporter</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>MailExporter opens Mail drafts and replies from Markdown email files.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Markdown Email</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Default</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>txt</string>
      </array>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
        <string>public.text</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>net.daringfireball.markdown</string>
      <key>UTTypeDescription</key>
      <string>Markdown</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.plain-text</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>md</string>
          <string>markdown</string>
        </array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Entitlements: allow bundled PyInstaller helper under same app identity
cat > "${ROOT}/build/MailExporter.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
ENT

echo "Compiling Swift UI…"
swiftc \
  "${SRC}/MailExporterApp.swift" \
  "${SRC}/AppPreferences.swift" \
  "${SRC}/PreferencesView.swift" \
  "${SRC}/AppUpdater.swift" \
  "${SRC}/JobsStore.swift" \
  "${SRC}/EngineBridge.swift" \
  "${SRC}/ComposeBridge.swift" \
  "${SRC}/ComposeInbox.swift" \
  "${SRC}/MailAccessProbe.swift" \
  "${SRC}/PermissionsBanner.swift" \
  "${SRC}/ContentView.swift" \
  "${SRC}/ConfigView.swift" \
  "${SRC}/RunView.swift" \
  "${SRC}/SendView.swift" \
  -o "${BIN}" \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos13 \
  -parse-as-library

echo "Bundling Python engine (PyInstaller onedir — fast startup)…"
"${VENV}/bin/pyinstaller" \
  --noconfirm \
  --clean \
  --onedir \
  --name MailExporterEngine \
  --paths "${REPO}" \
  --distpath "${PYI_DIST}" \
  --workpath "${PYI_WORK}" \
  --specpath "${ROOT}/build" \
  --console \
  --hidden-import mailexporter_mcp \
  --collect-all mcp \
  "${ROOT}/engine_entry.py"

mkdir -p "${HELPER_DIR}"
rm -rf "${HELPER_DIR}/MailExporterEngine"
# Path for EngineBridge: …/Resources/MailExporterEngine/MailExporterEngine
cp -R "${PYI_DIST}/MailExporterEngine" "${HELPER_DIR}/MailExporterEngine"
chmod +x "${HELPER_DIR}/MailExporterEngine/MailExporterEngine"

if [[ -f "${ROOT}/Resources/AppIcon.icns" ]]; then
  cp "${ROOT}/Resources/AppIcon.icns" "${HELPER_DIR}/AppIcon.icns"
fi

if [[ -f "${ROOT}/Resources/_how_to_use.md" ]]; then
  cp "${ROOT}/Resources/_how_to_use.md" "${HELPER_DIR}/_how_to_use.md"
fi

if [[ -f "${ROOT}/Resources/MakeMailDraft.applescript" ]]; then
  cp "${ROOT}/Resources/MakeMailDraft.applescript" "${HELPER_DIR}/MakeMailDraft.applescript"
fi

if [[ -f "${ROOT}/Resources/PutHTMLOnClipboard.js" ]]; then
  cp "${ROOT}/Resources/PutHTMLOnClipboard.js" "${HELPER_DIR}/PutHTMLOnClipboard.js"
fi

mkdir -p "${HELPER_DIR}/bin"
cp "${VENDOR_RG}" "${HELPER_DIR}/bin/rg"
chmod +x "${HELPER_DIR}/bin/rg"

echo "Signing…"
HELPER_ENGINE="${HELPER_DIR}/MailExporterEngine"
ENT="${ROOT}/build/MailExporter.entitlements"

PY_VER="$("${VENV}/bin/python3" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_DIR="python${PY_VER}"

# PyInstaller drops a pythonX.Y dir that codesign mistakes for a broken bundle.
if [[ -d "${HELPER_ENGINE}/_internal/${PY_DIR}" ]]; then
  cat > "${HELPER_ENGINE}/_internal/${PY_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.dwkns.MailExporter.${PY_DIR}-stdlib</string>
  <key>CFBundleName</key>
  <string>${PY_DIR}</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
</dict>
</plist>
PLIST
fi

while IFS= read -r -d '' f; do
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENT}" "$f" || true
done < <(find "${HELPER_ENGINE}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -name 'MailExporterEngine' \) -print0)

if [[ -d "${HELPER_ENGINE}/_internal/${PY_DIR}" ]]; then
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENT}" \
    "${HELPER_ENGINE}/_internal/${PY_DIR}" || true
fi
if [[ -d "${HELPER_ENGINE}/_internal/Python.framework" ]]; then
  if [[ -d "${HELPER_ENGINE}/_internal/Python.framework/Versions/${PY_VER}" ]]; then
    codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENT}" \
      "${HELPER_ENGINE}/_internal/Python.framework/Versions/${PY_VER}" || true
  fi
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENT}" \
    "${HELPER_ENGINE}/_internal/Python.framework" || true
fi
codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENT}" \
  "${HELPER_ENGINE}/MailExporterEngine"
codesign --force --sign "${SIGN_IDENTITY}" \
  "${HELPER_DIR}/bin/rg"
codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENT}" \
  "${BIN}"
codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ENT}" \
  "${APP}"

codesign --verify --verbose=2 "${APP}" 2>&1 | tail -12 || true

echo ""
echo "Built (self-contained): ${APP}"

DEST_APP="/Applications/MailExporter.app"
if [[ -d "/Applications" ]]; then
  echo "Copying to ${DEST_APP}…"
  rm -rf "${DEST_APP}" 2>/dev/null || true
  if ditto "${APP}" "${DEST_APP}" 2>/dev/null; then
    echo "Copied to ${DEST_APP}"
  else
    echo "Note: Could not copy to ${DEST_APP} (permission denied)."
  fi
fi

echo "Grant Full Disk Access only to MailExporter.app, then reopen it."
