#!/bin/sh
# Build the macOS app. If app/tmdb.local.json exists (gitignored), its TMDB token is
# compiled in as the default key; otherwise users enter their own in Settings.
# Usage: tool/build_macos.sh [debug|release]   (default: release)
set -e
cd "$(dirname "$0")/../app"
mode="${1:-release}"
defines=""
[ -f tmdb.local.json ] && defines="--dart-define-from-file=tmdb.local.json"
flutter build macos --"$mode" $defines
echo "Built: $(pwd)/build/macos/Build/Products/$( [ "$mode" = release ] && echo Release || echo Debug )/tidyreel.app"
