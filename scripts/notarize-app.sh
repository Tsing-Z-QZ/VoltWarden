#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo 'Usage: NOTARY_PROFILE=profile bash scripts/notarize-app.sh /absolute/VoltWarden.app /absolute/VoltWarden-arm64.zip' >&2
    exit 2
fi
APP_PATH="$1"
ZIP_PATH="$2"
: "${NOTARY_PROFILE:?Create a notarytool keychain profile first}"
[[ "$APP_PATH" = /* && "$APP_PATH" = *.app && -d "$APP_PATH" && "$ZIP_PATH" = /* && "$ZIP_PATH" = *.zip && ! -e "$ZIP_PATH" ]] || exit 2
codesign --verify --deep --strict "$APP_PATH"
SIGNATURE="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
[[ "$SIGNATURE" = *"Authority=Developer ID Application:"* ]] || {
    echo 'Public release requires a Developer ID Application signature.' >&2; exit 2;
}
# No Apple ID or password is embedded in this script or its command line.
mkdir -p "$(dirname "$ZIP_PATH")"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
# Recreate the archive after stapling; only this final ZIP is uploaded to GitHub.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH"
