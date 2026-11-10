#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
build_dir="/tmp/MenuScores-build"
mkdir -p "$build_dir"
cd "$project_dir"

# Separate identity and debug-only entry. No installation and no API authorization.
xcodebuild -project MenuScores.xcodeproj -scheme MenuScores -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$build_dir" -jobs 2 \
  -disableAutomaticPackageResolution build CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=local.MenuScores.TerraDemo \
  > "$build_dir/terra-build.log" 2>&1

exec "$build_dir/Build/Products/Debug/MenuScores.app/Contents/MacOS/MenuScores" \
  --terra-summary-demo "$project_dir/MenuScoresTests/Fixtures"
