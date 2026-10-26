#!/bin/zsh
# Runs the test suite in debug and in release (-O), since the app ships
# optimised. With only the Command Line Tools installed, SwiftPM doesn't find
# the swift-testing macro plugin on its own, so point it there.
set -e
cd "$(dirname "$0")/.."
extra=()
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d $plugins ]]; then
  extra=(-Xswiftc -plugin-path -Xswiftc $plugins)
fi
if [[ "${1:-}" == "--quick" ]]; then
  shift
  swift test $extra "$@"
else
  echo "== debug"; swift test $extra "$@"
  echo "== release"; swift test -c release -Xswiftc -enable-testing $extra "$@"
fi
