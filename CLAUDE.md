# CLAUDE.md — cc-autodream

Operating notes for working on this repo. Read this before changing `bin/run.sh` or the prompts. The README is the user-facing pitch; this file is the stuff that bit us and the decisions behind the design, so future sessions don't re-derive them.

## What it is

A nightly two-layer pipeline that reads yesterday's Claude Code session transcripts and produces a ranked daily report.

- **Layer 1** (`prompts/SESSION_TRIAGE.md`, haiku, fanned out one per session): reads one transcript, writes one findings JSON.
- **Layer 2** (`prompts/PROMPT.md`, opus, single call): reads all findings JSONs, emits the report on stdout (run.sh captures it and writes `dreams/YYYY-MM-DD.md`). L2 has no file tools — no memory writes under OMP.
- `bin/run.sh` orchestrates both layers and everything around them.

## Session roots: one dir is not the corpus

The user runs several Claude config dirs at once (`~/.claude-nous`, `~/.claude-ds4`,
`~/.claude-sigint`, ...), each with its own `projects/` bucket. autodream used to scan
only `$HOME/.claude/projects`, so the nightly report silently stopped seeing the real
work — triage collapsed 132 → 7 → 8 → 1 sessions/night on 2026-08-03…06 purely because
the sessions had moved to the other buckets. The fix is multi-root scanning:

- `SESSION_ROOTS` (colon-separated) wins; else `PROJECTS_DIR` (single root, kept for
  compat); else autodetect every `$HOME/.claude*/projects` via `bin/root-probe.sh`,
  primary first. `run.sh` logs the resolved list every run.
- `WORK_BUCKET` stays keyed off the PRIMARY dir: lean workers run under the default
  config, so their AI-title stubs land in the default bucket — scanning extra roots
  does not change the isolation/wipe story.
- `root-choices.conf` remembers the per-folder index decision. install.sh runs
  root-probe with `--ask` on a TTY, `--default-index` otherwise, and writes the managed
  `SESSION_ROOTS` section to `config` (the awk in install.sh converges re-installs by
  dropping the old managed section first). The nightly run passes neither flag, so it
  never writes choices — unindexed roots are *reported* (`findings/<date>/unindexed-roots.txt`)
  instead, which is the "found a folder, ask the user" surface.
- Semantics: a folder is scanned iff it's `index` or the always-on primary. An *unasked*
  folder is held out of the report until the user decides — that's what the flag
  "found a folder we're not indexing" means, and scanning it would make the flag a lie.
  `--default-index` on install flips every unasked folder to `index` so a fresh install
  covers everything silently.
- Compatibility (verified 2026-08-07 against real files): claude-code-router wraps
  sessions in a `{"type":"queue-operation",...}` envelope before the normal records —
  `session-stats.sh`, `prune-self-sessions.sh`, and L1's prompt all key off
  `.type == "user"`, so the envelope is invisible to them. cc-ds4's transcripts are
  standard shapes under `projects/` (its `history.jsonl`/`spend-ledger.jsonl` live
  outside `projects/`, so the glob never trips on them). ccam keeps an accounts file,
  no transcript store. The `projects/`-bucket glob IS the compatibility layer.
- run-stats carries `session_roots` (count) + `session_roots_list` so a regression to
  single-root scanning is visible from the artifact.

## Where state lives

All under `$AUTODREAM_DIR` (default `~/.claude/autodream/`) except the reports:

