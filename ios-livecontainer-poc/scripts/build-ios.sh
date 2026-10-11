#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
mkdir -p artifacts

{
  date -u
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
  xcodegen --version
  git rev-parse HEAD 2>/dev/null || true
} > artifacts/build-environment.txt

cd ios
xcodegen generate
cd "$task_root"

for scheme in ContainerSmoke OBSiPhoneLab; do
  xcodebuild \
    -project ios/OBSiPhoneLab.xcodeproj \
    -scheme "$scheme" \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | tee "artifacts/${scheme}-build.log"

  app="build/Build/Products/Release-iphoneos/${scheme}.app"
  test -d "$app"
  test -f "$app/Frameworks/ProbeKit.framework/ProbeKit"
  plutil -lint "$app/Info.plist"
  executable="$(plutil -extract CFBundleExecutable raw -o - "$app/Info.plist")"
  file "$app/$executable" > "artifacts/${scheme}-binary.txt"
  otool -L "$app/$executable" >> "artifacts/${scheme}-binary.txt"

  stage="build/ipa-${scheme}"
  mkdir -p "$stage/Payload"
  ditto "$app" "$stage/Payload/${scheme}.app"
  ditto -c -k --keepParent "$stage/Payload" "artifacts/${scheme}-LiveContainer.ipa"
done

python3 scripts/inspect_ipa.py artifacts/ContainerSmoke-LiveContainer.ipa artifacts/OBSiPhoneLab-LiveContainer.ipa \
  > artifacts/ipa-manifest.json
shasum -a 256 artifacts/*-LiveContainer.ipa > artifacts/SHA256SUMS.txt
