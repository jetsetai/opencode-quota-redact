# opencode-quota-redact

A `/redact-quota` slash command for [OpenCode](https://opencode.ai/v2/) (v2) that
removes persisted provider-quota error text — e.g. the `Free usage limit reached.
Free models work in OpenCode...` message OpenCode stores in its session database —
from a session transcript, so it stops reappearing in the agent's context window.

Running it replaces every occurrence of the error text inside the target
session's rows with `Error E-XXXXXXXX` (a random 8-character code generated once
per run), leaving everything else untouched.

## What it replaces

In `~/.local/share/opencode/opencode.db` (SQLite), scoped to one session only:

- the long message `Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go`
- the short phrase `Free usage limit reached`
- in the `session_message` table (v2 sessions) and, as a guarded fallback, in the
  legacy `part`/`message` tables

The replacement string contains no quotes, backslashes, or newlines, so the JSON
stored in the `data` column stays valid. The script verifies this after editing
(`json_valid()`) and refuses sessions it cannot find.

## Install

```sh
git clone https://github.com/jetsetai/opencode-quota-redact.git
cd opencode-quota-redact
./install.sh
```

This copies the command to `~/.config/opencode/commands/redact-quota.md` and the
script to `~/.config/opencode/bin/redact-quota.sh` (made executable). Reload
OpenCode config if needed — OpenCode reloads command files automatically.

## Usage

In the OpenCode TUI, with the session whose context you want to clean up:

```text
/redact-quota
```

Targets the active session automatically when exactly one is running. To target
a specific session (also useful when several sessions are active):

```text
/redact-quota ses_xxxxxxxxxxxxxxx
```

Directly from the shell:

```sh
~/.config/opencode/bin/redact-quota.sh [ses_id] [--dry] [--help]
```

- No arguments: auto-detect via `opencode api get /api/session/active`, else fall
  back to that database's most recently updated session. The script always prints
  which session it targeted (`SESSION=<id> [source=arg|active-api|latest]`).
- `--dry`: report match counts (`DRY-RUN session_message=N part=N message=N`)
  without editing anything.
- `OPENCODE_DB` environment variable overrides the database path.

Report format after an edit:

```text
SESSION=ses_xxx [source=active-api]
APPLIED session_message=3 part=1 message=0
verified: json_valid=ok remaining=0
```

## How it works

`redact-quota.sh` runs two `UPDATE ... SET data = replace(data, ...)` passes per
table (long message first, short phrase second), each with a `WHERE` clause that
matches both the session id and its own exact target string. Because SQLite's
`changes()` counts matched rows rather than changed rows, the per-pass WHERE
keeps the two counts disjoint and their sum equals the number of changed rows.

Session ids are validated against `^ses_[A-Za-z0-9]+$` before interpolation into
SQL; the replacement string is quote-free by construction, so JSON validity can
only be verified, never broken.

## Safety notes

- **Not an official OpenCode tool.** It edits the SQLite database directly
  because OpenCode's public API provides no transcript-editing endpoints.
- **Back up first** if you care about the transcript history; the script does
  not create backups. The edits are session-scoped and placeholder-substitutions
  inside JSON string values, but originals are gone once committed.
- If the session whose transcript you edited is currently open, run
  `opencode service restart` afterwards so nothing serves a cached copy.

## License

MIT — see [LICENSE](LICENSE).
