#!/usr/bin/env bash
# Runs the stress test on one device and prints the run id its events carry.
#
#   tool/stress.sh <device id>          # `flutter devices` lists them
#
# Every event the run sends carries `stress_run: <id>` in its properties, so what reached the
# server can be counted afterwards by that id.
set -euo pipefail
device="${1:?usage: tool/stress.sh <device id>}"
run="${STRESS_RUN:-$(date +%Y%m%d%H%M%S)-$RANDOM}"
cd "$(dirname "$0")/.."
echo "stress run $run on $device"
flutter test integration_test/stress_test.dart -d "$device" --dart-define=STRESS_RUN="$run" "${@:2}"
echo "stress run $run done"
