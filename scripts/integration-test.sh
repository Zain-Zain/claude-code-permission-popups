#!/usr/bin/env bash
# Runs the real permission-hook binary with no app listening and checks it stays silent and fast.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null
BIN=.build/debug/permission-hook
SOCK="/tmp/pp-int-$$.sock"
export PERMISSION_POPUPS_SOCKET="$SOCK"
rm -f "$SOCK"
OUT_FILE=$(mktemp)
trap 'rm -f "$OUT_FILE" "$SOCK"' EXIT

now() { python3 -c 'import time; print(time.time())'; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Valid request, no app running: silent, exit 0, fast.
start=$(now)
code=0
"$BIN" < Tests/PermissionCoreTests/Fixtures/bash.json > "$OUT_FILE" || code=$?
end=$(now)
[ "$code" -eq 0 ] || fail "exit code $code"
[ ! -s "$OUT_FILE" ] || fail "expected empty stdout"
python3 -c "import sys; sys.exit(0 if $end - $start < 0.2 else 1)" || fail "took too long ($start -> $end)"

# 5 MB of garbage: silent, exit 0.
code=0
head -c 5242880 /dev/zero | tr '\0' 'a' | "$BIN" > "$OUT_FILE" || code=$?
[ "$code" -eq 0 ] || fail "garbage input exit code $code"
[ ! -s "$OUT_FILE" ] || fail "garbage input produced output"

echo OK
