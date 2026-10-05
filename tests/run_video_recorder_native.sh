#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS AVFoundation.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation +    -framework AVFoundation -framework AudioToolbox +    tests/video_recorder_native.m iOS/M7VideoRecorder.m -o "$test_dir/video-recorder-tests"
"$test_dir/video-recorder-tests"
