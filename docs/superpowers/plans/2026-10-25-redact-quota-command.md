# OpenCode Quota Redact — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `/redact-quota` slash command that removes persisted provider-quota error text from an active OpenCode session's transcript in `~/.local/share/opencode/opencode.db`.

**Architecture:** A bash engine script (`redact-quota.sh`) does session resolution and scoped SQLite `replace()` edits; a thin markdown command template (`commands/redact-quota.md`) runs it via an `!` shell block so its report lands in the prompt; `install.sh` installs both into `~/.config/opencode/`. Repo: `jetsetai/opencode-quota-redact` (public, MIT).

**Tech Stack:** bash, sqlite3 CLI (WAL-safe), jq (session API parse), OpenCode v2.1.0 custom commands, GitHub CLI.

**Spec:** docs/superpowers/specs/2026-10-25-redact-quota-design.md (short design, approved in-session by user — recap: auto-target active session; optional explicit `ses_id`; `--dry` reports without editing; default applies; no backups; JSON-safe replacements only).

## Global Constraints

- OpenCode V2 docs are the source of truth: global commands live in `~/.config/opencode/commands/`; `!`backtick`` shell blocks expand before prompt submit; `$1` is the first positional argument.
- DB schema (verified live): v2 transcripts live in `session_message` (`id`,`session_id`,`seq`,`data` JSON) with sessions in `session_v2`. Legacy fallback tables `part` and `message` also expose `session_id` + `data`. There is NO `text` column anywhere.
- Target strings: long = `Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go`; short prefix = `Free usage limit reached`.
- Replacement placeholder = `[redacted: provider quota error]` — must contain no `"`, `\`, or newline (keeps JSON valid without escaping).
- Edits are scoped by `session_id`; the script never edits all sessions.
- No DB backups (user directive). Safety comes from: session scoping + quote-free replacements + post-hoc `json_valid()` check.
- DB path override env var: `OPENCODE_DB` (default `$HOME/.local/share/opencode/opencode.db`) — required for testability.

## Review Focus

1. **Empty/absence input:** a session with zero matching rows → script must report `APPLIED ...session_message=0...` with exit 0, not error. Test: `tests/run-tests.sh::dry_clean_row` + apply-on-scratch.
2. **Wrong-session input:** unknown `ses_...` id → nonzero exit, message contains `session not found`. Test: pins Task 1.
3. **Cross-DB leak:** no-args run against the scratch fixture DB (API resolves a different real session) → must refuse because that session id does not exist in the target DB, never silently edit. Test: pins Task 1.
4. **JSON validity after replace:** all edited rows must still pass `json_valid()`; script verifies and reports `verified: json_valid=ok remaining=0`. Test: pins Task 1.
5. **Double-application idempotency:** running the script twice must be a no-op the second time (0 changes, exit 0). Test: pins Task 1.

---

### Task 1: Engine script `redact-quota.sh` (+ test fixture)

**Files:**
- Create: `redact-quota.sh`
- Create: `tests/fixtures/make-fixture.sh` (builds `TESTDB` scratch DB via env var `OPENCODE_TEST_DB`)
- Create: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `opencode api get /api/session/active` → `{"data":{"<ses_id>":{"type":"running"}}}` (jq `.data | keys[]`); sqlite3 CLI.
- Produces (Task 2 and Task 3 rely on these EXACT report strings):
  - `SESSION=<ses_id> [source=arg|active-api|latest]`
  - Dry: `DRY-RUN session_message=<n> part=<n> message=<n>`
  - Apply: `APPLIED session_message=<n> part=<n> message=<n>` then `verified: json_valid=ok remaining=<n>` (ok means every `data` in that session passes `json_valid()`; `remaining` = rows still matching LIKE)
  - Errors → stderr, exit 2: `error: session not found: <id>` / `error: no active session detected` / `error: database not found`.

- [ ] **Step 1: Write `tests/run-tests.sh` (5 assertions)**

```bash
#!/usr/bin/env bash
# Exit 0 only when all assertions pass; each assertion echoes "PASS "name"" to stderr on fail.
set -euo pipefail
TESTDB="${OPENCODE_TEST_DB:-/tmp/opencode/redact-quota-test.db}"
export OPENCODE_DB="$TESTDB"
bash tests/fixtures/make-fixture.sh "$TESTDB"
SID=$(sqlite3 "$TESTDB" "SELECT id FROM session_v2;")
out=$(bash redact-quota.sh "$SID" --dry)
assert "dry reports counts" grep -q "DRY-RUN session_message=3 part=1 message=0"
assert "dry does not edit" [ "$(sqlite3 "$TESTDB" "SELECT count(*) FROM session_message WHERE data LIKE '%Free usage limit%';")" = "3" ]
out=$(bash redact-quota.sh "$SID")
assert "apply reports" grep -q "APPLIED session_message=3 part=1 message=0" ... && grep -q "remaining=0"
assert "json_valid ok" grep -q "json_valid=ok"
assert "clean row untouched" [ "$(sqlite3 "$TESTDB" "SELECT count(*) FROM session_message WHERE id='msg_clean' AND data='{\"time\":{},\"text\":\"smooth sailing\"}';")" = "1" ]
out=$(bash redact-quota.sh "$SID"); assert "idempotent second run" grep -q "APPLIED session_message=0 part=0 message=0"
set +e; out=$(bash redact-quota.sh "ses_unknown" 2>&1); rc=$?; set -e
assert "unknown session refuses" [ $rc -ne 0 ] && grep -q "session not found"
bash redact-quota.sh 2>&1 | grep -q ... # no-args fallback test expects it to resolve the API session then refuse on scratch DB:
set +e; out=$(bash redact-quota.sh 2>&1); rc=$?; set -e
assert "auto-detect cross-db refuses" [ $rc -ne 0 ] && grep -q "session not found"
echo "ALL TESTS PASSED"
```

(Implementer may clean this up; assertions named exactly: `dry reports counts`, `dry does not edit`, `apply reports`, `json_valid ok`, `clean row untouched`, `idempotent second run`, `unknown session refuses`, `auto-detect cross-db refuses`.)

- [ ] **Step 2: Write `tests/fixtures/make-fixture.sh`**

Creates schema identical to live `- [ ]` `session_v2`, `session_message`, `part`, `message` (NULL column shapes from the live schema in Global Constraints), session `ses_redactfixture01`, and 3 `session_message` rows containing the target strings:

```sql
-- row 1 (assistant error, plain):
'{"time":{},"finish":"error","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go","status":429}}'
-- row 2 (idle, escaped nested body):
'{"outcome":"failed","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go","status":429,"response":{"body":"{\"type\":\"error\",\"error\":{\"type\":\"FreeUsageLimitError\",\"message\":\"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go\"}}"}}}'
-- row 3 (user message that merely quotes the phrase):
'{"text":"the agent said: Free usage limit reached and stopped"}'
-- clean row 4 (control, id msg_clean, must never change):
'{"time":{},"text":"smooth sailing"}'
```

Plus 1 `part` row for the same session containing the short phrase; 0 rows in `message`. Deletes any pre-existing fixture DB first so tests are repeatable.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/run-tests.sh`
Expected: FAIL (redact-quota.sh missing → assertion fails).