- `findings/YYYY-MM-DD/*.json` — Layer 1 output, one per session (keyed by a 12-char sha1 of the session path). `*.json.err` is a worker's stderr on failure.
- `findings/YYYY-MM-DD/sessions.txt` (+ `.raw`) — the enumerated session list (`.raw` is pre-self-filter).
- `findings/YYYY-MM-DD/changelog-window.md` — upstream changelog diff for the date (see below).
- `findings/YYYY-MM-DD/run-stats.txt` — self-audit telemetry the aggregator reads.
- `findings/YYYY-MM-DD/operator-notes.md` — every capture surface's notes merged into the one file L2 reads. `vault-notes-manifest.txt` alongside it lists the inbox files that went into it.
- `findings/YYYY-MM-DD/x-bookmarks.md` — unread X bookmarks for the "Ideas from bookmarks" section, plus `x-bookmarks-manifest.txt` of their ids. `x-bookmarks/seen.jsonl` holds the persistent read state.
- `findings/YYYY-MM-DD/unindexed-roots.txt` — Claude folders (`~/.claude*/projects`) that exist but are not indexed, for the self-audit section. Written before the idempotency guard so a catch-up no-op still reports folders that appeared since setup.
- `root-choices.conf` — the per-folder index decision (`~/.claude-ds4/projects=index`), written by `bin/root-probe.sh` at install time. The primary `~/.claude/projects` is always indexed.
- `cache/claude-code/` — persistent clone of `anthropics/claude-code` for the changelog.
- `logs/run-YYYY-MM-DD.log` — full run log (run.sh tees here). `logs/launchd.{out,err}.log` — launchd's capture.
- `dreams/YYYY-MM-DD.md` (default `~/.claude/dreams/`) — the final report.

Scripts/prompts are symlinked into `~/.claude/autodream/` by `install.sh`, so editing the repo copy takes effect immediately. The installed launchd job is `com.samuelreed.autodream` (not the `com.user.*` example label).

