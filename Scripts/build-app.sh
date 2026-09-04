#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
PRODUCT_NAME="FinderFix"
BUILD_DIRECTORY="${PROJECT_ROOT}/.build/app"
APP_DIRECTORY="${BUILD_DIRECTORY}/${PRODUCT_NAME}.app"
CONTENTS_DIRECTORY="${APP_DIRECTORY}/Contents"
MACOS_DIRECTORY="${CONTENTS_DIRECTORY}/MacOS"
RESOURCES_DIRECTORY="${CONTENTS_DIRECTORY}/Resources"
SIGNING_IDENTITY="${FINDERFIX_SIGNING_IDENTITY:--}"
BUILD_PURPOSE="${FINDERFIX_BUILD_PURPOSE:-development}"
UNIVERSAL_BUILD="${FINDERFIX_UNIVERSAL:-0}"
source "${PROJECT_ROOT}/Scripts/version.sh"
finderfix_read_version "${PROJECT_ROOT}"

case "${CONFIGURATION}" in
    debug|release) ;;
    *)
        echo "Configuration must be 'debug' or 'release'." >&2
        exit 64
        ;;
esac

case "${BUILD_PURPOSE}" in
    development|distribution) ;;
    *)
        echo "FINDERFIX_BUILD_PURPOSE must be 'development' or 'distribution'." >&2
        exit 64
        ;;
esac

case "${UNIVERSAL_BUILD}" in
    0|1) ;;
    *)
        echo "FINDERFIX_UNIVERSAL must be 0 or 1." >&2
        exit 64
        ;;
esac

if [[ "${BUILD_PURPOSE}" == "distribution" ]]; then
    if [[ "${CONFIGURATION}" != "release" ]]; then
        echo "Distribution builds require the release configuration." >&2
        exit 64
    fi
    if [[ "${UNIVERSAL_BUILD}" != "1" ]]; then
        echo "Distribution builds must include arm64 and x86_64." >&2
        exit 64
    fi
    if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
        echo "Distribution builds require FINDERFIX_SIGNING_IDENTITY with a Developer ID Application identity." >&2
        exit 64
    fi
    if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
        echo "Distribution builds require a 'Developer ID Application:' signing identity." >&2
        exit 64
    fi
elif [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    echo "Building an ad-hoc development app. It is not distributable and its privacy grants can change after every rebuild." >&2
elif [[ "${SIGNING_IDENTITY}" == "Developer ID Application:"* ]]; then
    echo "Developer ID identities are accepted only by Scripts/release-app.sh." >&2
    exit 64
fi

SWIFT_BUILD_ARGUMENTS=(--configuration "${CONFIGURATION}")
if [[ "${UNIVERSAL_BUILD}" == "1" ]]; then
    SWIFT_BUILD_ARGUMENTS+=(--arch arm64 --arch x86_64)
fi

cd "${PROJECT_ROOT}"
swift build \
    "${SWIFT_BUILD_ARGUMENTS[@]}" \
    --product "${PRODUCT_NAME}"
BIN_DIRECTORY="$(
    swift build \
        "${SWIFT_BUILD_ARGUMENTS[@]}" \
        --show-bin-path
)"

PRODUCT_BINARY="${BIN_DIRECTORY}/${PRODUCT_NAME}"
if [[ ! -x "${PRODUCT_BINARY}" ]]; then
    echo "SwiftPM did not produce ${PRODUCT_BINARY}." >&2
    exit 1
fi

if [[ "${UNIVERSAL_BUILD}" == "1" ]]; then
    PRODUCT_ARCHITECTURES="$(lipo -archs "${PRODUCT_BINARY}")"
    if [[ " ${PRODUCT_ARCHITECTURES} " != *" arm64 "* \
        || " ${PRODUCT_ARCHITECTURES} " != *" x86_64 "* ]]; then
        echo "SwiftPM did not produce a universal arm64/x86_64 executable (found: ${PRODUCT_ARCHITECTURES})." >&2
        exit 1
    fi
fi

rm -rf "${APP_DIRECTORY}"
install -d "${MACOS_DIRECTORY}" "${RESOURCES_DIRECTORY}"
install -m 755 "${PRODUCT_BINARY}" "${MACOS_DIRECTORY}/${PRODUCT_NAME}"
install -m 644 "${PROJECT_ROOT}/Configuration/Info.plist" "${CONTENTS_DIRECTORY}/Info.plist"
plutil -insert CFBundleShortVersionString -string "${FINDERFIX_RELEASE_VERSION}" "${CONTENTS_DIRECTORY}/Info.plist"
plutil -insert CFBundleVersion -string "${FINDERFIX_BUILD_NUMBER}" "${CONTENTS_DIRECTORY}/Info.plist"
plutil -insert FinderFixVersion -string "${FINDERFIX_VERSION}" "${CONTENTS_DIRECTORY}/Info.plist"
install -m 644 "${PROJECT_ROOT}/Assets/AppIcon.icns" "${RESOURCES_DIRECTORY}/AppIcon.icns"
install -m 644 "${PROJECT_ROOT}/LICENSE" "${RESOURCES_DIRECTORY}/LICENSE.txt"

if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    codesign --force --options runtime --entitlements "${PROJECT_ROOT}/Configuration/FinderFix.entitlements" --sign - "${APP_DIRECTORY}"
elif [[ "${BUILD_PURPOSE}" == "distribution" ]]; then
    codesign --force --options runtime --timestamp --entitlements "${PROJECT_ROOT}/Configuration/FinderFix.entitlements" --sign "${SIGNING_IDENTITY}" "${APP_DIRECTORY}"
else
    codesign --force --options runtime --timestamp=none --entitlements "${PROJECT_ROOT}/Configuration/FinderFix.entitlements" --sign "${SIGNING_IDENTITY}" "${APP_DIRECTORY}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIRECTORY}"
echo "Built ${APP_DIRECTORY} ${FINDERFIX_VERSION} (${FINDERFIX_BUILD_NUMBER}, ${BUILD_PURPOSE}, $(lipo -archs "${MACOS_DIRECTORY}/${PRODUCT_NAME}"))"
