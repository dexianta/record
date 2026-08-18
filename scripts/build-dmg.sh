#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Record"
EXECUTABLE_NAME="Record"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/record.dmg"
LEGACY_APP_PATH="$DIST_DIR/Meeting Audio.app"
LEGACY_DMG_PATH="$DIST_DIR/MeetingAudio-0.1.0-arm64.dmg"
BUILD_DIR="$PROJECT_DIR/.build"
ICONSET_PATH="$BUILD_DIR/$APP_NAME.iconset"
SIGN_IDENTITY="${RECORD_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -nE 's/.*"(Developer ID Application:[^"]+)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
    echo "Warning: ad-hoc signing changes Record's privacy identity after every code change."
    echo "Install an Apple Development or Developer ID certificate to preserve permissions."
else
    echo "Signing with $SIGN_IDENTITY"
fi

export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"

mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$DIST_DIR"
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release --product "$EXECUTABLE_NAME"
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release --show-bin-path)"

test -x "$BIN_DIR/$EXECUTABLE_NAME"
"$BIN_DIR/$EXECUTABLE_NAME" --self-check
plutil -lint "$PROJECT_DIR/Packaging/Info.plist"

rm -rf -- "$APP_PATH" "$LEGACY_APP_PATH" "$ICONSET_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
install -m 755 "$BIN_DIR/$EXECUTABLE_NAME" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
install -m 644 "$PROJECT_DIR/Packaging/Info.plist" "$APP_PATH/Contents/Info.plist"
plutil -insert RecordAdHocSigned -bool "$([[ "$SIGN_IDENTITY" == "-" ]] && echo true || echo false)" "$APP_PATH/Contents/Info.plist"
install -m 644 "$PROJECT_DIR/Packaging/whisper.cpp-LICENSE" "$APP_PATH/Contents/Resources/whisper.cpp-LICENSE"
WHISPER_FRAMEWORK="$(find "$BUILD_DIR/artifacts" -type d -path '*/macos-arm64_x86_64/whisper.framework' -print -quit)"
test -n "$WHISPER_FRAMEWORK"
ditto "$WHISPER_FRAMEWORK" "$APP_PATH/Contents/Frameworks/whisper.framework"
swift "$PROJECT_DIR/scripts/generate-icon.swift" "$ICONSET_PATH"
iconutil -c icns "$ICONSET_PATH" -o "$APP_PATH/Contents/Resources/Record.icns"

codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

STAGE_DIR="$(mktemp -d "$BUILD_DIR/dmg-stage.XXXXXX")"
trap 'rm -rf -- "$STAGE_DIR"' EXIT
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f -- "$DMG_PATH" "$LEGACY_DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

codesign --force --sign "$SIGN_IDENTITY" --identifier "com.local.Record.dmg" "$DMG_PATH"
hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "$DMG_PATH"
