#!/bin/sh
set -eu
OUT="${TMPDIR:-/tmp}/manual7-pairing-manager-native"
clang -fobjc-arc -fmodules -Wall -Wextra \
  -framework Foundation -framework Vision -framework CoreImage -framework CoreVideo \
  -framework ImageIO -framework CoreGraphics \
  tests/pairing_manager_native.m iOS/M7PairingManager.m -o "$OUT"
"$OUT"
