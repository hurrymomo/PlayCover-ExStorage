#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/playcover-capacity-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun --sdk macosx swiftc -O -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$test_dir/module-cache" \
    "$repo_dir/PlayCover ExStorage/StorageService/Internal/APFSContainerCapacity.swift" \
    "$repo_dir/Tests/APFSContainerCapacityTests.swift" \
    -o "$test_dir/capacity-tests"
"$test_dir/capacity-tests"
xcrun --sdk macosx swiftc -O -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$test_dir/module-cache" \
    "$repo_dir/PlayCover ExStorage/Diagnostics/MigrationTrace.swift" \
    "$repo_dir/Tests/MigrationTraceTests.swift" \
    -o "$test_dir/log-tests"
# Foundation's test home override keeps production logging code away from the
# real user's logs. The executable checks this before performing any writes.
CFFIXED_USER_HOME="$test_dir/test-user" "$test_dir/log-tests" "$test_dir/test-user"
