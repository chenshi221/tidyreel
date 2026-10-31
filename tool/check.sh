#!/bin/sh
# Run all checks. Homebrew git first: /usr/bin/git fails until the Xcode license is accepted.
set -e
export PATH=/opt/homebrew/opt/git/bin:$PATH
cd "$(dirname "$0")/.."
(cd packages/tidyreel_core && dart format --set-exit-if-changed lib test && dart analyze && dart test)
(cd app && dart format --set-exit-if-changed lib test && flutter analyze && flutter test)
