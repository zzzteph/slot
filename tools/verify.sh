#!/bin/sh
# Says whether the game is good:
#
#   sh tools/verify.sh                    # uses `godot` from PATH
#   GODOT=/c/.../godot.exe sh tools/verify.sh
#
# The suite's "N passed, 0 failed" line is not the whole truth: GDScript ABORTS a test function the moment
# it hits a script error, and the checks after it never run (or fail). So any SCRIPT ERROR in the output
# fails the run as well.
set -e
cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"
OUT="${OUT:-build/verification}"
mkdir -p "$OUT"
fail=0

"$GODOT" --headless --path . --import > /dev/null 2>&1 || true
"$GODOT" --headless --path . --script res://tests/run_tests.gd > "$OUT/suite-output.txt" 2>&1 || true
grep -a "Summary" "$OUT/suite-output.txt" || true

if ! grep -aq " 0 failed ===" "$OUT/suite-output.txt"; then
  echo "FAILED: failing assertions." >&2
  grep -a "^FAIL" "$OUT/suite-output.txt" >&2 || true
  fail=1
fi
if grep -aE "SCRIPT ERROR|Parse Error|Compile Error" "$OUT/suite-output.txt" > "$OUT/suite-errors.txt"; then
  echo "FAILED: script errors -- a test function aborted." >&2
  cat "$OUT/suite-errors.txt" >&2
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "VERIFICATION FAILED.  Log: $OUT/suite-output.txt"
  exit 1
fi
echo "Verified: every check passed, no script errors."
