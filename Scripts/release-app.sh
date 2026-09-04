#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="FinderFix"
APP_DIRECTORY="${PROJECT_ROOT}/.build/app/${PRODUCT_NAME}.app"
INFO_PLIST="${APP_DIRECTORY}/Contents/Info.plist"
OUTPUT_DIRECTORY="${PROJECT_ROOT}/.build/distribution"
SIGNING_IDENTITY="${FINDERFIX_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${FINDERFIX_NOTARY_PROFILE:-}"

if [[ -z "${SIGNING_IDENTITY}" ]]; then
    echo "Set FINDERFIX_SIGNING_IDENTITY to a Developer ID Application identity." >&2
    exit 64
fi
if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
    echo "FINDERFIX_SIGNING_IDENTITY must name a 'Developer ID Application:' identity." >&2
    exit 64
fi
if [[ -z "${NOTARY_PROFILE}" ]]; then
    echo "Set FINDERFIX_NOTARY_PROFILE to a notarytool keychain profile." >&2
    exit 64
fi
if ! security find-identity -v -p codesigning | grep -F "\"${SIGNING_IDENTITY}\"" >/dev/null; then
    echo "The requested Developer ID signing identity is not available in the keychain." >&2
    exit 1
fi
if ! xcrun --find notarytool >/dev/null; then
    echo "notarytool is unavailable in the selected Xcode toolchain." >&2
    exit 1
fi
if [[ -n "$(git -C "${PROJECT_ROOT}" status --porcelain)" ]]; then
    echo "Release builds require a clean Git worktree so the source archive matches the binary." >&2
    exit 1
fi

FINDERFIX_BUILD_PURPOSE=distribution \
FINDERFIX_UNIVERSAL=1 \
FINDERFIX_SIGNING_IDENTITY="${SIGNING_IDENTITY}" \
    "${PROJECT_ROOT}/Scripts/build-app.sh" release

install -d "${OUTPUT_DIRECTORY}"
SUBMISSION_ARCHIVE="${OUTPUT_DIRECTORY}/${PRODUCT_NAME}-notarization.zip"
NOTARY_RESULT="${OUTPUT_DIRECTORY}/notary-result.plist"
ditto -c -k --keepParent "${APP_DIRECTORY}" "${SUBMISSION_ARCHIVE}"

if ! xcrun notarytool submit \
    "${SUBMISSION_ARCHIVE}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait \
    --output-format plist > "${NOTARY_RESULT}"; then
    echo "Notarization submission failed. See ${NOTARY_RESULT}." >&2
    exit 1
fi

NOTARY_STATUS="$(plutil -extract status raw -o - "${NOTARY_RESULT}")"
if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
    echo "Notarization was not accepted (status: ${NOTARY_STATUS}). See ${NOTARY_RESULT}." >&2
    exit 1
fi

xcrun stapler staple "${APP_DIRECTORY}"
xcrun stapler validate "${APP_DIRECTORY}"
codesign --verify --deep --strict --verbose=2 "${APP_DIRECTORY}"
spctl --assess --type execute --verbose=2 "${APP_DIRECTORY}"

VERSION="$(plutil -extract FinderFixVersion raw -o - "${INFO_PLIST}")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "${INFO_PLIST}")"
FINAL_ARCHIVE="${OUTPUT_DIRECTORY}/${PRODUCT_NAME}-${VERSION}-${BUILD}-macos-universal.zip"
SOURCE_ARCHIVE="${OUTPUT_DIRECTORY}/${PRODUCT_NAME}-${VERSION}-${BUILD}-source.zip"
ditto -c -k --keepParent "${APP_DIRECTORY}" "${FINAL_ARCHIVE}"
git -C "${PROJECT_ROOT}" archive \
    --format=zip \
    --prefix="${PRODUCT_NAME}-${VERSION}-${BUILD}-source/" \
    --output="${SOURCE_ARCHIVE}" \
    HEAD

echo "Created notarized release archive: ${FINAL_ARCHIVE}"
echo "Created corresponding source archive: ${SOURCE_ARCHIVE}"
