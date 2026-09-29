#!/bin/bash
set -euo pipefail

# Outputs are explicit and must not already exist; the installed app is never used as a template.
if [[ $# -ne 2 ]]; then
    echo 'Usage: SIGN_IDENTITY="Apple Development: …" bash scripts/package-app.sh /tmp/VoltWardenBuild /absolute/output/VoltWarden.app' >&2
    exit 2
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$1"
APP_PATH="$2"
: "${SIGN_IDENTITY:?Set a valid Apple Development or Developer ID Application signing identity}"
[[ "$BUILD_DIR" = /* && "$APP_PATH" = /* && "$APP_PATH" = *.app && ! -e "$APP_PATH" ]] || {
    echo 'Use absolute paths and a new .app output path.' >&2; exit 2;
}
[[ "$(uname -m)" = arm64 ]] || { echo 'This release recipe supports Apple Silicon only.' >&2; exit 2; }
cd "$PROJECT_DIR"
swift build -c release --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" \
    "$APP_PATH/Contents/XPCServices/helper.xpc/Contents/MacOS" \
    "$APP_PATH/Contents/Library/LaunchDaemons"
cp Packaging/App-Info.plist "$APP_PATH/Contents/Info.plist"
cp Packaging/Reader-Info.plist "$APP_PATH/Contents/XPCServices/helper.xpc/Contents/Info.plist"
cp "$BIN_DIR/stasis-custom" "$APP_PATH/Contents/MacOS/stasis"
cp "$BIN_DIR/stasis-reader-helper" "$APP_PATH/Contents/XPCServices/helper.xpc/Contents/MacOS/helper"
cp "$BIN_DIR/stasis-charging-helper" "$APP_PATH/Contents/Library/LaunchDaemons/charging-helper"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINKED_SDK="$(xcrun vtool -show-build "$APP_PATH/Contents/MacOS/stasis" | awk '$1 == "sdk" { print $2; exit }')"
[[ "$LINKED_SDK" = "$SDK_VERSION" ]] || {
    echo "Incorrect linked SDK: $LINKED_SDK; expected $SDK_VERSION. Refusing to package legacy UI." >&2
    exit 1
}
cp ChargingHelper/com.srimanachanta.stasis.charging-helper.native.plist "$APP_PATH/Contents/Library/LaunchDaemons/"
ditto "$BIN_DIR/StasisCustom_Defaults.bundle" "$APP_PATH/Contents/Resources/StasisCustom_Defaults.bundle"
xcrun xcstringstool compile Stasis/L10n/Localizable.xcstrings --output-directory "$APP_PATH/Contents/Resources"
ICON_BUILD_DIR="$BUILD_DIR/IconAssets"
mkdir -p "$ICON_BUILD_DIR"
xcrun actool --compile "$ICON_BUILD_DIR" --platform macosx \
    --minimum-deployment-target 14.8 --app-icon AppIcon \
    --output-partial-info-plist "$BUILD_DIR/IconInfo.plist" \
    Packaging/AppIcon.icon > "$BUILD_DIR/IconCompilation.plist"
[[ -s "$ICON_BUILD_DIR/Assets.car" && -s "$ICON_BUILD_DIR/AppIcon.icns" ]] || {
    echo 'Icon Composer asset compilation did not produce the expected files.' >&2
    exit 1
}
cp "$ICON_BUILD_DIR/Assets.car" "$ICON_BUILD_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
cp Vendor/SMCKit/LICENSE "$APP_PATH/Contents/Resources/SMCKit-LICENSE"
cp Vendor/Defaults/LICENSE "$APP_PATH/Contents/Resources/Defaults-LICENSE"

SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" = "Developer ID Application:"* ]]; then
    SIGN_FLAGS+=(--timestamp)
else
    SIGN_FLAGS+=(--timestamp=none)
fi
# Sign inside out so the outer resource seal includes each helper's signature.
# Finder/iCloud metadata on freshly generated bundles is not allowed by codesign.
# Only strip these two metadata keys from the new output, not security quarantine.
xattr -dr com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
codesign "${SIGN_FLAGS[@]}" --identifier com.srimanachanta.stasis.helper "$APP_PATH/Contents/XPCServices/helper.xpc"
codesign "${SIGN_FLAGS[@]}" --identifier com.srimanachanta.stasis.charging-helper.native "$APP_PATH/Contents/Library/LaunchDaemons/charging-helper"
codesign "${SIGN_FLAGS[@]}" --identifier com.srimanachanta.stasis "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built: $APP_PATH"
