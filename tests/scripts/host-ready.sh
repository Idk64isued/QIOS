#!/bin/bash
# scripts/host-ready's verdicts with the load limit lifted: READY with a free slot, WAIT while another process holds
# the only one, READY again once it exits, WAIT short of disk. Prints ok/FAIL per check; exits 1 on any FAIL.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/ltm-host-ready-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export LTM_EMULATOR_SLOT_DIR="$T" LTM_EMULATOR_SLOTS=1 LTM_HOST_LOAD_PER_CORE=100000 LTM_HOST_MIN_DISK_GB=0
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi; }
check "a free slot is READY" '"$SRC/scripts/host-ready" | grep -q "^READY .*1 of 1 slots free"'
perl -e 'use Fcntl ":flock"; open F, ">>", $ARGV[0]; flock(F, LOCK_EX); sleep 30' "$T/slot-0" &
holder=$!
sleep 1
check "a held slot is WAIT, exit 1" 'out="$("$SRC/scripts/host-ready")"; [[ $? == 1 && "$out" == "WAIT all 1 emulator slots taken"* ]]'
check "one reason has no separator after it" '[[ "$("$SRC/scripts/host-ready")" == "WAIT all 1 emulator slots taken ($T)" ]]'
check "two reasons are joined by \"; \"" '[[ "$(LTM_HOST_MIN_DISK_GB=100000000 "$SRC/scripts/host-ready")" == "WAIT all 1 emulator slots taken ($T); "*" GB free under ~/Developer (want 100000000; scripts/clean)" ]]'
kill "$holder"
wait "$holder" 2>/dev/null
check "a slot whose holder died is READY" '"$SRC/scripts/host-ready" >/dev/null'
check "too little disk is WAIT" '! LTM_HOST_MIN_DISK_GB=100000000 "$SRC/scripts/host-ready" >/dev/null'
exit $failed
