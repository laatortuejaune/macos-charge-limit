#!/bin/bash
# Compile et assemble BatteryLimitMenu.app.
# Xcode n'est pas nécessaire : swift build + assemblage manuel du bundle.
set -euo pipefail

cd "$(dirname "$0")"
APP="BatteryLimitMenu.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BatteryLimitMenu"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Les .lproj vont directement dans Contents/Resources : NSLocalizedString les
# trouve alors via Bundle.main, sans passer par le bundle de ressources SwiftPM.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

# Signature ad hoc : suffisante en local, et nécessaire pour que SMAppService
# accepte d'enregistrer l'app comme élément d'ouverture de session.
codesign --force --sign - "$APP"

echo "OK  ->  $(pwd)/$APP"
