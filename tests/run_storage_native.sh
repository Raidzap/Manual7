#!/bin/bash
set -eu
test "$(uname -s)" = Darwin || { echo 'These tests require macOS Foundation.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    "$repo_root/tests/storage_native.m" "$repo_root/iOS/M7Storage.m" -o "$test_dir/storage-tests"
"$test_dir/storage-tests"
