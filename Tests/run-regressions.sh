#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/Image2Movie-tests.XXXXXX")
trap 'if [[ ${KEEP_TEST_OUTPUT:-0} != 1 ]]; then rm -rf "$test_dir"; fi' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wno-int-conversion \
  -include Cocoa/Cocoa.h -I . Tests/ExportRegression.m ImagesToMovie.m \
  ImagesToMovieController.m PrimaryWindowController.m ImageTableController.m \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -o "$test_dir/regressions"
"$test_dir/regressions" "$test_dir"
