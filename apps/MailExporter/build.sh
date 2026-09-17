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

# Determine version and build number.
# Latest tag + commits since that tag. Uncommitted work on a tagged HEAD does
# not increment (commits-since is 0), so a ship must pass APP_VERSION matching
# the tag being created — see .cursor/rules/ship-mailexporter.mdc.
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

BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "${REPO}" rev-list --count HEAD 2>/dev/null || echo "1")}"
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
  <key>NSUbiquitousContainers</key>
  <dict>
    <key>iCloud.com.dwkns.MailExporter</key>
    <dict>
      <key>NSUbiquitousContainerIsDocumentScopePublic</key>
      <false/>
      <key>NSUbiquitousContainerName</key>
      <string>MailExporter</string>
      <key>NSUbiquitousContainerSupportedFolderLevels</key>
      <string>None</string>
    </dict>
  </dict>
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
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.dwkns.MailExporter</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>mailexporter</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Entitlements: always allow the bundled PyInstaller helper.
# Restricted iCloud keys need an App ID + Mac provisioning profile. Attaching
# them without a profile makes launchd reject the app ("can't be opened", 163)
# even when signed with Apple Development. Never attach iCloud on ad-hoc
# (SIGN_IDENTITY=-) or CI without a profile.
# Sign from a generated copy under build/ (gitignored). Never write back onto
# the tracked helper-only MailExporter.entitlements.
HELPER_ENT="${ROOT}/MailExporter.entitlements"
ENT_FILE="${ROOT}/build/MailExporter.entitlements"
APP_ENT="${ROOT}/build/MailExporter-app.entitlements"
PROVISION_EMBED=""

