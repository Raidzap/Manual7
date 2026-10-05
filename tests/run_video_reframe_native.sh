#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS AVFoundation.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -framework AVFoundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo \
    tests/video_reframe_native.m iOS/M7VideoReframe.m -o "$test_dir/video-reframe-tests"
"$test_dir/video-reframe-tests"
