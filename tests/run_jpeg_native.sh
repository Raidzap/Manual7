#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'ImageIO execution tests require macOS with Xcode Command Line Tools.' >&2
    exit 2
fi
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics -framework ImageIO \
    iOS/M7JPEG.m tests/jpeg_native.m -o "$test_dir/jpeg_native"
"$test_dir/jpeg_native"
