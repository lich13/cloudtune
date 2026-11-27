#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CloudTune"
BUILD_CONFIG="${1:-release}"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

cd "${ROOT_DIR}"
SWIFT_BUILD_FLAGS=(
  -c "${BUILD_CONFIG}"
  -Xswiftc -file-prefix-map -Xswiftc "${ROOT_DIR}=/build/CloudTune"
  -Xswiftc -file-prefix-map -Xswiftc "${HOME}=/build"
  -Xswiftc -file-prefix-map -Xswiftc "/private/var/folders=/build/var-folders"
  -Xswiftc -file-prefix-map -Xswiftc "/var/folders=/build/var-folders"
  -Xcc "-ffile-prefix-map=${ROOT_DIR}=/build/CloudTune"
  -Xcc "-ffile-prefix-map=${HOME}=/build"
  -Xcc "-ffile-prefix-map=/private/var/folders=/build/var-folders"
  -Xcc "-ffile-prefix-map=/var/folders=/build/var-folders"
)
if [[ "${BUILD_CONFIG}" == "release" ]]; then
  SWIFT_BUILD_FLAGS+=(-Xswiftc -O -Xswiftc -whole-module-optimization)
fi

swift build --product "${APP_NAME}" "${SWIFT_BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${APP_NAME}"

python3 - "${APP_BUNDLE}" <<'PY'
from pathlib import Path
import shutil, sys
target = Path(sys.argv[1])
if target.exists():
    shutil.rmtree(target)
PY

mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
if [[ "${BUILD_CONFIG}" == "release" ]]; then
  strip -S -x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" || true
fi

cp "${ROOT_DIR}/Packaging/macos/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "${ROOT_DIR}/Packaging/macos/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_BUNDLE}/Contents/Info.plist"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

SIGN_ID="${APPLE_SIGNING_IDENTITY:--}"
codesign --force --deep --sign "${SIGN_ID}" "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"
python3 "${ROOT_DIR}/scripts/verify_native_privacy.py" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "Built macOS app bundle at: ${APP_BUNDLE} (version ${APP_VERSION})"

if [[ "${PACKAGE_DMG:-0}" == "1" ]]; then
  ARCH="$(uname -m)"
  DMG_NAME="${APP_NAME}-${APP_VERSION}-${ARCH}.dmg"
  DMG_PATH="${DIST_DIR}/${DMG_NAME}"
  DMG_STAGE="${DIST_DIR}/.dmg-stage"

  python3 - "${DMG_STAGE}" "${DMG_PATH}" <<'PY'
from pathlib import Path
import shutil, sys
stage = Path(sys.argv[1])
dmg = Path(sys.argv[2])
if stage.exists():
    shutil.rmtree(stage)
dmg.unlink(missing_ok=True)
Path(str(dmg) + ".sha256").unlink(missing_ok=True)
PY

  mkdir -p "${DMG_STAGE}"
  ditto --rsrc --extattr "${APP_BUNDLE}" "${DMG_STAGE}/${APP_NAME}.app"
  ln -s /Applications "${DMG_STAGE}/Applications"

  hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

  python3 - "${DMG_STAGE}" <<'PY'
from pathlib import Path
import shutil, sys
stage = Path(sys.argv[1])
if stage.exists():
    shutil.rmtree(stage)
PY
  echo "Packaged DMG at: ${DMG_PATH}"
fi
