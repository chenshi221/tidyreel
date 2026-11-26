#!/bin/sh
# Run all Swift checks: version sync, zero-warning build across all targets, and parallel unit tests.
set -e
export PATH=/opt/homebrew/opt/git/bin:$PATH
cd "$(dirname "$0")/.."

plist_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
plist_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
swift_ver=$(sed -n 's/^    public static let appVersion = "\(.*\)"$/\1/p' Sources/TidyreelServices/AppStore.swift)
swift_build=$(sed -n 's/^    public static let appBuild = \(.*\)$/\1/p' Sources/TidyreelServices/AppStore.swift)

[ "$plist_ver+$plist_build" = "$swift_ver+$swift_build" ] || {
  echo "版本不一致：Info.plist $plist_ver+$plist_build，AppStore.swift $swift_ver+$swift_build" >&2
  exit 1
}

swift build --product tidyreel -Xswiftc -warnings-as-errors --explicit-target-dependency-import-check error
swift test --parallel -Xswiftc -warnings-as-errors --explicit-target-dependency-import-check error
