#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS Foundation and BSD sockets.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    tests/webcam_server_native.m iOS/M7WebcamServer.m -o "$test_dir/webcam-server-tests"
"$test_dir/webcam-server-tests"
