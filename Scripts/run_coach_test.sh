#!/bin/sh
# Compiles the state machine (and the other pure-logic files) with its tests as a Mac command-line program and runs it.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUT=$(mktemp -d)
swiftc -parse-as-library -o "$OUT/coach_test" \
    "Congressional App Challenge/Coach/StopSignCoach.swift" "Congressional App Challenge/Motion/SignalFilters.swift" \
    "Congressional App Challenge/Detection/SignColor.swift" "Congressional App Challenge/Detection/SignPosition.swift" Scripts/coach_test.swift
"$OUT/coach_test"
