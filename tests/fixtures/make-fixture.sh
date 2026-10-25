#!/usr/bin/env bash
# Builds a scratch OpenCode DB fixture for tests.
# Usage: bash tests/fixtures/make-fixture.sh [/path/to/testdb]
set -euo pipefail

TESTDB="${1:-${OPENCODE_TEST_DB:-/tmp/opencode/redact-quota-test.db}}"
rm -f "$TESTDB" "$TESTDB-wal" "$TESTDB-shm"

sqlite3 "$TESTDB" <<'EOF'
CREATE TABLE `session_v2` (
  `id` text PRIMARY KEY,
  `time_updated` integer NOT NULL
);
CREATE TABLE `session_message` (
  `id` text PRIMARY KEY,
  `session_id` text NOT NULL,
  `type` text NOT NULL,
  `seq` integer NOT NULL,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `data` text NOT NULL,
  UNIQUE (`session_id`,`seq`)
);
CREATE TABLE `part` (
  `id` text PRIMARY KEY,
  `message_id` text NOT NULL,
  `session_id` text NOT NULL,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `data` text NOT NULL
);
CREATE TABLE `message` (
  `id` text PRIMARY KEY,
  `session_id` text NOT NULL,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `data` text NOT NULL
);

-- v2 session record
INSERT INTO session_v2 (id, time_updated) VALUES ('ses_redactfixture01', 1792900000000);

-- row 1: assistant error with plain message string
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_row1','ses_redactfixture01','assistant',1,1792900000001,1792900000001,
'{"time":{},"finish":"error","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go","status":429}}');

-- row 2: idle failure with escaped nested response body
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_row2','ses_redactfixture01','idle',2,1792900000002,1792900000002,
'{"outcome":"failed","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go","status":429,"response":{"body":"{\"type\":\"error\",\"error\":{\"type\":\"FreeUsageLimitError\",\"message\":\"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go\"}}"}}}');

-- row 3: user message that merely quotes the phrase
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_row3','ses_redactfixture01','user',3,1792900000003,1792900000003,
'{"text":"the agent said: Free usage limit reached and stopped"}');

-- control row: must never change
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_clean','ses_redactfixture01','user',4,1792900000004,1792900000004,
'{"time":{},"text":"smooth sailing"}');

-- legacy part row for the same session (short phrase)
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
VALUES ('part_row1','msg_legacy','ses_redactfixture01',1792900000005,1792900000005,
'{"text":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"}');
EOF
echo "fixture built: $TESTDB"
