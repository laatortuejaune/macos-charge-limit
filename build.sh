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

# Le bundle vient d'être remplacé, mais une instance déjà lancée continue de
# tourner sur l'ancien binaire. `open` ne la remplacerait pas : il se contente
# d'activer celle qui existe, si bien qu'on croit avoir mis à jour sans l'avoir
# fait. On le signale plutôt que de tuer l'app sans prévenir.
if pgrep -f 'BatteryLimitMenu.app/Contents/MacOS' >/dev/null 2>&1; then
    echo
    echo "Note: an instance is still running the previous build."
    echo "      Quit it first — 'open' alone only activates the running copy:"
    echo "      pkill -f 'BatteryLimitMenu.app/Contents/MacOS' && open $APP"
fi
