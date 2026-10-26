#!/bin/sh
# Usage: Scripts/run_redetect.sh "<drive folder>" <model, e.g. yolo11s_1280>
# Re-runs detection on the drive's video with another bundled model and writes <folder>/sensors_<model>.csv.
# Then: Scripts/run_coach_replay.sh "<folder>" "<folder>/coach_<model>.json" sensors_<model>.csv
#   or: .venv/bin/python Scripts/drive_viewer.py "<folder>" --model <model>
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BIN=$(mktemp -d)
swiftc -O -parse-as-library -o "$BIN/redetect" "Congressional App Challenge/Detection/SignColor.swift" Scripts/redetect.swift
"$BIN/redetect" "$1" "$2"
