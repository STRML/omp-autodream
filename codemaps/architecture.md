# Codemap — architecture

Token-lean map of cc-autodream. See `CLAUDE.md` for the decisions and gotchas behind it.

## Data flow

```
launchd (com.samuelreed.autodream, several morning triggers)
      │
      ▼
bin/run.sh  TARGET_DATE
      │
      ├─ idempotency guard: report exists for date? → exit 0 (unless AUTODREAM_FORCE=1)
      │
      ├─ probe_roots: resolve SESSION_ROOTS (env/config | PROJECTS_DIR | root-probe autodetect)
      │     └─ write findings/<date>/unindexed-roots.txt (folders found but not indexed; before guard)
      ├─ enumerate: find *.jsonl in [TARGET_DATE, NEXT_DATE) per root → sessions.txt.raw (sort -u)
      │     └─ prune-self-sessions.sh --filter                → sessions.txt   (drops autodream's own)
      │
      ├─ L1 retry loop (AUTODREAM_L1_ROUNDS):
      │     dispatch_l1: xargs -P FANOUT → claude --print (haiku, lean flags) per session
      │       reads session .jsonl, writes findings/<date>/<sha>.json   (idempotent; .err on fail)
      │     l1_missing_count → wait_for_network → retry the still-missing
      │
      ├─ run-stats.txt          (self-audit telemetry)
      ├─ changelog_window()      → findings/<date>/changelog-window.md  (git log -p on claude-code CHANGELOG)
      │
      ├─ L2 retry loop (AUTODREAM_L2_ATTEMPTS):
      │     claude --print (opus, lean flags) with PROMPT.md
      │       reads all findings/<date>/*.json + changelog-window.md + run-stats.txt
      │       writes dreams/<date>.md (no memory writes — L2 does not edit MEMORY.md under OMP)
      │
      ├─ notify.sh → open-questions inbox file ($AUTODREAM_OPEN, default `open`)
```

## Files

| File | Role |
|---|---|
| `bin/run.sh` | orchestrator: guard, enumerate+filter, L1 retry loop, changelog, L2 retry loop, notify |
| `bin/autodream-now.sh` | run NOW via a transient one-shot launchd agent (escapes the ~10-min cap on bg tasks/ssh). `[DATE] [--force] [--watch] [--dry-run]`. RunAtLoad only (no kickstart → no double run); picks the scheduled plist that runs `run.sh` for its label namespace |
| `bin/prune-self-sessions.sh` | self-session predicate (single source of truth): list / `--delete` / `--filter` |
| `bin/oversized-gate.sh` | recompute the #12 measurement gate over a trailing window from the sidecars/findings on disk (`--days N`, or explicit findings dirs). Recovers dates whose `run-stats.txt` predates the counters; artifacts only, no model calls |
| `bin/root-probe.sh` | detect the `~/.claude*/projects` buckets and decide which to index. `--consolidated`/`--unindexed`/`--list` (read-only, nightly), `--ask`/`--default-index` (install-time; writes root-choices.conf + the managed `SESSION_ROOTS` config section). Artifacts only, no model calls |
| `bin/notify.sh` | extract "Open questions" → inbox file, counted from the `open-questions=N` marker, opened via `$AUTODREAM_OPEN` |
| `bin/review.sh` | interactive morning triage (`claude --append-system-prompt <report>`); `AUTODREAM_TRIAGE_SURFACE=cmux` (config/env) launches it in its own cmux workspace instead of inline. Skips the session entirely (prints a notice) when the report has 0 open questions or is already triaged — reads the `<!-- autodream:open-questions=N -->` marker, falls back to prose, launches on anything ambiguous; `--force` overrides. Skip check runs before the cmux branch so a skip never spawns a workspace |
| `prompts/SESSION_TRIAGE.md` | L1 prompt: per-session JSON schema |
| `prompts/PROMPT.md` | L2 prompt: report sections incl. Upstream changes + Autodream self-audit |
| `tests/run-all.sh` | integration tests for `run.sh` vs `mock-claude.sh` (offline) |
| `tests/review-skip.sh` | tests for `review.sh`'s skip/launch decision (offline; inline mock claude) |
| `tests/mock-claude.sh` | stand-in claude; modes: good / l1_incomplete / l1_flaky |
| `launchd/com.user.autodream.plist.example` | schedule (multi-trigger catch-up + pmset note) |
| `install.sh` | symlink scripts/prompts into `~/.claude/autodream/`; by default also generates + bootstraps the nightly launchd schedule (auto-detected label/PATH/dirs; `--no-schedule` to skip) |

