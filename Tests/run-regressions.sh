#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/Image2Movie-tests.XXXXXX")
trap 'if [[ ${KEEP_TEST_OUTPUT:-0} != 1 ]]; then rm -rf "$test_dir"; fi' EXIT
app_bundle=${APP_BUNDLE_PATH:-"$test_dir/build/Build/Products/Debug/Image2Movie.app"}
if [[ -z ${APP_BUNDLE_PATH:-} ]]; then
  if ! xcodebuild -project Image2Movie.xcodeproj -scheme Image2Movie \
    -configuration Debug -derivedDataPath "$test_dir/build" CODE_SIGNING_ALLOWED=NO build \
    > "$test_dir/build.log" 2>&1; then
    cat "$test_dir/build.log"
    exit 1
  fi
fi
xcrun clang -arch arm64 -mmacosx-version-min=27.0 -fobjc-arc -Wno-deprecated-declarations -Wno-int-conversion \
  -include Cocoa/Cocoa.h -I . Tests/ExportRegression.m ImagesToMovie.m MovieFrameRenderer.m \
  ImagesToMovieController.m PrimaryWindowController.m ImageTableController.m AppController.m \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework UniformTypeIdentifiers -framework CoreImage -framework ImageIO -framework VideoToolbox \
  -o "$test_dir/regressions"
"$test_dir/regressions" "$test_dir" "$app_bundle"
