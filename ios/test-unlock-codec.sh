#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
OUT="${UNLOCK_CODEC_BUILD_DIR:-$HOME/Library/Caches/proximity-unlock/ios-unlock-codec}"
mkdir -p "$OUT"
swiftc -parse-as-library ProximityUnlock/UnlockAuthorization.swift Tests/UnlockAuthorizationTests.swift \
    -o "$OUT/UnlockAuthorizationTests"
"$OUT/UnlockAuthorizationTests"