- [ ] **Step 4: Implement `redact-quota.sh`**

Interface already pinned. Body rules:

1. Args parse: `ses_*` → session id; `--dry` → dry mode; `-h|--help` → usage; anything else → usage error (exit 2).
2. Session resolution in order: (a) explicit arg (`source=arg`); (b) `opencode api get /api/session/active | jq -r '.data | keys[]?'` — if exactly one, use it (`source=active-api`); if several, error exit 2 listing them, instructing explicit id; (c) fallback newest session row (`source=latest`): `SELECT id FROM session_v2 ORDER BY time_updated DESC LIMIT 1`.
3. Existence check: `SELECT count(*) FROM session_v2 WHERE id='<sid>'` = 0 → `error: session not found: <sid>`, exit 2.
4. SQL (each table statement followed by `SELECT printf('session_message=%d', changes())`-style echo, dry mode = same statements run as SELECT-only counts, no UPDATE):
   ```sql
   UPDATE session_message SET data = replace(data, '<long>', '$PH') WHERE session_id='<sid>' AND data LIKE '%Free usage limit%';
   UPDATE session_message SET data = replace(data, '<short>', '$PH') WHERE session_id='<sid>' AND data LIKE '%Free usage limit%';
   -- same pair for part and message tables, guarded by the same WHERE session_id
   ```
   (Statement batching: emit `printf('APPLIED session_message=%d part=%d message=%d\n', ...)` after all three, capturing per-table changes with intermediate `SELECT changes()` calls — implementer may store in shell vars via `sqlite3 ... | tail -1`.)
