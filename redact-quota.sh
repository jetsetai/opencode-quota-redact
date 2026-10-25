#!/usr/bin/env bash
# redact-quota.sh — remove persisted provider-quota error text from an
# OpenCode session transcript in opencode.db (v2 schema).
#
# Usage: redact-quota.sh [ses_id] [--dry] [--help]
# Env:   OPENCODE_DB (default ~/.local/share/opencode/opencode.db)
set -euo pipefail

DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
LONG='Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go'
SHORT='Free usage limit reached'

usage() {
  cat <<'EOF'
Usage: redact-quota.sh [ses_id] [--dry]

Removes stored provider-quota error text ("Free usage limit reached...")
from the transcript of an OpenCode session, in the SQLite database.

  ses_id    target session (ses_...); omitted = auto-detect the active
            session via `opencode api get /api/session/active`
  --dry     report match counts without editing
  --help    show this help

  OPENCODE_DB  override database path (default ~/.local/share/opencode/opencode.db)
EOF
}

die() { echo "error: $*" >&2; exit 2; }

SID=""
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry)  DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown argument: $arg" ;;
    ses_*) [ -n "$SID" ] && usage >&2 && die "multiple session ids given"
           SID="$arg" ;;
    *) usage >&2; die "unexpected argument: $arg" ;;
  esac
done

[ -f "$DB" ] || die "database not found: $DB"

q() { sqlite3 "$DB" "$1"; }

if [ -n "$SID" ]; then
  source="arg"
elif actives=$(opencode api get /api/session/active 2>/dev/null | jq -r '.data | keys[]?' 2>/dev/null) && [ -n "$actives" ]; then
  mapfile -t ids <<<"$actives"
  if [ "${#ids[@]}" -eq 1 ]; then
    SID="${ids[0]}"
    source="active-api"
  else
    echo "error: multiple active sessions detected; pass an explicit session id:" >&2
    printf '  %s\n' "${ids[@]}" >&2
    exit 2
  fi
else
  SID=$(q "SELECT id FROM session_v2 ORDER BY time_updated DESC LIMIT 1;")
  [ -n "$SID" ] || die "no active session detected"
  source="latest"
fi

# Before interpolating into single-quoted SQL, pin the id to the format the
# server issues (ses_<alphanumeric>).
[[ "$SID" =~ ^ses_[A-Za-z0-9]+$ ]] || die "invalid session id: $SID"

q "SELECT count(*) FROM session_v2 WHERE id='$SID';" | grep -qv '^0$' \
  || die "session not found: $SID"

c_sm=$(q "SELECT count(*) FROM session_message WHERE session_id='$SID' AND data LIKE '%Free usage limit%';")
c_p=$(q  "SELECT count(*) FROM part WHERE session_id='$SID' AND data LIKE '%Free usage limit%';")
c_m=$(q  "SELECT count(*) FROM message WHERE session_id='$SID' AND data LIKE '%Free usage limit%';")

echo "SESSION=$SID [source=$source]"

if [ "$DRY" -eq 1 ]; then
  echo "DRY-RUN session_message=$c_sm part=$c_p message=$c_m"
  exit 0
fi

apply_table() {
  local table="$1" total=0 u1 u2
  # Each pass matches only rows containing its own exact target string, so the
  # two change counts are disjoint and their sum is the count of changed rows.
  u1=$(q "UPDATE $table SET data = replace(data, '$LONG', '$PH') WHERE session_id='$SID' AND data LIKE '%$LONG%'; SELECT changes();" | tail -1)
  u2=$(q "UPDATE $table SET data = replace(data, '$SHORT', '$PH') WHERE session_id='$SID' AND data LIKE '%$SHORT%'; SELECT changes();" | tail -1)
  echo $((u1 + u2))
}

# Replacement string: "Error E-<random 8-char code>" (generated once per run).
# Chosen here rather than per-DB so it stays stable across all rows this run.
# Contains no quotes, backslashes, or newlines — JSON-safe by construction.
CODE=$(python3 -c 'import secrets;print("".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8)))')
PH="Error E-$CODE"

c_sm2=$(apply_table session_message)
c_p2=$(apply_table part)
c_m2=$(apply_table message)
echo "APPLIED session_message=$c_sm2 part=$c_p2 message=$c_m2"

bad=$(q "SELECT count(*) FROM session_message WHERE session_id='$SID' AND (data IS NULL OR data='' OR json_valid(data)=0);")
rem=$(q "SELECT count(*) FROM session_message WHERE session_id='$SID' AND data LIKE '%Free usage limit%';")
if [ "$bad" -eq 0 ]; then
  echo "verified: json_valid=ok remaining=$rem"
else
  echo "verified: json_valid=FAIL invalid=$bad remaining=$rem"
  exit 1
fi