find_mac_provision_profile() {
  if [[ -n "${PROVISION_PROFILE:-}" && -f "${PROVISION_PROFILE}" ]]; then
    printf '%s\n' "${PROVISION_PROFILE}"
    return 0
  fi
  local f
  for f in \
    "${ROOT}/embedded.provisionprofile" \
    "${ROOT}/MailExporter.provisionprofile"
  do
    if [[ -f "${f}" ]]; then
      printf '%s\n' "${f}"
      return 0
    fi
  done
  local dir="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  local best="" best_mtime=0 m
  if [[ -d "${dir}" ]]; then
    shopt -s nullglob
    for f in "${dir}"/*.provisionprofile "${dir}"/*.mobileprovision; do
      if security cms -D -i "${f}" 2>/dev/null | grep -q 'com.dwkns.MailExporter' \
        && security cms -D -i "${f}" 2>/dev/null | grep -q 'iCloud.com.dwkns.MailExporter'; then
        m="$(stat -f %m "${f}")"
        if [[ "${m}" -gt "${best_mtime}" ]]; then
          best="${f}"
          best_mtime="${m}"
        fi
      fi
    done
    shopt -u nullglob
  fi
  if [[ -n "${best}" ]]; then
    printf '%s\n' "${best}"
    return 0
  fi
  return 1
}

this_mac_provisioning_udid() {
  system_profiler SPHardwareDataType 2>/dev/null \
    | awk -F': ' '/Provisioning UDID/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
}

refresh_icloud_profile() {
  local proj="${ROOT}/signing/MailExporter.xcodeproj"
  if [[ ! -d "${proj}" ]]; then
    return 1
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ]]; then
    return 1
  fi
  local dest="generic/platform=macOS"
  local udid
  udid="$(this_mac_provisioning_udid || true)"
  if [[ -n "${udid}" ]]; then
    dest="platform=macOS,arch=arm64,id=${udid}"
  fi
  echo "Creating/refreshing Mac iCloud provisioning profile (automatic signing, ${dest})…"
  xcodebuild \
    -project "${proj}" \
    -scheme MailExporter \
    -destination "${dest}" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    -derivedDataPath "${ROOT}/signing/DerivedData" \
    build >/tmp/mailexporter-icloud-profile.log 2>&1 || {
      echo "warning: automatic signing did not produce a profile (see /tmp/mailexporter-icloud-profile.log)."
      return 1
    }
  find_mac_provision_profile
}

IS_ADHOC=0
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  IS_ADHOC=1
fi
IS_CI=0
if [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ]]; then
  IS_CI=1
fi

PROFILE="$(find_mac_provision_profile || true)"
if [[ -z "${PROFILE}" && "${IS_ADHOC}" == "0" && "${IS_CI}" == "0" ]]; then
  PROFILE="$(refresh_icloud_profile || true)"
fi

# Local Apple Development / Developer ID ships with iCloud when a profile exists.
# Explicit INCLUDE_ICLOUD_ENTITLEMENTS=0/1 wins. Ad-hoc and CI-without-profile stay helper-only.
if [[ -z "${INCLUDE_ICLOUD_ENTITLEMENTS:-}" ]]; then
  if [[ "${IS_ADHOC}" == "1" ]]; then
    INCLUDE_ICLOUD=0
  elif [[ "${IS_CI}" == "1" && -z "${PROFILE}" ]]; then
    INCLUDE_ICLOUD=0
  elif [[ -n "${PROFILE}" ]]; then
    INCLUDE_ICLOUD=1
  else
    INCLUDE_ICLOUD=0
  fi
else
  INCLUDE_ICLOUD="${INCLUDE_ICLOUD_ENTITLEMENTS}"
fi

if [[ "${INCLUDE_ICLOUD}" == "1" ]]; then
  if [[ "${IS_ADHOC}" == "1" ]]; then
    echo "error: refusing iCloud entitlements on ad-hoc signing (launchd 163). Unset INCLUDE_ICLOUD_ENTITLEMENTS." >&2
    exit 1
  fi
  if [[ -z "${PROFILE}" ]]; then
    echo "error: iCloud entitlements need a Mac provisioning profile for com.dwkns.MailExporter." >&2
    echo "Add the Apple ID in Xcode → Settings → Accounts, or set PROVISION_PROFILE=." >&2
    exit 1
  fi
  TEAM_ID="$(security cms -D -i "${PROFILE}" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - -- - 2>/dev/null || true)"
  if [[ -z "${TEAM_ID}" ]]; then
    TEAM_ID="LD2427W529"
  fi
  cat > "${ENT_FILE}" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>${TEAM_ID}.com.dwkns.MailExporter</string>
  <key>com.apple.developer.team-identifier</key>
  <string>${TEAM_ID}</string>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array>
    <string>iCloud.com.dwkns.MailExporter</string>
  </array>
  <key>com.apple.developer.ubiquity-container-identifiers</key>
  <array>
    <string>iCloud.com.dwkns.MailExporter</string>
  </array>
  <key>com.apple.developer.icloud-services</key>
  <array>
    <string>CloudDocuments</string>
  </array>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
ENT
  cp "${ENT_FILE}" "${APP_ENT}"
  PROVISION_EMBED="${PROFILE}"
  echo "Developer signing with iCloud entitlements + profile $(basename "${PROFILE}")."
else
  cp "${HELPER_ENT}" "${ENT_FILE}"
  cp "${HELPER_ENT}" "${APP_ENT}"
  if [[ "${IS_ADHOC}" == "1" ]]; then
    echo "Ad-hoc signing: omitting iCloud entitlements (no profile; avoids launchd 163)."
  elif [[ "${IS_CI}" == "1" ]]; then
    echo "CI signing without iCloud entitlements (no Mac provisioning profile)."
  else
    echo "Developer signing without iCloud entitlements (no Mac profile for iCloud.com.dwkns.MailExporter)."
  fi
fi

echo "Compiling Swift UI…"
SWIFT_FILES=()
while IFS= read -r -d '' f; do
  SWIFT_FILES+=("$f")
done < <(find "${SRC}" -name '*.swift' -print0 | sort -z)
if [[ "${#SWIFT_FILES[@]}" -eq 0 ]]; then
  echo "error: no Swift sources in ${SRC}" >&2
  exit 1
fi
swiftc \
  "${SWIFT_FILES[@]}" \
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

if [[ -f "${ROOT}/Resources/how_to_use.md" ]]; then
  cp "${ROOT}/Resources/how_to_use.md" "${HELPER_DIR}/how_to_use.md"
fi

if [[ -f "${ROOT}/Resources/MakeMailDraft.applescript" ]]; then
  cp "${ROOT}/Resources/MakeMailDraft.applescript" "${HELPER_DIR}/MakeMailDraft.applescript"
fi

if [[ -f "${ROOT}/Resources/PutHTMLOnClipboard.js" ]]; then
  cp "${ROOT}/Resources/PutHTMLOnClipboard.js" "${HELPER_DIR}/PutHTMLOnClipboard.js"
fi

if [[ -f "${REPO}/skills/mail-exporter/SKILL.md" ]]; then
  mkdir -p "${HELPER_DIR}/skills/mail-exporter"
  cp "${REPO}/skills/mail-exporter/SKILL.md" "${HELPER_DIR}/skills/mail-exporter/SKILL.md"
fi

mkdir -p "${HELPER_DIR}/bin"
cp "${VENDOR_RG}" "${HELPER_DIR}/bin/rg"
chmod +x "${HELPER_DIR}/bin/rg"

echo "Signing…"
HELPER_ENGINE="${HELPER_DIR}/MailExporterEngine"
ENT="${ROOT}/build/MailExporter.entitlements"
if [[ -n "${PROVISION_EMBED}" ]]; then
  cp "${PROVISION_EMBED}" "${APP}/Contents/embedded.provisionprofile"
  echo "Embedded provisioning profile → Contents/embedded.provisionprofile"
fi

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
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${HELPER_ENT}" "$f" || true
done < <(find "${HELPER_ENGINE}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -name 'MailExporterEngine' \) -print0)

if [[ -d "${HELPER_ENGINE}/_internal/${PY_DIR}" ]]; then
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${HELPER_ENT}" \
    "${HELPER_ENGINE}/_internal/${PY_DIR}" || true
fi
if [[ -d "${HELPER_ENGINE}/_internal/Python.framework" ]]; then
  if [[ -d "${HELPER_ENGINE}/_internal/Python.framework/Versions/${PY_VER}" ]]; then
    codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${HELPER_ENT}" \
      "${HELPER_ENGINE}/_internal/Python.framework/Versions/${PY_VER}" || true
  fi
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${HELPER_ENT}" \
    "${HELPER_ENGINE}/_internal/Python.framework" || true
fi
codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${HELPER_ENT}" \
  "${HELPER_ENGINE}/MailExporterEngine"
codesign --force --sign "${SIGN_IDENTITY}" \
  "${HELPER_DIR}/bin/rg"
APP_SIGN_FLAGS=(--force --sign "${SIGN_IDENTITY}" --entitlements "${APP_ENT}")
if [[ -n "${PROVISION_EMBED}" ]]; then
  APP_SIGN_FLAGS+=(--generate-entitlement-der)
fi
codesign "${APP_SIGN_FLAGS[@]}" "${BIN}"
codesign "${APP_SIGN_FLAGS[@]}" "${APP}"

codesign --verify --verbose=2 "${APP}" 2>&1 | tail -12 || true

echo ""
echo "Built (self-contained): ${APP}"

DEST_APP="/Applications/MailExporter.app"
if [[ -d "/Applications" ]]; then
  echo "Copying to ${DEST_APP}…"
  if pgrep -x MailExporter >/dev/null 2>&1; then
    echo "Quitting running MailExporter so the install can be replaced…"
    osascript -e 'tell application "MailExporter" to quit' 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      pgrep -x MailExporter >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -x MailExporter >/dev/null 2>&1; then
      echo "error: MailExporter is still running; quit it and rerun so /Applications can be updated." >&2
      exit 1
    fi
  fi
  rm -rf "${DEST_APP}"
  ditto "${APP}" "${DEST_APP}"
  INSTALLED="$(defaults read "${DEST_APP}/Contents/Info" CFBundleShortVersionString)"
  echo "Copied to ${DEST_APP} (CFBundleShortVersionString ${INSTALLED})"
  if [[ "${INSTALLED}" != "${VERSION}" ]]; then
    echo "error: ${DEST_APP} is ${INSTALLED}, expected ${VERSION}" >&2
    exit 1
  fi
fi

echo "Grant Full Disk Access only to MailExporter.app, then reopen it."
