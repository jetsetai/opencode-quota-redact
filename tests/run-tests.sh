#!/usr/bin/env bash
# Integration tests for redact-quota.sh against a scratch fixture DB.
set -euo pipefail

TESTDB="${1:-${OPENCODE_TEST_DB:-/tmp/opencode/redact-quota-test.db}}"
export OPENCODE_DB="$TESTDB"

bash tests/fixtures/make-fixture.sh "$TESTDB" >/dev/null
SID="ses_redactfixture01"

assert() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    exit 1
  fi
}

# Runs the command, swallows its stderr into the captured output, asserts a
# nonzero exit AND that the output contains the given message.
refused() {
  local name="$1" msg="$2"; shift 2
  local out="" rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && grep -q "$msg" <<<"$out"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (rc=$rc out=$out)" >&2
    exit 1
  fi
}

msg_count() {
  sqlite3 "$TESTDB" "SELECT count(*) FROM session_message WHERE session_id='$1' AND data LIKE '%Free usage limit%';"
}

# 1-2. dry run reports counts and does not edit
out=$(bash redact-quota.sh "$SID" --dry)
assert "dry reports counts" grep -q "DRY-RUN session_message=3 part=1 message=0" <<<"$out"
assert "dry does not edit" [ "$(msg_count "$SID")" = "3" ]

# 3-5. apply redacts, reports, verifies JSON validity, leaves control row intact
out=$(bash redact-quota.sh "$SID")
assert "apply reports" grep -q "APPLIED session_message=3 part=1 message=0" <<<"$out"
assert "json_valid ok" grep -q "json_valid=ok" <<<"$out"
assert "clean row untouched" [ "$(sqlite3 "$TESTDB" "SELECT count(*) FROM session_message WHERE id='msg_clean' AND data = '{\"time\":{},\"text\":\"smooth sailing\"}';")" = "1" ]

# 6. second application is a no-op
out=$(bash redact-quota.sh "$SID")
assert "idempotent second run" grep -q "APPLIED session_message=0 part=0 message=0" <<<"$out"

# 7. unknown session id is refused
refused "unknown session refuses" "session not found" bash redact-quota.sh "ses_unknown"

# 8. no-args fallback resolves a session via the live API that is NOT in the
#    scratch DB, so the script must refuse rather than guess.
refused "auto-detect cross-db refuses" "session not found" bash redact-quota.sh

echo "ALL TESTS PASSED"
