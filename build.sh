#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIGURATION="${1:-release}"
OUTPUT_DIRECTORY="${PROJECT_ROOT}/OUT"
OUTPUT_APP="${OUTPUT_DIRECTORY}/FinderFix.app"
BUILT_APP="${PROJECT_ROOT}/.build/app/FinderFix.app"

resolve_signing_identity() {
    if [[ -n "${FINDERFIX_SIGNING_IDENTITY:-}" ]]; then
        printf '%s\n' "${FINDERFIX_SIGNING_IDENTITY}"
        return
    fi

    local valid_identities
    valid_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    local installed_authority=""
    if [[ -d "/Applications/FinderFix.app" ]]; then
        installed_authority="$(
            codesign -dv --verbose=4 "/Applications/FinderFix.app" 2>&1 \
                | sed -n 's/^Authority=\(Apple Development:.*\)$/\1/p' \
                | head -1
        )"
    fi

    local installed_identity=""
    if [[ -n "${installed_authority}" ]]; then
        installed_identity="$(
            printf '%s\n' "${valid_identities}" \
                | awk -v authority="${installed_authority}" '
                    /"Apple Development: / {
                        name = $0
                        sub(/^[^"]*"/, "", name)
                        sub(/"[^"]*$/, "", name)
                        if (name == authority) {
                            print $2
                            exit
                        }
                    }
                '
        )"
    fi
    if [[ -n "${installed_identity}" ]]; then
        echo "Reusing the installed app's Apple Development identity." >&2
        printf '%s\n' "${installed_identity}"
        return
    fi

    local development_identities
    development_identities="$(
        printf '%s\n' "${valid_identities}" \
            | awk '/"Apple Development: / { print $2 }'
    )"
    local identity_count
    identity_count="$(
        printf '%s\n' "${development_identities}" \
            | awk 'NF { count += 1 } END { print count + 0 }'
    )"
    if [[ "${identity_count}" == "1" ]]; then
        echo "Using the available Apple Development identity." >&2
        printf '%s\n' "${development_identities}"
        return
    fi

    if [[ "${identity_count}" == "0" ]]; then
        echo "No Apple Development identity is available." >&2
    else
        echo "Multiple Apple Development identities are available and none matches the installed app." >&2
    fi
    echo "Set FINDERFIX_SIGNING_IDENTITY to the intended identity, or '-' to opt into ad-hoc signing." >&2
    return 78
}

SIGNING_IDENTITY="$(resolve_signing_identity)"

case "${CONFIGURATION}" in
    debug|release) ;;
    *)
        echo "Usage: ./build.sh [debug|release]" >&2
        exit 64
        ;;
esac

FINDERFIX_BUILD_PURPOSE=development \
FINDERFIX_SIGNING_IDENTITY="${SIGNING_IDENTITY}" \
FINDERFIX_UNIVERSAL=0 \
    "${PROJECT_ROOT}/Scripts/build-app.sh" "${CONFIGURATION}"

if [[ ! -d "${BUILT_APP}" ]]; then
    echo "Build completed without producing ${BUILT_APP}." >&2
    exit 1
fi

install -d "${OUTPUT_DIRECTORY}"
STAGING_DIRECTORY="$(mktemp -d "${OUTPUT_DIRECTORY}/.finderfix-stage.XXXXXX")"
BACKUP_DIRECTORY="$(mktemp -d "${OUTPUT_DIRECTORY}/.finderfix-backup.XXXXXX")"

cleanup() {
    local exit_status="$?"
    if [[ -d "${BACKUP_DIRECTORY}/FinderFix.app" && ! -e "${OUTPUT_APP}" ]]; then
        mv "${BACKUP_DIRECTORY}/FinderFix.app" "${OUTPUT_APP}" || true
    fi
    rm -rf "${STAGING_DIRECTORY}" "${BACKUP_DIRECTORY}"
    return "${exit_status}"
}
trap cleanup EXIT

ditto "${BUILT_APP}" "${STAGING_DIRECTORY}/FinderFix.app"
codesign --verify --deep --strict "${STAGING_DIRECTORY}/FinderFix.app"

if [[ -e "${OUTPUT_APP}" ]]; then
    mv "${OUTPUT_APP}" "${BACKUP_DIRECTORY}/FinderFix.app"
fi
mv "${STAGING_DIRECTORY}/FinderFix.app" "${OUTPUT_APP}"
rm -rf "${BACKUP_DIRECTORY}/FinderFix.app"

LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LAUNCH_SERVICES_REGISTER}" ]]; then
    "${LAUNCH_SERVICES_REGISTER}" -u "${BUILT_APP}" >/dev/null 2>&1 || true
    "${LAUNCH_SERVICES_REGISTER}" -u "${OUTPUT_APP}" >/dev/null 2>&1 || true
fi

echo "FinderFix is ready at ${OUTPUT_APP}"
