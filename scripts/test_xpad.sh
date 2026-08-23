#!/bin/bash
#
# Host-native unit test for user/usb/xpad.c3's report-parsing logic
# (test/xpad_parse_test.c3) — checks the byte/bit decoding against
# hand-computed expected values, no Duo or real controller needed.
# This does NOT exercise the USB transfer/enumeration path (dwc2.c3,
# the hub-downstream code in usbd.c3) — that only real hardware can
# confirm; see docs/devlog.md for the manual real-hardware check.
#
# Usage: bash scripts/test_xpad.sh

set -e

ROOT="$(dirname "$0")/.."
cd "$ROOT"

mkdir -p build/test
c3c compile-test -o build/test/xpad_parse_test test/xpad_parse_test.c3 user/usb/xpad.c3
