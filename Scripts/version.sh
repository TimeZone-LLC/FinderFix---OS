#!/bin/bash

finderfix_read_version() {
    local version_root="$1"
    FINDERFIX_VERSION="$(< "${version_root}/VERSION")" || return 1
    FINDERFIX_BUILD_NUMBER="$(< "${version_root}/BUILD_NUMBER")" || return 1
    local version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(dev|alpha|beta|rc)[1-9][0-9]*)?$'
    if [[ ! "${FINDERFIX_VERSION}" =~ ${version_pattern} ]]; then
        echo "VERSION must be MAJOR.MINOR.PATCH with an optional -devN, -alphaN, -betaN, or -rcN suffix." >&2
        return 64
    fi
    if [[ ! "${FINDERFIX_BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
        echo "BUILD_NUMBER must be a positive integer." >&2
        return 64
    fi
    FINDERFIX_RELEASE_VERSION="${FINDERFIX_VERSION%%-*}"
}
