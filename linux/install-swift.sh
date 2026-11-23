#!/usr/bin/env bash
# Installs the official Swift toolchain for Linux into /opt/swift (idempotent).
# Usage: linux/install-swift.sh [version]   e.g. linux/install-swift.sh 6.2.1
set -euo pipefail

VERSION="${1:-6.2.1}"
PREFIX="${SWIFT_PREFIX:-/opt/swift}"

if [[ -x "$PREFIX/usr/bin/swift" ]] && "$PREFIX/usr/bin/swift" --version 2>/dev/null | grep -q "version $VERSION"; then
    echo "Swift $VERSION already installed in $PREFIX"; exit 0
fi

. /etc/os-release
case "$ID$VERSION_ID" in
    ubuntu24.04) PLATFORM=ubuntu2404; SUFFIX=ubuntu24.04 ;;
    ubuntu22.04) PLATFORM=ubuntu2204; SUFFIX=ubuntu22.04 ;;
    *) echo "unsupported distribution: $PRETTY_NAME (see https://www.swift.org/install/linux/)" >&2; exit 1 ;;
esac
[[ "$(uname -m)" == aarch64 ]] && { PLATFORM="$PLATFORM-aarch64"; SUFFIX="$SUFFIX-aarch64"; }

URL="https://download.swift.org/swift-${VERSION}-release/${PLATFORM}/swift-${VERSION}-RELEASE/swift-${VERSION}-RELEASE-${SUFFIX}.tar.gz"
echo "Downloading $URL"
mkdir -p "$PREFIX"
curl -fL --retry 3 "$URL" | tar xz --strip-components=1 -C "$PREFIX"
"$PREFIX/usr/bin/swift" --version
