#!/bin/zsh
# Builds build/Monotask.app with only the Command Line Tools.
#   --run      launch it afterwards
#   --install  copy it to /Applications first (launch at login works best from there)
set -euo pipefail
cd "${0:A:h}/.."

if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

swift build -c release

app=build/Monotask.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Monotask "$app/Contents/MacOS/Monotask"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app" 2>/dev/null
echo "Built $app"

install=false
run=false
for arg in "$@"; do
  case $arg in
    --install) install=true ;;
    --run) run=true ;;
  esac
done

if $install || $run; then
  pkill -f "Monotask.app/Contents/MacOS/Monotask" 2>/dev/null || true
  sleep 0.5
fi

if $install; then
  if [[ -d /Applications/Monotask.app ]]; then
    existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Monotask.app/Contents/Info.plist 2>/dev/null || echo unknown)
    if [[ $existing != io.github.avi130805.Monotask ]]; then
      echo "/Applications/Monotask.app is a different app ($existing); leaving it alone." >&2
      exit 1
    fi
    rm -rf /Applications/Monotask.app
  fi
  cp -R "$app" /Applications/Monotask.app
  app=/Applications/Monotask.app
  echo "Installed $app"
fi

if $run; then
  open "$app"
fi
