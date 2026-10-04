#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS Foundation.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    tests/capture_result_native.m iOS/M7CaptureResult.m -o "$test_dir/capture-tests"
"$test_dir/capture-tests"