## Key invariants

- L1 worker is **idempotent**: a session with a non-empty `<sha>.json` is skipped. Failures leave no JSON (retry target); deterministic errors (unreadable file) write a JSON (done).
- A `dreams/<date>.md` exists only after a successful L2 → it is the "done" signal for the idempotency guard.
- `prune-self-sessions.sh` matches only the FIRST user turn against autodream's own prompt framing → human sessions about autodream are not false positives.
- claude is always invoked with the lean flags + subscription auth; never `--bare`/`CLAUDE_CODE_SIMPLE` (breaks auth).

## Environment overrides

All optional; full list (with defaults) is documented in `bin/run.sh`'s header. The ones you reach for most:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_BIN` | `$HOME/.local/bin/claude` | path to `claude` CLI |
| `SESSION_ROOTS` | autodetected | colon-separated dirs to scan for session JSONLs (every `$HOME/.claude*/projects`). Wins over `PROJECTS_DIR` |
| `PROJECTS_DIR` | `$HOME/.claude/projects` | single root, kept for compat (one dir); `WORK_BUCKET` isolation is keyed off this |
| `AUTODREAM_DIR` | `$HOME/.claude/autodream` | scripts + runtime state |
| `DREAMS_DIR` | `$HOME/.claude/dreams` | where reports are written |
| `FANOUT` | `8` | L1 parallelism |
| `AUTODREAM_FORCE` | `0` | `1` rebuilds even if a report exists |
| `AUTODREAM_CHANGELOG` | `1` | `0` skips the upstream-changelog check |
| `CLAUDE_CODE_REPO` / `CHANGELOG_REMOTE` | cache dir / anthropics/claude-code | changelog clone source/cache |
| `AUTODREAM_L1_ROUNDS` / `AUTODREAM_L2_ATTEMPTS` | `5` / `3` | sleep-resilient retry bounds |
| `AUTODREAM_NETCHECK` / `AUTODREAM_RETRY_WAIT` | `1` / `60` | network-wait between retry rounds |
| `AUTODREAM_SLIM_BYTES` | `262144` | sessions larger than this are slimmed for L1 |
| `AUTODREAM_OPEN` | `open` | how `notify.sh` opens the inbox file; a `sh -c` snippet, so flags work (`subl`, `code -g`, `open -a Obsidian`). `SUBL` is a deprecated alias |
| `AUTODREAM_TRIAGE_SURFACE` | `inline` | `review.sh` triage surface: `inline` (current terminal) or `cmux` (own workspace) |
| `AUTODREAM_TRIAGE_FOCUS` | `false` | cmux surface only: `true` switches to the new workspace on launch, `false` opens it in the background |
| `CMUX_BIN` | `/Applications/cmux.app/.../bin/cmux` then PATH | cmux CLI, used when surface is `cmux` |
| `AUTODREAM_CONFIG` | `$AUTODREAM_DIR/config` | sourced KEY=VALUE config (env vars override it) |

## Lean queries / no self-pollution (see CLAUDE.md for full detail)

- Both layers call `claude --print` with composed lean flags (`--no-session-persistence --disable-slash-commands --strict-mcp-config --settings '{"disableAllHooks":true}'` + `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` …) — minimal footprint while keeping subscription/OAuth auth.
- `--no-session-persistence` stops workers leaving their own transcripts; the enumeration also pipes through `prune-self-sessions.sh --filter` to drop any left by older runs. Without this, ~90% of a night's corpus is autodream re-reading itself.
