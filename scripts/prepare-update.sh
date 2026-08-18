#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 || ! "$1" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || ! "$2" =~ '^[0-9]+$' ]]; then
    echo "Usage: $0 <version> <build-number>"
    echo "Example: $0 0.2.0 2"
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$1"
BUILD_NUMBER="$2"
ARCHIVE_NAME="record-$VERSION.zip"
UPDATE_DIR="$(mktemp -d "$PROJECT_DIR/.build/update.XXXXXX")"
trap 'rm -rf -- "$UPDATE_DIR"' EXIT

RECORD_VERSION="$VERSION" RECORD_BUILD_NUMBER="$BUILD_NUMBER" \
    "$SCRIPT_DIR/build-dmg.sh"

cp "$PROJECT_DIR/appcast.xml" "$UPDATE_DIR/appcast.xml"
cp "$PROJECT_DIR/dist/$ARCHIVE_NAME" "$UPDATE_DIR/$ARCHIVE_NAME"

"$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --account dexianta.record \
    --download-url-prefix "https://github.com/dexianta/record/releases/download/v$VERSION/" \
    --link "https://github.com/dexianta/record" \
    "$UPDATE_DIR"

cp "$UPDATE_DIR/appcast.xml" "$PROJECT_DIR/appcast.xml"

echo "Prepared Record $VERSION (build $BUILD_NUMBER):"
echo "$PROJECT_DIR/dist/record.dmg"
echo "$PROJECT_DIR/dist/$ARCHIVE_NAME"
echo "$PROJECT_DIR/appcast.xml"
