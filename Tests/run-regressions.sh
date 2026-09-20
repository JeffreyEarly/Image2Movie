#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/Image2Movie-tests.XXXXXX")
trap 'if [[ ${KEEP_TEST_OUTPUT:-0} != 1 ]]; then rm -rf "$test_dir"; fi' EXIT
app_bundle=${APP_BUNDLE_PATH:-"$test_dir/build/Build/Products/Debug/Image2Movie.app"}
build_dir=${REGRESSION_BUILD_DIR:-"$test_dir/build"}
if [[ -z ${APP_BUNDLE_PATH:-} ]]; then
  app_bundle="$build_dir/Build/Products/Debug/Image2Movie.app"
  if ! xcodebuild -project Image2Movie.xcodeproj -scheme Image2Movie \
    -configuration Debug -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO build \
    > "$test_dir/build.log" 2>&1; then
    cat "$test_dir/build.log"
    exit 1
  fi
fi
if ! xcodebuild -project Image2Movie.xcodeproj -scheme Image2MovieRegression \
  -configuration Debug -derivedDataPath "$build_dir" build > "$test_dir/regression-build.log" 2>&1; then
  cat "$test_dir/regression-build.log"
  exit 1
fi
"$build_dir/Build/Products/Debug/Image2MovieRegression" "$test_dir" "$app_bundle"
