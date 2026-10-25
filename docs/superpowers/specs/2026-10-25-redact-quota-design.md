# Short design: /redact-quota slash command (2026-10-25)

## Intent
Turn the manually-performed repair (removing "Free usage limit reached" provider
quota error text from an OpenCode session transcript in
`~/.local/share/opencode/opencode.db`) into a reusable `/redact-quota` slash
command that targets the active session by default.

## Background facts (verified live this session)
- `opencode db` is not a CLI subcommand; transcripts live in v2 tables:
  `session_v2` + `session_message` (text stored in the `data` JSON column).
  Legacy `part`/`message` tables exist; `part.text` does not exist.
- Live error blobs embed the long message in `error.message` and an escaped copy
  inside `error.response.body`.
- `/api/session/active` returns `{"data":{"<ses_id>":{"type":"..."}}}` for the
  currently-running session(s) — reliable "active session" detection.

## Goals
- `/redact-quota` (no args) redacts the active session; `/redact-quota ses_xxx`
  targets an explicit session; `--dry` reports counts without editing.
- Session-scoped SQL `replace()` edits, JSON-safe (quote-free placeholder
  `Error E-<random 8-char code>` (per user) ), post-check `json_valid()`.
- No backups (user standing directive); safety = scoping + simple replacements +
  integrity check.

## Non-goals
- Not a general transcript editor, service restarter, or quota-workaround.
- Not an official OpenCode tool; calls the sqlite DB directly because the public
  API has no transcript-editing endpoints (justified custom utility, no external
  dependencies beyond sqlite3/jq/bash).

## Approaches considered
1. **Inline one-liner SQL in the command markdown** — rejected: fragile quoting,
   no session validation, hard to test.
2. **Bash engine script + thin command template (chosen)** — testable, exact
   report strings, single place for session logic.
3. **OpenCode plugin with message hooks** — rejected: over-engineered for a
   fix-up utility; hooks run on every message write.

## Repo
`github.com/jetsetai/opencode-quota-redact`, public, MIT, main branch; local dir
`~/Documents/Dev/opencode-quota-redact`.
