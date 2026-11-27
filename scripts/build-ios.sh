#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG_RAW="${1:-Release}"
if [[ "${BUILD_CONFIG_RAW}" == "release" ]]; then
  BUILD_CONFIG="Release"
elif [[ "${BUILD_CONFIG_RAW}" == "debug" ]]; then
  BUILD_CONFIG="Debug"
else
  BUILD_CONFIG="${BUILD_CONFIG_RAW}"
fi

APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${ROOT_DIR}/dist"
DERIVED_DATA="${ROOT_DIR}/DerivedData/ios-device"
IPA_PATH="${DIST_DIR}/CloudTune-${APP_VERSION}-ios-arm64.ipa"

mkdir -p "${DIST_DIR}"

SWIFT_REMAP_FLAGS="-file-prefix-map ${ROOT_DIR}=/build/CloudTune -file-prefix-map ${HOME}=/build -file-prefix-map /private/var/folders=/build/var-folders -file-prefix-map /var/folders=/build/var-folders"
C_REMAP_FLAGS="-ffile-prefix-map=${ROOT_DIR}=/build/CloudTune -ffile-prefix-map=${HOME}=/build -ffile-prefix-map=/private/var/folders=/build/var-folders -ffile-prefix-map=/var/folders=/build/var-folders"

xcodebuild \
  -project "${ROOT_DIR}/ios/CloudTuneIOS.xcodeproj" \
  -scheme CloudTuneIOS \
  -configuration "${BUILD_CONFIG}" \
  -sdk iphoneos \
  -arch arm64 \
  -derivedDataPath "${DERIVED_DATA}" \
  MARKETING_VERSION="${APP_VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  OTHER_SWIFT_FLAGS="\$(inherited) ${SWIFT_REMAP_FLAGS}" \
  OTHER_CFLAGS="\$(inherited) ${C_REMAP_FLAGS}" \
  build

APP_DIR="${DERIVED_DATA}/Build/Products/${BUILD_CONFIG}-iphoneos/CloudTuneIOS.app"
if [[ "${BUILD_CONFIG}" == "Release" ]]; then
  strip -S -x "${APP_DIR}/CloudTuneIOS" || true
fi

python3 - "${APP_DIR}" "${IPA_PATH}" <<'PY'
import os
from pathlib import Path
import stat
import sys
import zipfile

app_dir = Path(sys.argv[1]).resolve(strict=True)
ipa_path = Path(sys.argv[2])
ipa_path.unlink(missing_ok=True)

with zipfile.ZipFile(ipa_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for file_path in sorted(app_dir.rglob("*")):
        if file_path.is_dir():
            continue
        rel = Path("Payload") / app_dir.name / file_path.relative_to(app_dir)
        info = zipfile.ZipInfo(rel.as_posix())
        st = file_path.stat()
        mode = stat.S_IMODE(st.st_mode)
        info.external_attr = (stat.S_IFREG | mode) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        zf.writestr(info, file_path.read_bytes())
PY

python3 "${ROOT_DIR}/scripts/verify_ipa.py" "${IPA_PATH}"
echo "Packaged iOS ARM64 IPA at: ${IPA_PATH}"
