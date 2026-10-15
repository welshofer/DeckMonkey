#!/bin/bash
# keynote-app.sh — print the path of the installed Keynote.app, found by bundle identifier.
#
# usage: Scripts/keynote-app.sh [--version]
#   --version  print "<CFBundleShortVersionString> (<CFBundleVersion>)" instead, e.g. "15.4 (7051.0.79)"
#
# The bundle is not always /Applications/Keynote.app (the M4 has "Keynote Creator Studio.app"), so
# never hard-code the path. KEYNOTE_APP overrides discovery. Exits 1 if Keynote is not found.

set -euo pipefail

app="${KEYNOTE_APP:-}"
if [[ -z "$app" ]]; then
  app=$(osascript -e 'POSIX path of (path to application id "com.apple.Keynote")' 2>/dev/null || true)
  app="${app%/}"
fi
if [[ -z "$app" || ! -f "$app/Contents/Info.plist" ]]; then
  app=$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.Keynote"' 2>/dev/null | grep '^/Applications/' | head -1 || true)
fi
[[ -n "$app" && -f "$app/Contents/Info.plist" ]] || { echo "Keynote (com.apple.Keynote) not found; set KEYNOTE_APP" >&2; exit 1; }

if [[ "${1:-}" == "--version" ]]; then
  plist="$app/Contents/Info.plist"
  printf '%s (%s)\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
else
  printf '%s\n' "$app"
fi