`install.sh` also installs that scheduled job by default (unless `--no-schedule`): it generates the plist with auto-detected label/PATH/dirs (same detection as `autodream-now.sh` — reuses an existing `*autodream*` plist's label if present, else synthesizes `com.<user>.autodream`), then `bootout`+`bootstrap`s it. `RunAtLoad` is false, so install *arms* the schedule without firing a run; the four morning triggers (03:15/06:15/09:15/12:15) match the example plist. It does not run `pmset` (sudo) — it only prints the `pmset repeat wake` recommendation. The `launchd/*.example` file is kept as a hand-editable fallback.

## How claude is invoked — the lean-query pattern (do not use `--bare`)

Both layers call `claude --print` with a composed set of minimal-footprint flags borrowed from claude-cells `internal/claude/query.go`. The point: strip per-call bloat (hooks, skills, MCP, CLAUDE.md auto-load) while KEEPING subscription/OAuth auth.

```
--no-session-persistence            # see self-pollution below
--tools Read Write                  # L1; L2 uses: Glob Read
--disable-slash-commands            # no skills
--strict-mcp-config                 # no MCP servers
--settings '{"disableAllHooks":true}'   # no hooks (incl. the big SessionStart injection)
```
plus env `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1`, and `--permission-mode bypassPermissions` so workers can write.

**Do NOT switch to `--bare` or `CLAUDE_CODE_SIMPLE=1`.** Verified (2026-05) with a control on this host: plain `claude --print` authenticates, but both `--bare` and `CLAUDE_CODE_SIMPLE=1` return "Not logged in". They disable OAuth/keychain auth and require `ANTHROPIC_API_KEY` (or an apiKeyHelper), and `--bare`'s toolset is only Bash+Edit (no Read/Write/Glob). The composed flags above give the same minimal footprint without breaking auth or the file tools. (claude-cells uses simple mode only inside containers, where creds are a mounted `.credentials.json` file, not the macOS keychain.)

## Self-pollution (the eating-its-own-tail bug)

Every `claude --print` call used to persist its own session JSONL into `~/.claude/projects/-Users-<you>/`. So a run that triaged ~190 sessions left ~190 worker transcripts, and the NEXT night's run enumerated those as "sessions" to triage. On a real day, ~90% of the corpus was autodream looking at itself (215 enumerated vs. 21 real on 2026-05-29).

Three defenses, all in place:
1. **Root cause**: `--no-session-persistence` on every call. New runs leave no transcript.
2. **Enumeration filter**: after `find`, the session list is piped through `bin/prune-self-sessions.sh --filter`, which drops any session whose first user turn is one of autodream's own inlined prompts (markers: `Session transcript to analyze (literal absolute path)`, `Findings directory to aggregate (literal absolute path)`, legacy `SESSION_PATH=` / `FINDINGS_DIR=`). This catches transcripts left by runs predating the fix.
3. **Backlog cleanup**: `bin/prune-self-sessions.sh` (dry-run lists, `--delete` removes). `prune-self-sessions.sh` is the single source of truth for the "is this ours?" predicate; run.sh resolves it relative to itself (`BASH_SOURCE`).

The predicate is anchored to the FIRST user message so a human session that merely *discusses* autodream is not a false positive.

### The AI-title stub vector (second-order self-pollution)

`--no-session-persistence` suppresses the full transcript but NOT Claude Code's **AI-title generation**: a fire-and-forget background call that writes a one-line `{"type":"ai-title",...}` stub into the launch cwd's project bucket. Because workers ran from `cd "$HOME"`, those stubs landed in the real `-Users-<you>` bucket and polluted session history / `search-sessions` — 339 of them accumulated 2026-05-25…06-02 (titles like "Analyze Claude session findings", "Aggregate daily findings into report"). Whether a stub lands is version/timing-dependent (the `--print` process sometimes exits before the async write flushes — current builds often drop it, older ones flushed it), so the fix must not assume the binary's current behavior.

Two defenses:
1. **cwd isolation + wipe (run.sh)**: both layers now launch from `$AUTODREAM_DIR/work` (`WORK_DIR`), not `$HOME`. Claude maps cwd → `~/.claude/projects/<cwd with / and . → ->`, so any stub lands in the isolated `WORK_BUCKET` instead of the real bucket. `clean_work_bucket` (`rm -rf "$WORK_BUCKET"`) runs before L1 and after L2, so stubs never accumulate. Workers read/write only by absolute path, so cwd is functionally irrelevant — L1 cd's inside the worker subshell; L2 cd's inside a subshell so the change does not leak into the notify step. **Watch the apostrophes**: the L1 worker body is a single-quoted `bash -c '...'`, so a `'` in a comment there silently breaks quoting (it still passes `bash -n`).
2. **Pruner title predicate (`is_self_title`)**: catches orphan stubs in the real bucket left by runs predating defense 1. Gated on (a) NO user turn anywhere in the file — a real session keeps its title alongside its conversation turns, so it is never a title-only orphan and is never matched — AND (b) the title paraphrases our L1/L2 prompts (session triage → findings, aggregate findings → report). Tuned against the real backlog: spares terminal-tab-title stubs and unrelated headless orphans (e.g. "GCU Rush firmware development").

## Sleep resilience

The overnight failure mode: launchd fires at the scheduled time on a brief wake, the Mac sleeps in and out during the run, workers lose the network and fail (we saw 104/215 fail, L2 exit 1, no report).

launchd facts: `StartCalendarInterval` is anacron-like (runs once on the next wake if asleep at the trigger), NOT vanilla cron. But launchd does not WAKE the Mac (use `pmset repeat wake` for that), and it does nothing about sleep DURING a run.

run.sh handles it with:
- **L1 retry loop** (`dispatch_l1` + `l1_missing_count`): re-dispatches only the sessions still missing a findings JSON, up to `AUTODREAM_L1_ROUNDS` (5), calling `wait_for_network` between rounds. The worker is idempotent, so retries are cheap.
- **L2 retry loop**: retries the aggregator up to `AUTODREAM_L2_ATTEMPTS` (3) until `$REPORT_PATH` is non-empty.
- **Idempotency guard**: at the top of `run()`, if a report already exists for the date it exits in a second (`AUTODREAM_FORCE=1` to rebuild). This is what makes multiple launchd catch-up triggers safe.
- The plist example schedules several morning triggers (03:15/06:15/09:15/12:15) so a failed-overnight date gets retried on later wakes; the guard no-ops the rest.

`net_up` checks reachability of `api.anthropic.com` (any HTTP code beats `000`). Disable the wait with `AUTODREAM_NETCHECK=0` (tests set this).

### The logger could kill the run, and did (2026-08-02)

Every recovery path above assumes it gets to run. `run 2>&1 | tee -a "$RUN_LOG"` quietly revoked that assumption for all of them at once: it made each log line a write to a pipe, so whatever killed `tee` killed the run by SIGPIPE on the next `log` call. Three runs died there on 2026-08-02 — two scheduled, one detached, so launchd was not the cause — and 2026-08-01 ended with no report at all. The signature is a run log that stops mid-sentence at `L2 aggregation attempt 1/3...` and a `Terminated: 15` on tee beside a `Broken pipe: 13` on run in the launchd stderr. Nothing else says anything, because the thing that would have said it is what died.

The fix is that an unattended run writes to the file directly (a file has no reader to lose) and `trap '' PIPE` covers the interactive path, where `tee` is still worth having. A closed terminal now costs the run its output rather than its life. `test_dead_stdout_does_not_kill_the_run` pins it by piping a real run into a reader that closes immediately.

What still has no root cause is who SIGTERMs `tee`. It was not `claude --print` signalling its process group (tested directly: a sibling `sleep` survives a worker call), it was not sleep (`pmset -g log` shows the Mac awake), and it was not launchd (the detached run died the same way). The run no longer cares, which is the point, but the signal source is worth naming if it ever shows up somewhere that does.

## Upstream changelog window

`changelog_window()` clones/pulls `anthropics/claude-code` into `cache/claude-code` and runs `git log -p` on `CHANGELOG.md` over `[TARGET_DATE, NEXT_DATE)` (real commit dates; the raw CHANGELOG has no dates, the git history does). The inserted lines go to `changelog-window.md`, which L2 reads for the "Upstream Claude Code changes" report section. Any git failure writes a note and never aborts the run. There is no remote `git blame`; that is why we keep a persistent local clone.

## Operator notes: one file for the prompt, many surfaces for the human

`PROMPT.md` reads exactly one notes path, `findings/<date>/operator-notes.md`, and `bin/vault-notes.sh` writes it by merging every capture surface. Adding a surface is a change to that script and never to the prompt. Today there are two:

- `~/.claude/autodream/notes.md`, appended by `autodream-note.sh`. Terminal-only, unchanged, still the right thing for an agent leaving itself a note mid-session.
- `$AUTODREAM_VAULT_DIR/inbox/*.md`, one file per note. This is the surface that gets used away from the keyboard — Obsidian mobile, Shortcuts, a share sheet, anything that writes a file into a synced folder. Optional YAML frontmatter `expires: YYYY-MM-DD`; expired notes are dropped at collect time so the prompt keeps exactly one expiry format to parse (the `- [added] (expires DATE)` lines).

Consumed inbox files move to `processed/<date>/` and the report is copied to `reports/<date>.md` for phone reading. Both steps are gated on a **non-empty** report, deliberately stricter than the `-f` check that encloses them: archiving a note the aggregator never read destroys the only copy, silently and unrecoverably. The manifest exists for the same reason — `collect` records which files it read and `archive` moves only those, so a note written during the ten minutes a run takes is not swallowed unread.

The vault lives in iCloud, which evicts file contents under storage pressure and leaves a `.<name>.icloud` placeholder. 03:15 is exactly when nothing has touched the vault for hours, so `materialize()` calls `brctl download` and waits for the placeholders to clear (`AUTODREAM_ICLOUD_WAIT`, default 30s). A note still dataless after the wait is written into `operator-notes.md` as `UNREADABLE` and left in the inbox rather than skipped — a note the user wrote and we could not read is worth saying out loud.

### run.sh sources the config now

It didn't until this feature; only `review.sh` did, which was fine while every key was review-only and stopped being fine the moment `AUTODREAM_VAULT_DIR` had to reach the nightly run. Two details in that block are load-bearing and both were caught by tests rather than by reading:

- **`set -a` around the source.** The helper scripts are separate processes, so a config key that stays an unexported shell variable reaches nothing. Without it the config parses fine and the feature silently does not happen.
- **The `export -p` snapshot replayed after.** The config uses plain `KEY=value`, so a bare `.` lets the file clobber a variable the caller deliberately exported. Tests set env; a run invoked with an explicit `AUTODREAM_VAULT_DIR=` to disable the vault has to actually disable it.

`AUTODREAM_DIR` is resolved before the source and therefore cannot be set from the config. That is not an oversight — it names the file's own location.

### What the consume gate actually has to check (PR #37 review)

"Only consume after a real report" turned out to need three conditions, not one. A review found the first version satisfied by things that are not a real report at all:

- **`-s "$REPORT_PATH"` is not proof this run wrote it.** Under `AUTODREAM_FORCE=1` the idempotency guard is bypassed while the *previous* run's report is still on disk, and nothing ever truncates that path. A sleep-killed L2 then left the old file standing, which both broke the retry loop out after one attempt and let the consume step archive an unread note. The fix is to move an existing report aside *before* the L2 loop, so the path being non-empty means what the code always assumed it meant. The copy is kept and logged on failure, discarded on success so `--force` doesn't litter `.stale-<epoch>` files forever.
- **The date matters.** Both collectors are date-agnostic — they read the *current* inbox and the *currently* unread bookmarks regardless of which date's findings dir they write into. Reprocessing an old date therefore consumed today's pending input. Consuming is now gated on `TARGET_DATE` matching the date a normal nightly run would process. `AUTODREAM_CONSUME_DATE` overrides that authoritatively, because the suite pins a fixed historical date and without the override every archive assertion would pass while testing nothing.
- **Publishing is not consuming.** Copying the report into the vault stays outside the date gate; only `archive` and `mark-read` destroy the user's only copy.
- **A failed move-aside must disarm consuming, not warn.** The first version logged a warning and carried on when the `mv` failed, which puts you back in exactly the state the move exists to prevent: a stale report at `$REPORT_PATH` that a failed L2 lets both the retry loop and the consume gate mistake for fresh output. `CONSUME_SAFE=0` turns the whole consume phase off for that run. A guard whose failure path continues is not a guard.

The copies those moves leave behind are retired by one block that sits *outside* the `-f "$REPORT_PATH"` test, and it has to (#40). A successful `.partial-*` move deletes that path, so anything nested under that test was skipped in exactly the outcome where the user most needs to be told where their last good report went. A complete report supersedes every `.partial-*` for its date, including ones from earlier nights, since a partial is a prefix of a report that now exists in full.

Credentials never go in `argv`. `-H "cookie: auth_token=…"` puts a full account-takeover token in the process list for the life of the request, readable by anything running as the same user, and the nightly run makes several of these unattended. `x-bookmarks.sh` writes them to a 0600 `curl --config` file inside the per-run `$TMP` that the EXIT trap removes.

`materialize()` calls **both** `brctl download` and `fileproviderctl materialize`. `brctl` predates the FileProvider migration and on current macOS often succeeds while doing nothing, which would silently reduce the iCloud wait to a passive timeout dressed up as a fetch.

### Bash traps this feature hit, all of them silent

Each of these passed a smoke test and failed in a way that produced no error:

- **`$(grep -c ... || echo 0)` yields `"0\n0"`.** `grep -c` prints `0` *and* exits 1 on no match, so the fallback fires too. The arithmetic that follows then dies under `set -e`. Triggered by a `notes.md` holding only its header — exactly what the user is left with after deleting notes a report said were addressed.
- **A variable set inside `$(...)` never comes back.** `fail()` assigned `FAIL_REASON` from inside nested command substitutions (`qid=$(get_query_id)` → `qid=$(detect_query_id)`), so the cookie-expiry remediation text died with the subshell and the report said a fetch failed for no reason. The reason now goes to a file, which crosses the boundary.
- **An iCloud-evicted file is not a zero-byte file.** macOS replaces it outright with a dot-prefixed `.<name>.icloud` placeholder, so a `-name '*.md'` walk matches *nothing* and the unreadable-note branch was unreachable for the only case it existed for. Placeholders get their own pass and are never manifested, so the note stays in the inbox to retry.
- **Sourcing a user-edited config under `set -u` kills the shell.** Not the source — the shell, so `|| echo WARNING` cannot fire. `run.sh` now probes the config in a throwaway subshell purely to capture bash's own error naming the bad variable, then sources for real with nounset off. Both helper scripts need the same guard; fixing only `run.sh` left them dying instead.
- **`mv` across filesystems is a copy, not a rename.** State staged in `$TMPDIR` and moved onto `$STATE_DIR` was never the atomic swap its comment claimed. Stage in the destination directory and gate the `mv` on the staging copy having succeeded.

## X bookmarks as idea fuel

`bin/x-bookmarks.sh` fetches recent bookmarks into `findings/<date>/x-bookmarks.md`; `PROMPT.md`'s "Ideas from bookmarks" section crosses them against the day's findings. The section's whole value is the intersection, so the prompt is explicit that a bookmark with no connection to this run gets left out and "none connected" is a correct answer — otherwise the model manufactures links and the section becomes a reading list the user already read.

The official API is not an option: `GET /2/users/:id/bookmarks` has never been on the free tier and needs Basic at $200/mo (checked 2026-08-02). So it reads X's internal web GraphQL endpoint with cookies pasted once into `$AUTODREAM_DIR/x-credentials`. The queryId in that endpoint's path rotates on X deploys, which is why the script scrapes it from the live JS bundle and caches it rather than hardcoding one.

Two invariants keep this from ever costing a night's report: the script always exits 0, and it always writes its output file — including a "not configured" stub and a `# x-bookmarks: fetch failed — <reason>` header. `mark-read` runs only after a non-empty report, same reasoning as the note archive above: a bookmark stamped read by a run that produced nothing is a bookmark the user never gets an idea from.

The queryId walk against X's JS bundle stays untested, and #38 closed on that rather than on a fixture. A fixture would assert that our regex matches a string we wrote, and would keep passing on the only day it mattered — the day X changes its chunk naming. A live canary was rejected too: it buys a few hours of notice over the nightly report, at the cost of an unattended job hitting a third party on a schedule. What shipped instead is `x_queryid_source` in `run-stats.txt` (`fresh` / `cache` / `failed` / `not_attempted`), because the one state nothing could see was `cache` — the fetch works, so the walk looks fine, while it may have rotted at any point since the last `fresh`. `x-bookmarks.sh` stamps it on every path via a file rather than a variable, for the reason the whole script does: `get_query_id` runs inside a command substitution.

`bin/cookie-cadence.sh` (#39) answers how long a pasted cookie pair lasts, which is what decides whether automating the capture is worth its moving parts. Same shape as `oversized-gate.sh`: it recomputes from the `x-bookmarks.md` headers already on disk, makes no model calls, reads no credentials, and is safe to re-run. Two things in it are load-bearing rather than decorative. It counts only the 401/403 rejection and the login-page redirect as expiries — a dead network or a missing jq says nothing about the cookies, and folding those in would make a yearly chore read as a weekly one with no visible sign of the error. And a stretch of working nights with no expiry at the end of it is right-censored, so it is reported as a lower bound and never as a lifetime.

## Self-audit

run.sh writes `run-stats.txt` (raw/excluded/triaged counts, L1 rounds/done/missing/err, elapsed). PROMPT.md's "Autodream self-audit" section reads it and is told to flag self-pollution regressions (excluded count climbing), pipeline-capacity problems (oversized transcripts that blow the token budget), retry/sleep health, and to propose concrete cc-autodream source fixes since the user authors the tool. It proposes; it does not edit cc-autodream source.

### Degraded measurements must say so, not read as zero

Two counters exist only to keep a broken measurement from looking like a real result, and any new stat should follow the same rule. `overlap_measured: yes|no` (#26) marks whether the cross-session overlap pass actually ran. `stats_sidecars_unparseable: N` (#27) counts sessions whose `*.stats.json` sidecar was missing, empty, or had no numeric `transcript_bytes`.

The sidecar counter is deliberately one number rather than a flag per stat: a broken sidecar degrades several counters at once (the noise gate and the oversized gate both read the same file), so the failure is counted once and PROMPT.md caveats the affected keys. The oversized loop walks `sessions.txt` rather than the `*.stats.json` glob — a sidecar that was never written is absent from the glob, and the session it belonged to used to vanish from `oversized_total` silently. Sizes for those sessions fall back to `wc -c` on the transcript itself, which is exactly what `transcript_bytes` holds anyway, so the #12 gate keeps a truthful number instead of a clamped 0.

The noise gate's own sidecar read still biases to triage on an unparseable sidecar and that stays — the cost is one wasted model call. What was missing there was never the behavior, only the signal.

### Nobody was told (`unassembled_dates`)

A run killed during L2 leaves a complete findings dir and no report, and every surface that would have said so is downstream of the death: `notify.sh` never runs, so there is not even a quiet banner. The catch-up triggers cannot cover it either, because launchd will not start a second instance of a label that is already running — a run slow enough to span its own catch-up window converts those triggers into nothing at all. 2026-07-26 sat unassembled for two days and was found during an unrelated investigation; 2026-08-01 repeated it.

`unassembled_dates()` sweeps the trailing week at the top of `run()` — deliberately *above* the idempotency guard, so a catch-up trigger that no-ops for today still reports older abandoned dates. It lists dates holding findings JSONs (sidecar-only dirs were never triaged and are not failures) whose report is missing or marker-less, and the result goes to the log and to `run-stats.txt`, which puts it in the next morning's report. The data was never the problem: `autodream-now.sh <date>` rebuilds one in minutes because the findings survive and it skips straight to L2.

### Which code actually ran (`runner_commit`)

`install.sh` symlinks `~/.claude/autodream/*.sh` straight at the repo working tree, so the nightly executes whatever is checked out at 03:15. A tree behind origin runs old code even though the fix is merged and the PR is green. This has cost data twice: the 2026-07-24 `overlap-stats.sh` dangle, and a tree stuck on a local commit from 2026-07-20 to 2026-07-24 that wrote four nights of `run-stats.txt` with no `oversized_*` / `gated` / `overlap_*` keys at all.

`run-stats.txt` therefore carries `runner_commit` + `runner_dirty` (#29). The diagnostic that matters: a `run-stats.txt` that is *missing keys*, rather than holding suspicious values, means an old runner — not a stat that didn't apply. Both times it took a reflog dig to establish that.

`bin/oversized-gate.sh` exists because of the same incident. The #12 gate is a trailing-window judgment but `run.sh` records one night at a time, so a stretch of old-runner nights used to be unrecoverable. It recomputes the window from the `*.stats.json` sidecars and findings JSONs still on disk, which survive independently of whether the runner knew how to count them. Artifacts only, no model calls, safe to re-run. It refuses to call an empty window a measured 0%, and quotes a rule-of-three upper bound so a clean run isn't read as stronger evidence than the sample supports.

## Running / rerunning a date

```
~/.claude/autodream/run.sh 2026-05-29        # process a date
AUTODREAM_FORCE=1 ~/.claude/autodream/run.sh 2026-05-29   # rebuild despite an existing report
```
To reprocess cleanly (e.g. after the corpus changed), delete that date's findings dir AND report first, then run; otherwise idempotency reuses old findings and the guard skips. Env knobs are documented in `run.sh`'s header and the README.

### Running on-demand without the 10-min cap (`autodream-now.sh`)

A full run routinely exceeds 10 minutes, so launching `run.sh` from a foreground/background context that has a time cap (a Claude Code background Bash task, an ssh session that may drop) gets it killed mid-flight. `bin/autodream-now.sh` sidesteps this by handing the run to **launchd**, which owns the process — no time cap, survives the caller disconnecting.

```
~/.claude/autodream/autodream-now.sh                  # yesterday, now
~/.claude/autodream/autodream-now.sh 2026-05-29 --force   # specific date, rebuild
~/.claude/autodream/autodream-now.sh 2026-05-29 --watch   # tail run log until report lands
~/.claude/autodream/autodream-now.sh 2026-05-29 --dry-run # print plist + commands, run nothing
```

How it works: it writes a transient one-shot LaunchAgent (`<base-label>.ondemand`, `RunAtLoad`) into `$AUTODREAM_DIR`, `bootout`s any prior instance, then `bootstrap`s it so launchd runs `run.sh <date>` once and the job exits. `RunAtLoad` is the *only* trigger — it deliberately does not also `kickstart`, or a fast run (e.g. the idempotency no-op) would fire twice. It never touches the scheduled nightly job. Everything is auto-detected: it resolves its own symlink to find `run.sh`, picks the scheduled plist whose `ProgramArguments` reference `run.sh` (not the sibling `*-review` job) to borrow its label namespace, and detects uid + the `claude`/`git` dirs for the agent's PATH — so it is not specific to one user or host. The default date is computed with plain `date -v-1d`, exactly like run.sh (no TZ override). `--force` maps to `AUTODREAM_FORCE=1`; the caller's `AUTODREAM_DIR`/`DREAMS_DIR` are passed through. Progress is in `$AUTODREAM_DIR/logs/run-<date>.log`; the agent's own stdout/stderr go to `logs/ondemand.{out,err}.log`.

When you (the agent) need to kick off a run, prefer this over a background Bash task — fire it, then poll `dreams/<date>.md` instead of holding a long task open.

## Reviewing changes here

Almost everything in this repo is shell, and a shell bug here fails silently on a
nightly cron nobody is watching. `/code-review` is a fine first pass but it is not the
gate. Before merging any change to `run.sh`, `bin/*.sh`, `install.sh`, the launchd
plists, or the prompts, also run `/debate:run tight` — that preset is Codex + Gemini +
DeepSeek, so at least one seat does not share Claude's blind spots.

This is not a hypothetical. PR #37 (merged 2026-08-02) was reviewed by a fanout of 30+
Claude verifier subagents. They found 18 real defects, which is the case for the fanout.
But ten of those verifiers issued verdicts quoting `file:line` they had never read, and
three of them accused a sibling of fabricating citations while fabricating their own.
Adding more Claude seats does not catch that, because every seat fails the same way.
A different vendor does.

DeepSeek direct retains prompts and trains on them. That is fine for this repo, which is
public. For private code, swap the seat rather than skipping the pass.

## Tests

`tests/run-all.sh` drives the real `run.sh` against `tests/mock-claude.sh` (no network, no model). Mock modes: `good` (default), `l1_incomplete` (worker writes nothing), `l1_flaky` (fails first dispatch per session, succeeds on retry). The suite forces `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0` and a low `AUTODREAM_L1_ROUNDS` so it never sleeps or hits the network. macOS only (BSD `date`/`touch`). Run it after any run.sh/prompt change.

The suite pins `AUTODREAM_CONFIG` into its sandbox now that `run.sh` sources the config. Without that pin, a developer whose real config points `AUTODREAM_VAULT_DIR` at a live Obsidian vault would have the test suite writing notes and reports into it. `MOCK_MODE=l2_fail` makes the aggregator write nothing and exit 1, which is how the "don't archive an unread note" guard is tested; pair it with `AUTODREAM_L2_ATTEMPTS=1` so the test doesn't sit through the retry loop.

`tests/x-bookmarks.sh` covers the bookmark fetcher with `curl` shimmed and the queryId cache pre-seeded, so nothing touches X. The bundle-scraping walk is untested on purpose — it runs against a live third party and a fake proves nothing about it. Everything downstream of the HTTP call is pinned hard, because that is where both development bugs lived: the emit came out oldest-first (it trusted file order, which is only chronological within one run), and `mark-read` silently no-opped on every row (`$ids | index(.id)` rebinds `.` to the array before `.id` is read, so it indexed an array with a string). Neither showed up in a smoke test and both would have quietly wasted the feature.

`tests/cookie-cadence.sh` pins `bin/cookie-cadence.sh`'s classification against every header shape the fetcher writes. Fixtures rather than a smoke test, because a misclassification produces a number that looks exactly as authoritative as a correct one.

`tests/review-skip.sh` covers `bin/review.sh`'s skip/launch decision against fixture reports, with an inline mock claude that just touches a marker file — if the marker exists, review.sh reached `exec claude`. It pins `AUTODREAM_CONFIG` to a nonexistent path so the host's own config (`AUTODREAM_TRIAGE_SURFACE=cmux`) can't leak in and spawn a real workspace mid-test. Run it after any review.sh change, and after changing PROMPT.md's Open-questions marker contract.

## Gotchas (host environment)

- The user's shell rewrites `grep` to `rtk grep`, which rejects some flags (`-h`); prefer `tail`/`rg`-style invocations when scripting against logs interactively.
- The Claude Code sandbox denies writes under `~/.claude/` (including `rm` of symlinks/findings); those operations need the sandbox disabled.
- Subagent transcripts live in `projects/.../<session>/subagents/agent-*.jsonl` and ARE legitimate sessions to triage; they are not self-pollution.
- `claude --print` worker calls run from cwd `$HOME`, so any transcript they (used to) leave landed in the `-Users-<you>` project bucket.
