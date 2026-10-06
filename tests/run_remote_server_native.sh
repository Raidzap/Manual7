#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS Foundation and BSD sockets.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    tests/remote_server_native.m iOS/M7RemoteServer.m -o "$test_dir/remote-server-tests"
"$test_dir/remote-server-tests"
