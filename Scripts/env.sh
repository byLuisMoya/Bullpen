#!/usr/bin/env bash
# Workarounds when only Command Line Tools are installed (no Xcode):
# - the newest CLT SDK uses SwiftUI macros whose plugin ships only with Xcode, so pin an older SDK;
# - the Swift Testing macro plugin lives in a subfolder SwiftPM does not search.
# With Xcode selected, nothing is changed.
SWIFT_EXTRA_FLAGS=()
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    CLT=/Library/Developer/CommandLineTools
    SDK=$(ls -d "$CLT"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
    if [[ -n "$SDK" ]]; then export SDKROOT="$SDK"; fi
    SWIFT_EXTRA_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
fi
