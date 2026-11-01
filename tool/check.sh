#!/bin/sh
# Run all checks. Homebrew git first: /usr/bin/git fails until the Xcode license is accepted.
set -e
export PATH=/opt/homebrew/opt/git/bin:$PATH
cd "$(dirname "$0")/.."
# app/lib/version.dart must match app/pubspec.yaml (tool/release.sh writes both).
pub=$(sed -n 's/^version: //p' app/pubspec.yaml)
dart=$(sed -n "s/^const appVersion = '\(.*\)';$/\1/p" app/lib/version.dart)+$(sed -n 's/^const appBuild = \(.*\);$/\1/p' app/lib/version.dart)
[ "$pub" = "$dart" ] || { echo "版本不一致：pubspec $pub，version.dart $dart" >&2; exit 1; }
(cd packages/tidyreel_core && dart format --set-exit-if-changed lib test && dart analyze && dart test)
(cd app && dart format --set-exit-if-changed lib test && flutter analyze && flutter test)
