#!/bin/bash
set -euo pipefail
test "$(uname -s)" = Darwin || { echo 'These tests require macOS Vision.' >&2; exit 1; }
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -framework Vision -framework ImageIO -framework CoreGraphics -framework CoreVideo \
    tests/subject_tracker_native.m iOS/M7SubjectTracker.m -o "$test_dir/subject-tracker-tests"
"$test_dir/subject-tracker-tests"
