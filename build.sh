#!/bin/bash
# Installs Aurel: builds Aurel.app, starts it at login, and (re)starts it now. Run it again after any change.
set -e; cd "$(dirname "$0")"
VERSION=$(tr -d '\n' < VERSION)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION: $VERSION"; exit 1; }
IFS=. read -r VERSION_MAJOR VERSION_MINOR VERSION_PATCH <<< "$VERSION"
(( VERSION_MINOR < 1000 && VERSION_PATCH < 1000 )) || { echo "VERSION components must be below 1000"; exit 1; }
BUILD=$((VERSION_MAJOR * 1000000 + VERSION_MINOR * 1000 + VERSION_PATCH))
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo "Aurel needs macOS 26 or later (it uses Apple's new on-device speech)."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Needs Apple's command line tools. Run: xcode-select --install   then run ./build.sh again."; exit 1; }
command -v python3 >/dev/null || { echo "Aurel needs Python 3. Install it, then run ./build.sh again."; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# A compiler error must leave the installed app and its resources alone. Package.swift adds Textual (native Markdown and math);
# its first build fetches it and takes a minute or two. The scratch path is outside the source, which Nix keeps read-only.
APPBUILD="${XDG_CACHE_HOME:-$HOME/.cache}/aurel-app"
LOG=$(swift build -c release --scratch-path "$APPBUILD" 2>&1) || { echo "$LOG" | grep -E 'error' >&2; exit 1; }
cp "$APPBUILD/release/Aurel" "$STAGE/Aurel"; cp -R "$APPBUILD/release/"*.bundle "$STAGE/"
# The Parakeet speech helper (Settings → Speech model). Its first build fetches FluidAudio and takes a few minutes; later ones are quick.
# The scratch path is outside the source, which Nix keeps read-only. Without it, Apple speech still works.
swift build -c release --package-path parakeet --scratch-path "${XDG_CACHE_HOME:-$HOME/.cache}/aurel-parakeet" 2>&1 | grep -E 'error|Compiling aurel|Build complete' || true
cp "${XDG_CACHE_HOME:-$HOME/.cache}/aurel-parakeet/release/aurel-parakeet" "$STAGE/" 2>/dev/null || echo "Note: the Parakeet helper didn't build, so Settings won't offer Parakeet speech."
APP=~/Applications/Aurel.app   # in Applications so System Settings can list it for permissions
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ui"
cp aurel.py "$APP/Contents/Resources/"
rm -f "$APP/Contents/Resources/ui/"*.html "$APP/Contents/Resources/ui/orbs.js"   # the old web pages: the windows are native now
cp ui/*.js ui/*.json "$APP/Contents/Resources/ui/"
cp ui/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.aurel.app</string>
<key>CFBundleName</key><string>Aurel</string>
<key>CFBundleExecutable</key><string>Aurel</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>AurelCommit</key><string>$COMMIT</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>AurelSource</key><string>$(pwd)</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Aurel listens when you use its shortcut or microphone button.</string>
<key>NSAppleEventsUsageDescription</key><string>Aurel controls apps like Finder, Chrome and Music when you ask it to.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Aurel reads your calendar, adds events you request, and asks before moving or deleting existing events. Calendar details are sent to your chosen AI model.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Aurel turns your words into text on this Mac.</string>
</dict></plist>
P
mv "$STAGE/Aurel" "$APP/Contents/MacOS/Aurel"
rm -rf "$APP/Contents/Resources/"*.bundle; mv "$STAGE/"*.bundle "$APP/Contents/Resources/"   # Textual's code-highlighting and math fonts
# With a code-signing identity named "Aurel Local Signing" in the keychain, macOS keeps permissions across
# rebuilds and auto-updates; ad hoc signing would ask for every permission again after each one. So make it once.
ID=$(security find-identity -p codesigning | awk '/Aurel Local Signing/{print $2; exit}')
if [ -z "$ID" ]; then
  K=$(mktemp -d)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=Aurel Local Signing" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" -keyout "$K/k.pem" -out "$K/c.pem" 2>/dev/null &&
  /usr/bin/openssl pkcs12 -export -inkey "$K/k.pem" -in "$K/c.pem" -out "$K/a.p12" -passout pass:aurel 2>/dev/null &&
  security import "$K/a.p12" -P aurel -T /usr/bin/codesign >/dev/null 2>&1 || true   # fails quietly: ad hoc still works
  rm -rf "$K"
  ID=$(security find-identity -p codesigning | awk '/Aurel Local Signing/{print $2; exit}')
fi
if [ -f "$STAGE/aurel-parakeet" ]; then mv "$STAGE/aurel-parakeet" "$APP/Contents/MacOS/"; codesign -s "${ID:--}" --force "$APP/Contents/MacOS/aurel-parakeet"; fi   # nested code is signed before its app
codesign -s "${ID:--}" --force "$APP"
# register with macOS, or System Settings can't list it for permissions
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
AGENT=~/Library/LaunchAgents/com.aurel.app.plist   # starts at login, restarts if it crashes (Quit stays quit)
# Atticus was renamed Aurel: keep its settings, chats and models. Before anything creates ~/.config/aurel, and before the updater's early exit;
# an Aurel folder with no settings yet (only a launch's log and lock) is set aside rather than kept over them.
if [ -d ~/.config/atticus ] && [ ! -e ~/.config/aurel/settings.json ]; then
  [ -e ~/.config/aurel ] && mv ~/.config/aurel ~/.config/aurel-before-migration-$$
  mv ~/.config/atticus ~/.config/aurel
fi
mkdir -p ~/Library/LaunchAgents ~/.config/aurel
cat > "$AGENT" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.aurel.app</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Aurel</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>StandardErrorPath</key><string>$HOME/.config/aurel/app.err</string>
</dict></plist>
P
[ -n "$AUREL_NO_RESTART" ] && exit 0   # the app's own updater restarts it when idle
# Reload the job so launchd refreshes its executable signing requirement after a rebuild.
launchctl bootout gui/$(id -u)/com.aurel.app 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/Aurel$" 2>/dev/null && sleep 1   # stop a copy opened by hand too
# bootout can return before the job has finished unloading.
launchctl bootstrap gui/$(id -u) "$AGENT" 2>/dev/null || { sleep 1; launchctl bootstrap gui/$(id -u) "$AGENT" 2>/dev/null || {
  echo "Could not add Aurel to Login Items; opening it directly instead."
  open "$APP"
}; }
echo "Aurel is running. Hold Control+Option+Space and talk."
# Retire Atticus, Aurel's old name: its app, login item and routine jobs (Aurel reinstalls routines when it starts).
# Last, because stopping the old app may stop this script when its updater started it.
if [ -e ~/Library/LaunchAgents/com.atticus.app.plist ] || [ -d ~/Applications/Atticus.app ]; then
  for J in ~/Library/LaunchAgents/com.atticus.routine.*.plist; do launchctl bootout gui/$(id -u) "$J" 2>/dev/null || true; rm -f "$J"; done
  rm -rf ~/Applications/Atticus.app ~/Library/LaunchAgents/com.atticus.app.plist
  launchctl bootout gui/$(id -u)/com.atticus.app 2>/dev/null || true; pkill -f "/Atticus.app/Contents/MacOS/Atticus$" 2>/dev/null || true
fi
