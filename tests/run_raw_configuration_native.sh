#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS Foundation.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    tests/raw_configuration_native.m iOS/M7RAWConfiguration.m -o "$test_dir/raw-configuration-tests"
"$test_dir/raw-configuration-tests"