5. Post-check after apply: `SELECT count(*) FROM session_message WHERE session_id='<sid>' AND (data IS NULL OR data='' OR json_valid(data)=0);` (must be 0 and only then `json_valid=ok`; print `remaining=<n>` from the LIKE count).
6. `set -euo pipefail`; single-quoted-sql safety: session id matched against `^ses_[A-Za-z0-9]+$` before interpolation.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: PASS (`ALL TESTS PASSED`).

- [ ] **Step 6: Commit**

```bash
git add redact-quota.sh tests/
git commit -m "feat(redact): engine script with session-scoped sqlite redaction"
```

### Task 2: Slash command template + `install.sh`

**Files:**
- Create: `commands/redact-quota.md`
- Create: `install.sh`

**Interfaces:**
- Consumes: `redact-quota.sh` report strings (Task 1).
- Produces: installed `~/.config/opencode/commands/redact-quota.md` + `~/.config/opencode/bin/redact-quota.sh` (executable).

- [ ] **Step 1: Write the exact command template**

```md
---
description: Remove persisted provider quota error text from this session transcript
---

Run the following and repeat its output verbatim, then add one short sentence stating whether the redaction applied. Do not explore the database or take further action.

!`bash "$HOME/.config/opencode/bin/redact-quota.sh" "$1"`
```

- [ ] **Step 2: Write `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.config/opencode/commands" "$HOME/.config/opencode/bin"
cp commands/redact-quota.md "$HOME/.config/opencode/commands/redact-quota.md"
cp redact-quota.sh "$HOME/.config/opencode/bin/redact-quota.sh"
chmod +x "$HOME/.config/opencode/bin/redact-quota.sh"
echo "installed /redact-quota to ~/.config/opencode"
```

- [ ] **Step 3: Verify install**

Run: `bash install.sh && test -x "$HOME/.config/opencode/bin/redact-quota.sh" && test -f "$HOME/.config/opencode/commands/redact-quota.md" && echo INSTALL-OK && "$HOME/.config/opencode/bin/redact-quota.sh" --help >/dev/null && echo HELP-OK`
Expected: `INSTALL-OK` `HELP-OK` exit 0.

- [ ] **Step 4: Commit**

```bash
git add commands/redact-quota.md install.sh
git commit -m "feat(commands): /redact-quota slash command and installer"
```

### Task 3: README, LICENSE, GitHub push

**Files:**
- Create: `README.md`, `LICENSE` (MIT, JetSet AI)

- [ ] **Step 1: Write README** — sections: what it does (pinned placeholder + target strings + tables touched), install (`git clone ... ; cd opencode-quota-redact ; ./install.sh ; opencode service restart`), usage (`/redact-quota`, `/redact-quota ses_xxx`, script flags `--dry`/`--help`, `OPENCODE_DB` override), how it works (session resolution order + JSON-safety), safety notes (no backups per design, run `opencode service restart` after editing a session that is currently open elsewhere; not an official OpenCode tool).

- [ ] **Step 2: Commit + create repo + push**

```bash
git add README.md LICENSE docs/
git commit -m "docs: README, MIT license, design + plan records"
gh repo create jetsetai/opencode-quota-redact --public --source=. --push --description "Slash command that redacts provider quota error text from OpenCode session transcripts"
```

- [ ] **Step 3: Verify**

Run: `gh repo view jetsetai/opencode-quota-redact --json name,visibility,url -q '.url' && git log --oneline -5 && git status --short`
Expected: printed URL, 3 commits, empty status.

## Self-review notes

- Spec coverage: session resolution, scoping, dry mode, JSON safety, install, push — all mapped to Task 1-3. Review-Focus items 1-5 each have a named assertion in Task 1 Step 1.
- No function-level interface exists to keep type-consistent; report strings are the shared contract and are pinned verbatim in Interfaces blocks.
- Proportion: plan is shorter than the script it will produce; bodies are pinned only where SQL/strings are consequential.
