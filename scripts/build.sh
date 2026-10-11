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

# Command Line Tools 27 ship a macOS 27 SDK where SwiftUI's @State is a macro whose plugin only Xcode includes.
# If the default SDK needs it and it isn't here, build against the newest installed SDK that doesn't.
if [[ -z "${SDKROOT:-}" ]]; then
  sdk=$(xcrun --show-sdk-path)
  needs_macros() { grep -qs '"StateMacro"' "$1"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*-apple-macos.swiftinterface }
  have_macros() { [[ -e /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib || -e "$1/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]] }
  if needs_macros "$sdk" && ! have_macros "$sdk"; then
    for candidate in ${(On)$(print -l "${sdk:h}"/MacOSX[0-9]*.[0-9]*.sdk(N))}; do
      if ! needs_macros "$candidate"; then
        export SDKROOT=$candidate
        echo "Using ${candidate:t}: this Command Line Tools' default SDK needs SwiftUI macros that only Xcode ships." >&2
        break
      fi
    done
    [[ -n "${SDKROOT:-}" ]] || { echo "No installed SDK can build SwiftUI without Xcode's macro plugin. Install Xcode, or the macOS 26 Command Line Tools." >&2; exit 1; }
  fi
fi

swift build -c release

app=build/Monotask.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Monotask "$app/Contents/MacOS/Monotask"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
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
