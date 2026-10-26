#!/bin/sh
# Usage: Scripts/run_coach_replay.sh "<drive folder>" [output.json] [sensors file]   (defaults: <folder>/coach.json, sensors.csv)
# A sensors file from Scripts/run_redetect.sh (sensors_<model>.csv) replays the drive with another model's detections.
# Compiles the real StopSignCoach with the replay tool as a Mac command-line program and runs it on a recorded drive.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
FOLDER="$1"
OUT_JSON="${2:-$FOLDER/coach.json}"
BIN=$(mktemp -d)
swiftc -parse-as-library -o "$BIN/coach_replay" \
    "Congressional App Challenge/Coach/StopSignCoach.swift" "Congressional App Challenge/Motion/SignalFilters.swift" "Congressional App Challenge/Detection/SignColor.swift" "Congressional App Challenge/Detection/SignPosition.swift" \
    Scripts/coach_replay.swift
"$BIN/coach_replay" "$FOLDER" "$OUT_JSON" ${3:+"$3"}
