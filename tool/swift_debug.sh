#!/bin/sh
# Share the same Apple Silicon Debug build graph across builds, tests and packaging.
exec swift "$@" -c debug --arch arm64 -Xswiftc -warnings-as-errors --explicit-target-dependency-import-check error
