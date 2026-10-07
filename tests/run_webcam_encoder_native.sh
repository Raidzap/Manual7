#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS Core Image.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -framework CoreGraphics -framework CoreVideo -framework CoreImage -framework ImageIO \
    tests/webcam_encoder_native.m iOS/M7WebcamEncoder.m -o "$test_dir/webcam-encoder-tests"
"$test_dir/webcam-encoder-tests"
