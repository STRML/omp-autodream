#!/bin/bash
# Integration tests for cc-autodream's bin/run.sh.
#
# Drives the real run.sh end-to-end against a mock claude binary and fixture
# session files, then asserts on the output tree. No network, no model calls.
# macOS only (BSD `date`/`touch`), like the rest of the project.
#
# Usage:  tests/run-all.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
RUN="$REPO/bin/run.sh"
MOCK="$HERE/mock-claude.sh"
OMP_MOCK="$HERE/mock-omp.sh"
DATE=2020-01-02          # fixed target date; sessions are touched into this day
STAMP=202001021200       # touch -t form of DATE at noon

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_file(){     [ -f "$1" ] && ok "$2" || no "$2 (missing: $1)"; }
assert_no_file(){  [ ! -e "$1" ] && ok "$2" || no "$2 (unexpected: $1)"; }
assert_nonempty(){ [ -s "$1" ] && ok "$2" || no "$2 (empty/missing: $1)"; }
assert_grep(){     grep -q "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){   grep -q "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }
assert_eq(){       [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# Fresh sandbox: projects/ (session inputs) + autodream/ (prompts + state) + dreams/.
setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/proj-a" "$root/autodream" "$root/dreams" "$root/cap"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$root/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$root/autodream/PROMPT.md"
  printf '%s' "$root"
}
mk_session(){ # $1=root $2=name
  # Two real user turns (no timestamps -> duration_minutes 0, uncomputable and
  # so exempt from the duration gate rule) so this fixture clears the noise
  # gate's default AUTODREAM_MIN_USER_TURNS=2 floor and every existing test
  # that expects real L1 triage keeps getting it. OMP transcript shape
  # (PORT_CONTRACT.md): message records + custom tool_execution_start.
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"start the task"}]}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"keep going"}]}}' \
    '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Read","intent":"read"}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_trivial_session(){ # $1=root $2=name — single user turn, no tool calls: below the noise gate
  local f="$1/projects/proj-a/$2.jsonl"
  printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"quick question"}]}}\n' > "$f"
  touch -t "$STAMP" "$f"
}
mk_short_duration_session(){ # $1=root $2=name — 2 user turns, 5s apart: gates on duration alone
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"message","timestamp":"2026-07-20T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"quick check"}]}}' \
    '{"type":"message","timestamp":"2026-07-20T10:00:05Z","message":{"role":"user","content":[{"type":"text","text":"thanks bye"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_subagent_session(){ # $1=root $2=name — isSidechain + >=5 tool calls: carve-out, never gated
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"message","timestamp":"2026-07-20T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"subagent task"}]}}' \
    '{"type":"custom","customType":"agent","data":{},"timestamp":"2026-07-20T10:00:01Z"}' \
    '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Read"},"timestamp":"2026-07-20T10:00:02Z"}' \
    '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Write"},"timestamp":"2026-07-20T10:00:03Z"}' \
    '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Bash"},"timestamp":"2026-07-20T10:00:04Z"}' \
    '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Grep"},"timestamp":"2026-07-20T10:00:05Z"}' \
    '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Edit"},"timestamp":"2026-07-20T10:00:06Z"}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_timed_session(){ # $1=root $2=name $3.. = ISO8601 timestamps, one user turn each (#14 overlap fixtures)
  local root="$1" name="$2"; shift 2
  local f="$root/projects/proj-a/$name.jsonl" ts
  : > "$f"
  for ts in "$@"; do
    printf '{"type":"message","timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"turn"}]}}\n' "$ts" >> "$f"
  done
  touch -t "$STAMP" "$f"
}
hash_of(){ printf '%s' "$1" | shasum -a 1 | cut -c1-12; }
run_dream(){ # $1=root ; inherits MOCK_MODE/MOCK_CAPTURE_DIR/FANOUT + changelog knobs from env
  # Changelog check defaults OFF so the suite never touches the network; the dedicated
  # changelog test exports AUTODREAM_CHANGELOG=1 with a local CHANGELOG_REMOTE.
  # Retry/network knobs forced fast+offline so the suite never sleeps or hits the net.
  # AUTODREAM_CONFIG is pinned into the sandbox so the HOST's own
  # ~/.claude/autodream/config can never leak in. run.sh started sourcing that file so
  # AUTODREAM_VAULT_DIR could reach the nightly run; without this pin a developer whose
  # config points at a real Obsidian vault would have the suite writing into it.
  # Individual tests override this by exporting AUTODREAM_CONFIG before calling.
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG="${AUTODREAM_CHANGELOG:-0}" OMP_BIN="$MOCK" \
  AUTODREAM_CONFIG="${AUTODREAM_CONFIG:-$1/autodream/config}" \
  AUTODREAM_CONSUME_DATE="${AUTODREAM_CONSUME_DATE:-$DATE}" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS="${AUTODREAM_L1_ROUNDS:-2}" \
  PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  # An unattended run logs to its file rather than through a pipe, so that stdout carries
  # only a pointer now. Fold the real log in, so every assertion below still reads what a
  # nightly run actually recorded rather than what a tty run happens to echo.
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
}
# Same run, but piped into a reader that closes immediately, so any write run.sh makes to
# stdout lands on a dead pipe. This is the shape of the real 2026-08-02 failure.
run_dream_broken_pipe(){ # $1=root
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_CONFIG="$1/autodream/config" \
  AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  bash "$RUN" "$DATE" 2>&1 | true
  cat "$1/autodream/logs/run-$DATE.log" > "$1/run.out" 2>/dev/null || true
}
fdir(){ printf '%s' "$1/autodream/findings/$DATE"; }   # findings dir for a root

# ---------------------------------------------------------------------------

# ---- Operator notes: notes.md + vault inbox merged into operator-notes.md ----------
# The seam under test is that PROMPT.md reads exactly ONE file. Every assertion here is
# about that file's contents and about what leaves the inbox, because the two ways this
# feature fails silently are (a) a surface not reaching the model and (b) a note being
# archived before it was read.

mk_vault_note(){ # $1=root $2=name $3=body [$4=expires]
  local d="$1/vault/inbox"; mkdir -p "$d"
  {
    if [ -n "${4:-}" ]; then printf -- '---\nexpires: %s\n---\n' "$4"; fi
    printf '%s\n' "$3"
  } > "$d/$2.md"
}
vault_run(){ # $1=root — a run with the vault surface enabled
  AUTODREAM_VAULT_DIR="$1/vault" run_dream "$1"
}

test_notes_no_surfaces(){
  echo "# operator notes: no notes.md and no vault -> the file still exists, saying so"
  local root; root=$(setup_env); mk_session "$root" s1
  run_dream "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_file "$f" "operator-notes.md is written even with nothing to report"
  assert_grep "$f" "active: 0" "header reports zero active notes"
  assert_grep "$f" "No active operator notes" "body says there are no notes"
  rm -rf "$root"
}

test_notes_from_notes_file(){
  echo "# operator notes: notes.md lines reach the merged file verbatim"
  local root; root=$(setup_env); mk_session "$root" s1
  printf -- '- [2020-01-01] check whether /graphify is used\n' > "$root/autodream/notes.md"
  run_dream "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "check whether /graphify is used" "the note text is present"
  assert_grep "$f" "active: 1" "the line note is counted active"
  rm -rf "$root"
}

test_notes_from_vault_inbox(){
  echo "# operator notes: a vault inbox file becomes a note block"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" idea-from-phone "look at how often the retry budget fires"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "note: idea-from-phone" "the inbox file is titled by its filename"
  assert_grep "$f" "how often the retry budget fires" "the inbox note body is present"
  assert_grep "$f" "active: 1" "the inbox note is counted active"
  assert_nogrep "$f" "^expires:" "frontmatter is stripped from the body"
  rm -rf "$root"
}

test_notes_vault_expired_dropped(){
  echo "# operator notes: an expired vault note is dropped from the merged file but still archived"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" stale "this stopped mattering" 2020-01-01
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_nogrep "$f" "this stopped mattering" "expired note body is not shown to the model"
  assert_grep "$f" "expired-and-dropped: 1" "the expired note is counted in the header"
  assert_no_file "$root/vault/inbox/stale.md" "an expired note still leaves the inbox"
  rm -rf "$root"
}

test_notes_vault_archived_after_report(){
  echo "# operator notes: a consumed vault note moves to processed/<date>/"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" done-with-this "some note"
  vault_run "$root"
  assert_no_file "$root/vault/inbox/done-with-this.md" "the note left the inbox"
  assert_file "$root/vault/processed/$DATE/done-with-this.md" "the note landed in processed/<date>/"
  rm -rf "$root"
}

test_notes_vault_not_archived_without_report(){
  echo "# operator notes: a failed L2 (no report) leaves the note in the inbox"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" keep-me "must survive a failed run"
  # l2_fail makes the aggregator write nothing; the archive step is gated on a
  # non-empty report precisely so an unread note is never thrown away.
  export MOCK_MODE=l2_fail AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/keep-me.md" "the note stayed in the inbox after a failed run"
  assert_no_file "$root/vault/processed/$DATE/keep-me.md" "the note was not archived"
  rm -rf "$root"
}

test_notes_vault_report_published(){
  echo "# operator notes: the report is copied into the vault for phone reading"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"
  assert_nonempty "$root/vault/reports/$DATE.md" "the report was published into the vault"
  rm -rf "$root"
}

test_notes_vault_unreadable_note_stays(){
  echo "# operator notes: an empty (unsynced) note is reported, not silently skipped"
  local root; root=$(setup_env); mk_session "$root" s1
  mkdir -p "$root/vault/inbox"; : > "$root/vault/inbox/not-synced.md"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the unreadable note is counted"
  assert_grep "$f" "not-synced.md — UNREADABLE" "the unreadable note is named for the model"
  assert_file "$root/vault/inbox/not-synced.md" "an unread note is left in the inbox to retry"
  rm -rf "$root"
}

# ---- Config file: run.sh sources it, but the environment still wins ----------------
# run.sh ignored ~/.claude/autodream/config until AUTODREAM_VAULT_DIR needed to reach the
# nightly run. The env-wins half is the part worth pinning: the config uses plain
# KEY=value, so a naive `.` would let the file override a caller who deliberately
# exported something.

test_config_file_sourced(){
  echo "# config: AUTODREAM_VAULT_DIR set only in the config file reaches the run"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" from-config "config-sourced vault"
  printf 'AUTODREAM_VAULT_DIR=%s/vault\n' "$root" > "$root/autodream/config"
  run_dream "$root"
  assert_grep "$(fdir "$root")/operator-notes.md" "config-sourced vault" "the config-only vault path was used"
  rm -rf "$root"
}

test_config_env_wins_over_config(){
  echo "# config: an exported AUTODREAM_VAULT_DIR beats the config file's value"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" real "the env-chosen vault"
  mkdir -p "$root/decoy/inbox"
  printf 'the config-chosen vault\n' > "$root/decoy/inbox/decoy.md"
  printf 'AUTODREAM_VAULT_DIR=%s/decoy\n' "$root" > "$root/autodream/config"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep   "$f" "the env-chosen vault"    "the environment's vault was read"
  assert_nogrep "$f" "the config-chosen vault" "the config's vault was overridden"
  rm -rf "$root"
}

# ---- Regressions from the PR #37 review -------------------------------------------
# Every one of these had a reproducer in the review and no test. They are grouped here
# rather than merged into the tests above because each pins a specific way the feature
# lost the user's input silently.

test_notes_header_only_file_does_not_abort(){
  echo "# regression: a notes.md with no '- [' lines must not abort collect"
  local root; root=$(setup_env); mk_session "$root" s1
  # Exactly what autodream-note.sh leaves once the user deletes the notes a report told
  # them were addressed. `grep -c` prints 0 AND exits 1, so a `|| echo 0` fallback made
  # the count "0\n0" and the arithmetic killed the whole collect under set -e.
  printf '# Operator notes for autodream\n\nFree-text notes.\n\n' > "$root/autodream/notes.md"
  mk_vault_note "$root" survives "this note must still reach the model"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_file "$f" "operator-notes.md was still written"
  assert_grep "$f" "active: 1" "the vault note was still counted"
  assert_grep "$f" "this note must still reach the model" "the vault note still reached the model"
  rm -rf "$root"
}

test_notes_icloud_placeholder_is_counted(){
  echo "# regression: an iCloud placeholder is a missed note, not a clean zero"
  local root; root=$(setup_env); mk_session "$root" s1
  # An evicted note is NOT a zero-byte .md — the real file is gone and only the
  # dot-prefixed placeholder remains, so the '*.md' walk matched nothing at all.
  mkdir -p "$root/vault/inbox"; : > "$root/vault/inbox/.from-phone.md.icloud"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the evicted note is counted, not reported as zero"
  assert_grep "$f" "from-phone.md — UNREADABLE" "it is named so the user knows what was missed"
  assert_file "$root/vault/inbox/.from-phone.md.icloud" "the placeholder stays for the next run"
  rm -rf "$root"
}

test_notes_placeholder_and_real_file_counted_once(){
  echo "# regression: a materialised note with a leftover placeholder is not double-counted"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" both "the real content"
  : > "$root/vault/inbox/.both.md.icloud"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "active: 1" "counted as one active note"
  assert_grep "$f" "unreadable: 0" "not also counted as unreadable"
  rm -rf "$root"
}

test_notes_expiry_uses_report_date(){
  echo "# regression: expiry is judged against the reported date, not today"
  local root; root=$(setup_env); mk_session "$root" s1
  # Expires long after the date being reported on ($DATE) but long before today, so a
  # wall-clock comparison drops and archives a note that was active for this window.
  mk_vault_note "$root" still-active "active during the reported window" 2020-06-01
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "active during the reported window" "the note is still shown to the model"
  assert_grep "$f" "expired-and-dropped: 0" "it is not counted as expired"
  rm -rf "$root"
}

test_force_rebuild_failed_l2_does_not_consume(){
  echo "# regression: a stale report must not satisfy the consume gate under --force"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                    # first run succeeds, leaves a report
  mk_vault_note "$root" written-later "must survive the failed rebuild"
  # Rebuild with an L2 that writes nothing. The old report is still on disk, and it used
  # to satisfy both the retry loop's break and the consume gate, so this note was
  # archived having been read by nothing.
  export MOCK_MODE=l2_fail AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/written-later.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/written-later.md" "the note was not archived"
  ls "$root/dreams/$DATE.md.stale-"* >/dev/null 2>&1 \
    && ok "the previous report was preserved, not destroyed" \
    || no "the previous report was not preserved"
  rm -rf "$root"
}

test_unmovable_stale_report_disarms_consuming(){
  echo "# regression: if the stale report cannot be moved aside, nothing may be consumed"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                    # first run leaves a report
  mk_vault_note "$root" must-survive "the mv failed, so this must not be archived"
  # Make the move fail the way it would in practice: the destination directory is not
  # writable, so the old report stays at $REPORT_PATH. Without the disarm this is the
  # original hole reopened — the retry loop and the consume gate both see the old file.
  chmod 555 "$root/dreams"
  export MOCK_MODE=l2_fail AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  chmod 755 "$root/dreams"
  assert_file "$root/vault/inbox/must-survive.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/must-survive.md" "the note was not archived"
  assert_grep "$root/run.out" "will NOT archive notes" "the run says why consuming was disarmed"
  rm -rf "$root"
}

test_partial_report_does_not_consume(){
  echo "# regression: a truncated report must not satisfy the retry break or the consume gate"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" survives-truncation "a half-written report must not consume this"
  # l2_partial writes a non-empty report with no open-questions marker — what a mid-write
  # kill leaves. `-s` alone cannot tell it from a good report.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=2
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/survives-truncation.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/survives-truncation.md" "the note was not archived"
  assert_grep "$root/run.out" "no open-questions marker" "the run names the reason"
  # It must also have RETRIED rather than accepting the partial file on attempt 1.
  assert_grep "$root/run.out" "L2 aggregation attempt 2" "a truncated report triggers a retry"
  rm -rf "$root"
}

test_partial_report_does_not_block_retry(){
  echo "# regression: a truncated report must not satisfy the idempotency guard forever"
  local root; root=$(setup_env); mk_session "$root" s1
  # Every attempt dies mid-write. Without the move-aside, the next launchd catch-up
  # trigger sees a non-empty file, says "nothing to do", and the half-written report
  # becomes the permanent output for the date.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_no_file "$root/dreams/$DATE.md" "the truncated report was moved off the report path"
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && ok "it was preserved as .partial-<epoch>, not deleted" \
    || no "the partial report was lost"
  # The next trigger must actually re-run rather than no-op on the leftover.
  vault_run "$root"
  assert_nonempty "$root/dreams/$DATE.md" "a later trigger produced a real report"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "and it is a complete one"
  rm -rf "$root"
}

test_unassembled_dates_are_surfaced(){
  echo "# a date triaged but never assembled must be named, not left for someone to find"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  printf '{"transcript_bytes":10}\n' > "$prior/abc123def456.stats.json"
  # A second dir holding only a sidecar: never triaged, so nothing to assemble.
  mkdir -p "$root/autodream/findings/2020-01-03"
  printf '{"transcript_bytes":10}\n' > "$root/autodream/findings/2020-01-03/dead.stats.json"
  run_dream "$root"
  assert_grep "$root/run.out" "findings but no complete report: 2020-01-01" "the log names the abandoned date"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: 2020-01-01" "and the stat carries it into the next report"
  assert_nogrep "$(fdir "$root")/run-stats.txt" "2020-01-03" "a sidecar-only dir was never triaged and is not a failure"
  rm -rf "$root"
}

test_unassembled_ignores_a_finished_date(){
  echo "# a date with a complete report is not an abandoned one"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior" "$root/dreams"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  printf '# report\n\nautodream:open-questions=0\n' > "$root/dreams/2020-01-01.md"
  run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: *$" "the finished date is not listed"
  # A truncated report is not a finished one, and must come back onto the list.
  printf '# report with no marker\n' > "$root/dreams/2020-01-01.md"
  rm -f "$root/dreams/$DATE.md"
  run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: 2020-01-01" "but a marker-less one is"
  rm -rf "$root"
}

test_dead_stdout_does_not_kill_the_run(){
  echo "# regression: losing the log reader must cost the run its output, not its life"
  local root; root=$(setup_env); mk_session "$root" s1
  # Three runs died this way on 2026-08-02: tee was killed, the next log line SIGPIPEd the
  # run, and everything after L2 — the retry loop, the move-aside, the consume gate — was
  # never reached. No error line said so, because saying so was the thing that died.
  run_dream_broken_pipe "$root"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "the run finished and wrote a complete report"
  assert_grep "$root/run.out" "autodream end" "and its log reached the end on disk"
  rm -rf "$root"
}

test_complete_report_retires_partials(){
  echo "# a complete report supersedes the partials left by the nights that failed"
  local root; root=$(setup_env); mk_session "$root" s1
  # Two failed nights, so the second run has to retire a partial it did not itself create.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && ok "the failed nights left partials behind" \
    || no "setup failed: no partial report to retire"
  vault_run "$root"                                   # the night that finally works
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "a complete report landed"
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && no "partials survived the complete report that supersedes them" \
    || ok "every partial for the date was discarded"
  rm -rf "$root"
}

test_no_sessions_stub_carries_marker(){
  echo "# the no-sessions stub is a complete report and must carry the marker"
  local root; root=$(setup_env)     # no sessions at all
  run_dream "$root"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "the stub carries the marker"
  rm -rf "$root"
}

test_partial_report_keeps_previous(){
  echo "# regression: a truncated rebuild must not discard the previous good report"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                   # a good report lands
  export MOCK_MODE=l2_partial AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  ls "$root/dreams/$DATE.md.stale-"* >/dev/null 2>&1 \
    && ok "the previous good report was kept" \
    || no "the previous good report was discarded for a truncated one"
  rm -rf "$root"
}

test_old_date_reprocess_does_not_consume(){
  echo "# regression: reprocessing an old date must not consume today's pending input"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" todays-note "written this morning"
  # TARGET_DATE is not the date a normal nightly run would process.
  AUTODREAM_CONSUME_DATE=2099-01-01 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "written this morning" "the note is still collected as context for L2"
  assert_file "$root/vault/inbox/todays-note.md" "but it is NOT archived out of the inbox"
  assert_nonempty "$root/vault/reports/$DATE.md" "publishing still happens (it consumes nothing)"
  rm -rf "$root"
}

test_config_unbound_var_does_not_kill_run(){
  echo "# regression: a typo'd variable in the config must warn, not kill the run"
  local root; root=$(setup_env); mk_session "$root" s1
  # AUTODREAM_HOME does not exist; under `set -u` this used to abort bash outright,
  # before the log file or log() existed, so the night produced nothing and said nothing.
  printf 'X_CREDS_FILE=$AUTODREAM_HOME/x-credentials\nAUTODREAM_VAULT_DIR=%s/vault\n' "$root" > "$root/autodream/config"
  mk_vault_note "$root" survives-typo "the run must still happen"
  run_dream "$root"
  assert_nonempty "$root/dreams/$DATE.md" "the run still produced a report"
  assert_grep "$root/run.out" "unbound variable" "the bad config key is named in a warning"
  assert_grep "$(fdir "$root")/operator-notes.md" "the run must still happen" \
    "keys after the bad line still took effect"
  rm -rf "$root"
}

test_session_stats(){
  echo "# deterministic session stats pre-pass acceptance fixtures"
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local fixture out

  # Fixtures are emitted by tests/mock-omp.sh in OMP transcript shape (message
  # records + custom tool_execution_start), the format bin/session-stats.sh now
  # parses. MOCK guards the emitter so it never writes outside a test run.

  fixture="$root/carriers.jsonl"; out="$root/carriers.stats.json"
  MOCK=1 "$OMP_MOCK" "$fixture" carriers
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r 'keys | sort | join(",")' "$out")" \
    "duration_minutes,isSidechain,models_used,tool_call_count,tools_used,transcript_bytes,transcript_mtime,turn_count,user_message_count,user_turn_timestamps" \
    "stats output has exactly the specified fields"
  assert_eq "$(jq -r '.user_turn_timestamps | length' "$out")" "0" "no timestamped user turns in this fixture -> empty user_turn_timestamps"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "toolResult records are excluded from user message count"
  assert_eq "$(jq -r .turn_count "$out")" "2" "turn count excludes toolResult records (OMP has no tool-in-user-message carriers)"

  fixture="$root/timestamps.jsonl"; out="$root/timestamps.stats.json"
  MOCK=1 "$OMP_MOCK" "$fixture" timestamps
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .duration_minutes "$out")" "2.5" "duration uses available fractional timestamps"
  assert_eq "$(jq -r .models_used[0] "$out")" "claude-opus" "synthetic model is dropped"
  assert_eq "$(jq -r '.user_turn_timestamps | join(",")' "$out")" "1784541600" "user_turn_timestamps holds only the (fractional-second-truncated) real user turn's epoch"

  fixture="$root/text-image.jsonl"; out="$root/text-image.stats.json"
  MOCK=1 "$OMP_MOCK" "$fixture" text-image
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "text plus image human turn counts"

  fixture="$root/sidechain.jsonl"; out="$root/sidechain.stats.json"
  MOCK=1 "$OMP_MOCK" "$fixture" sidechain
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "sidechain has one human message"
  assert_eq "$(jq -r .turn_count "$out")" "5" "sidechain turn count counts user/assistant message records"
  assert_eq "$(jq -r .tool_call_count "$out")" "3" "sidechain tool calls are counted mechanically"
  assert_eq "$(jq -r '.tools_used | join(",")' "$out")" "Bash,Read,Write" "sidechain tools are sorted and unique"
  assert_eq "$(jq -r .isSidechain "$out")" "true" "sidechain marker is copied"
  rm -rf "$root"
}

test_happy(){
  echo "# happy path"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "L1 wrote findings JSON"
  assert_file    "$(fdir "$root")/$h.stats.json" "mechanical stats sidecar written"
  assert_eq      "$(jq -r .tool_call_count "$(fdir "$root")/$h.stats.json")" "1" "sidecar has plausible tool_call_count"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err on success"
  assert_file    "$root/dreams/$DATE.md"       "L2 wrote the report"
  rm -rf "$root"
}

test_unreadable(){
  echo "# unreadable session (validated before dispatch)"
  local root; root=$(setup_env); mk_session "$root" sess1
  chmod 000 "$root/projects/proj-a/sess1.jsonl"
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "unreadable -> structured error JSON written"
  assert_grep    "$(fdir "$root")/$h.json"     'not readable at dispatch' "error JSON states the reason"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err (structured record instead of a loop)"
  chmod 644 "$root/projects/proj-a/sess1.jsonl"; rm -rf "$root"
}

test_incomplete(){
  echo "# incomplete worker run (no JSON written)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # After the 2026-06-11 self-audit fix: on the FINAL retry round, a worker
  # that produced no output gets a metadata-only stub so the session is
  # visible to L1_ERRORED and the L2 aggregator instead of becoming a silent
  # .err. Earlier rounds still left the slot absent so retries could fire.
  assert_file     "$(fdir "$root")/$h.json"     "final-round stub written (no longer a silent failure)"
  assert_grep     "$(fdir "$root")/$h.json"     'worker exited without findings JSON' "stub carries the failure reason"
  # Whitespace-tolerant: the project-field normalization pass rewrites this stub via
  # json.dump (it has a real session_path + no project), reformatting "findings":[] →
  # "findings": []. The assertion is about the empty array, not its exact spacing.
  assert_grep     "$(fdir "$root")/$h.json"     '"findings": *\[\]'                   "stub has an empty findings array (counted by L1_ERRORED via the error key)"
  assert_nonempty "$(fdir "$root")/$h.json.err" ".err is still non-empty (per-round diagnostics)"
  assert_grep     "$(fdir "$root")/$h.json.err" 'incomplete run' ".err carries a diagnostic"
  assert_file     "$root/dreams/$DATE.md"       "L2 still produced the report"
  rm -rf "$root"
}

test_self_audit_stats(){
  echo "# run-stats.txt self-audit telemetry is written"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/x/y.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  assert_grep  "$stats" 'self_sessions_excluded: 1' "stats record the excluded self-session"
  assert_grep  "$stats" 'sessions_triaged: 1'        "stats record the triaged count"
  assert_grep  "$stats" 'l1_findings_with_error: 0'  "stats record the in-band error count"
  # 2026-06-11 self-audit fix: vs.-raw denominator + cache-disambiguating fields.
  assert_grep  "$stats" 'sessions_dropped_after_failures: 0'   "no dropped sessions on a clean happy-path run"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 0' "no precached findings on a fresh run"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 1'     "the one session was freshly processed this run"
  # #38: the key is always emitted, even with no bookmark credentials anywhere near the
  # sandbox, so a consumer never has to tell "absent" from "the walk did not run".
  assert_grep  "$stats" 'x_queryid_source: not_attempted'      "the queryId source is recorded even when the walk never ran"
  rm -rf "$root"
}

test_self_audit_stats_failure_denominator(){
  echo "# self-audit stats: dropped-after-failures is nonzero when a worker dies"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  # After the fix, even a stubbed final-round failure is counted: the stub
  # carries an "error" key so it lands in l1_findings_with_error, AND the
  # vs.-raw denominator stays accurate. Old behavior reported zero across
  # the board even though the session never produced real findings.
  assert_grep  "$stats" 'l1_findings_with_error: 1' "stats now surface the failed session via the error key"
  rm -rf "$root"
}

test_self_audit_stats_precached_disambiguation(){
  echo "# self-audit stats: precached findings counted so fast elapsed isn't 'impossible'"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Pre-seed a valid findings JSON so dispatcher's idempotency skips the worker.
  mkdir -p "$(fdir "$root")"; printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 1' "precached session counted as already done"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 0'     "no fresh work this run"
  rm -rf "$root"
}

test_idempotent(){
  echo "# idempotent (pre-existing VALID findings JSON is not re-run)"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # A valid findings record (has a top-level findings key) marks a completed
  # triage; the run must leave it untouched. Sentinel lives in session_path.
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"SENTINEL","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -r .session_path "$(fdir "$root")/$h.json")" "SENTINEL" "valid findings JSON left untouched"
  rm -rf "$root"
}

test_revalidates_garbage(){
  echo "# a non-empty but malformed findings JSON is re-dispatched, not counted as done"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Old contract treated any non-empty file as done; new contract re-runs a
  # record that lacks a valid top-level findings key (a worker that emitted
  # garbage). The mock worker overwrites it with a well-formed record.
  mkdir -p "$(fdir "$root")"; printf 'GARBAGE{not json' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -e 'has("findings")' "$(fdir "$root")/$h.json" 2>/dev/null)" "true" "garbage findings JSON re-dispatched and replaced"
  rm -rf "$root"
}

test_no_sessions(){
  echo "# no sessions for the date"
  local root; root=$(setup_env)   # no mk_session
  run_dream "$root"
  assert_file "$root/dreams/$DATE.md" "stub report written"
  assert_grep "$root/dreams/$DATE.md" 'No Claude Code sessions' "stub report has the no-sessions notice"
  rm -rf "$root"
}

test_framing(){
  echo "# prompt framing regression (literal paths, no \$VAR, blank separator)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset FANOUT MOCK_CAPTURE_DIR
  local cap="$root/cap/l1-stdin.txt"
  assert_file "$cap" "captured the L1 prompt"
  local l1 l2 l3 l4
  l1=$(sed -n '1p' "$cap"); l2=$(sed -n '2p' "$cap"); l3=$(sed -n '3p' "$cap"); l4=$(sed -n '4p' "$cap")
  case "$l1" in "Session transcript to analyze (literal absolute path): /"*) ok "line 1 = literal session path" ;; *) no "line 1 framing (got [$l1])" ;; esac
  case "$l2" in "Write your findings JSON to this literal absolute path: /"*) ok "line 2 = literal output path" ;; *) no "line 2 framing (got [$l2])" ;; esac
  assert_eq "$l3" "" "line 3 = blank separator (doc not glued onto the path)"
  case "$l4" in "# Session Triage"*) ok "line 4 = SESSION_TRIAGE.md begins" ;; *) no "line 4 doc start (got [$l4])" ;; esac
  local doc_line stats_line
  doc_line=$(grep -n '^## Output schema' "$cap" | head -n 1 | cut -d: -f1)
  stats_line=$(grep -n '^## Precomputed session stats' "$cap" | head -n 1 | cut -d: -f1)
  [ -n "$doc_line" ] && [ -n "$stats_line" ] && [ "$stats_line" -gt "$doc_line" ] \
    && ok "precomputed stats block follows the full SESSION_TRIAGE.md body" \
    || no "precomputed stats block follows the full SESSION_TRIAGE.md body"
  assert_grep "$cap" '"tool_call_count": 1' "captured L1 prompt contains the sidecar JSON"
  if printf '%s\n%s\n' "$l1" "$l2" | grep -qE 'SESSION_PATH=|OUTPUT_PATH=|[$]SESSION_PATH|[$]OUTPUT_PATH'; then
    no "no legacy KEY=value / \$VAR framing in the inlined header"
  else
    ok "no legacy KEY=value / \$VAR framing in the inlined header"
  fi
  assert_grep "$root/cap/l1-args.txt" 'not shell variables' "system prompt forbids shell-variable treatment"
  rm -rf "$root"
}

test_changelog(){
  echo "# upstream changelog window (offline, local fixture remote)"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1

  # Build a local 'remote' for anthropics/claude-code: one CHANGELOG commit dated
  # inside the target day [2020-01-02, 2020-01-03), one dated a month later (out of window).
  local up="$root/upstream"; mkdir -p "$up"
  ( cd "$up" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'release 2.1.999'
    printf '# Changelog\n\n## 2.2.0\n\n- Out-of-window mock feature\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-02-01T12:00:00" GIT_COMMITTER_DATE="2020-02-01T12:00:00" \
      git commit -q -m 'release 2.2.0' )

  export AUTODREAM_CHANGELOG=1 CHANGELOG_REMOTE="$up" CLAUDE_CODE_REPO="$root/cache/cc"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG CHANGELOG_REMOTE CLAUDE_CODE_REPO

  local cw="$(fdir "$root")/changelog-window.md"
  assert_file   "$cw" "changelog-window.md written"
  assert_grep   "$cw" '2.1.999'              "captures the in-window release"
  assert_grep   "$cw" 'In-window mock'       "captures the in-window bullet"
  assert_nogrep "$cw" '2.2.0'                "excludes the out-of-window release"
  rm -rf "$root"
}

test_prune_helper(){
  echo "# prune-self-sessions helper: list / filter / delete"
  local PR="$REPO/bin/prune-self-sessions.sh"
  [ -x "$PR" ] || { no "prune helper executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/-Users-x"
  local self="$root/projects/-Users-x/self.jsonl" real="$root/projects/-Users-x/real.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"Session transcript to analyze (literal absolute path): /x"}}\n' > "$self"
  printf '{"type":"user","message":{"role":"user","content":"fix the bug in foo.ts"}}\n' > "$real"

  local out; out=$(PROJECTS_DIR="$root/projects" "$PR")
  case "$out" in *self.jsonl*) ok "list includes the self session" ;; *) no "list includes the self session (got [$out])" ;; esac
  case "$out" in *real.jsonl*) no "list must exclude the real session" ;; *) ok "list excludes the real session" ;; esac

  printf '%s\n%s\n' "$self" "$real" | "$PR" --filter > "$root/filtered.txt"
  assert_grep   "$root/filtered.txt" 'real.jsonl' "filter keeps the real session"
  assert_nogrep "$root/filtered.txt" 'self.jsonl' "filter drops the self session"

  PROJECTS_DIR="$root/projects" "$PR" --delete >/dev/null
  assert_no_file "$self" "self session deleted"
  assert_file    "$real" "real session kept"
  rm -rf "$root"
}

test_self_session_excluded(){
  echo "# autodream's own transcripts are excluded from triage"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/Users/x/.claude/projects/foo/bar.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local hr hs; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); hs=$(hash_of "$sf")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$hs.json" "self-session excluded (no findings JSON)"
  assert_grep    "$root/run.out" 'excluded 1 autodream-own' "run log reports the exclusion"
  rm -rf "$root"
}

test_skip_empty_sessions(){
  echo "# 0-turn shell sessions are skipped before fanout"
  local root; root=$(setup_env); mk_session "$root" real1
  # an auto-opened/aborted shell: a single ai-title line, no user turn at all
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  run_dream "$root"
  local hr he; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); he=$(hash_of "$empty")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$he.json" "empty shell skipped (no findings JSON)"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 1' "stats record the empty skip"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "stats record one triaged"
  assert_grep    "$root/run.out" 'skipped 1 empty' "run log reports the empty skip"
  rm -rf "$root"
}

test_skip_empty_disabled(){
  echo "# AUTODREAM_SKIP_EMPTY=0 keeps 0-turn shells in the triage set"
  local root; root=$(setup_env)
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  export AUTODREAM_SKIP_EMPTY=0; run_dream "$root"; unset AUTODREAM_SKIP_EMPTY
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 0' "no skips when disabled"
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "shell still triaged when disabled"
  rm -rf "$root"
}

test_l1_retry(){
  echo "# L1 retries a flaky session and completes it on a later round"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_flaky AUTODREAM_L1_ROUNDS=3; run_dream "$root"; unset MOCK_MODE AUTODREAM_L1_ROUNDS
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file "$(fdir "$root")/$h.json"  "flaky session produced findings on retry"
  assert_grep "$root/run.out" 'round 2'  "a second L1 round ran"
  assert_file "$root/dreams/$DATE.md"    "report still produced"
  rm -rf "$root"
}

test_idempotency_guard(){
  echo "# existing report short-circuits the run (launchd catch-up no-op)"
  local root; root=$(setup_env); mk_session "$root" sess1
  printf 'SENTINEL REPORT' > "$root/dreams/$DATE.md"
  run_dream "$root"
  assert_eq   "$(cat "$root/dreams/$DATE.md")" "SENTINEL REPORT" "existing report left untouched"
  assert_grep "$root/run.out" 'already exists' "run logged the skip"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_no_file "$(fdir "$root")/$h.json" "no L1 work done when report already exists"
  rm -rf "$root"
}

test_normalize_project(){
  echo "# project field is normalized deterministically from the session path"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_badproject; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  local fj="$(fdir "$root")/$h.json"
  assert_file   "$fj" "findings JSON written"
  assert_nogrep "$fj" 'WRONG-PROJECT'     "model's wrong project value was overwritten"
  assert_grep   "$fj" '"project": "proj-a"' "project normalized to the session dir basename"
  assert_grep   "$root/run.out" 'normalized project field' "run log reports normalization"
  # l1_badproject emits the pre-pilot JSON shape (no facet fields) — the report
  # landing proves L2 still accepts legacy findings.
  assert_file   "$root/dreams/$DATE.md" "L2 completed on facet-free legacy findings"
  rm -rf "$root"
}

test_slim_transcript(){
  echo "# slim-transcript bounds an oversized transcript"
  local SL="$REPO/bin/slim-transcript.sh"
  [ -x "$SL" ] || { no "slim-transcript executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local big="$root/big.jsonl" out="$root/slim.jsonl"
  # 3000 lines × ~3000 chars ≈ 9 MB
  awk 'BEGIN{ b=""; for(i=0;i<3000;i++) b=b "x"; for(n=0;n<3000;n++) print "{\"n\":" n ",\"blob\":\"" b "\"}" }' > "$big"
  "$SL" "$big" "$out"
  local osz; osz=$(wc -c < "$out" | tr -d ' ')
  [ "$osz" -lt 300000 ] && ok "slimmed far below original ($osz bytes < 300k, orig ~9M)" || no "slim output too big ($osz)"
  assert_grep "$out" 'elided by autodream'     "elides the middle"
  assert_grep "$out" 'slimmed this transcript' "appends the slim note"
  rm -rf "$root"
}

test_facet_fields_plumbed(){
  echo "# pilot facet fields flow L1 -> findings JSON -> L2 input"
  # Plumbing only: the L2 mock ignores findings content, so assertions stop at
  # the findings JSON L2 reads. Behavioral quality is the production pilot's job.
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h j; h=$(hash_of "$root/projects/proj-a/sess1.jsonl"); j="$(fdir "$root")/$h.json"
  assert_eq "$(jq -r .outcome "$j")"                          "fully_achieved" "outcome facet present in findings JSON"
  assert_eq "$(jq -r .satisfaction_signals.satisfied "$j")"   "1"              "satisfaction_signals present"
  assert_eq "$(jq -e 'has("underlying_goal")' "$j")"          "true"           "underlying_goal key present (null allowed)"
  assert_eq "$(jq -r '.instructions_given[0]' "$j")"          "always run tests after edits" "instructions_given present"
  assert_file "$root/dreams/$DATE.md" "L2 run completed with facet-bearing findings as input"
  rm -rf "$root"
}

test_noise_gate_trivial(){
  echo "# noise gate: a trivial (1-user-turn) session is stubbed, not sent to the model"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  export MOCK_CALL_LOG="$root/calls.log"
  run_dream "$root"
  unset MOCK_CALL_LOG
  local hr ht
  hr=$(hash_of "$root/projects/proj-a/real1.jsonl")
  ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_file    "$(fdir "$root")/$ht.json"     "gated session still got a findings JSON (the stub)"
  # Whitespace-tolerant like test_incomplete: the project-field normalization
  # pass rewrites this stub via json.dump (it has a real session_path + no
  # project), reformatting "skipped":"below_noise_gate" -> "skipped": "..." etc.
  assert_grep    "$(fdir "$root")/$ht.json"     '"skipped": *"below_noise_gate"' "gated stub carries the skip reason"
  assert_grep    "$(fdir "$root")/$ht.json"     '"findings": *\[\]'              "gated stub has an empty findings array"
  assert_no_file "$(fdir "$root")/$ht.json.err" "no .err for a gated session (clean skip, not a failure)"
  assert_grep    "$root/calls.log" "$hr" "model was called for the real session"
  assert_nogrep  "$root/calls.log" "$ht" "model was NOT called for the gated session"
  rm -rf "$root"
}

test_noise_gate_short_duration(){
  echo "# noise gate: duration alone gates even with enough user turns"
  local root; root=$(setup_env)
  mk_short_duration_session "$root" short1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/short1.jsonl")
  assert_grep "$(fdir "$root")/$h.json" '"skipped": *"below_noise_gate"' "short-duration session gated despite 2 user turns"
  rm -rf "$root"
}

test_noise_gate_subagent_carveout(){
  echo "# noise gate: subagent / high-tool-count sessions are never gated"
  local root; root=$(setup_env)
  mk_subagent_session "$root" subagent1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/subagent1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "subagent session was not gated"
  assert_grep   "$(fdir "$root")/$h.json" 'fully_achieved'    "subagent session got real findings from the model"
  rm -rf "$root"
}

test_noise_gate_stats(){
  echo "# noise gate: gated count in run-stats.txt; precache count stays truthful alongside gating"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  mk_session "$root" cached1
  local hc; hc=$(hash_of "$root/projects/proj-a/cached1.jsonl")
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$hc.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'gated: 1'                        "gated count recorded"
  assert_grep "$stats" 'sessions_triaged: 3'              "all three sessions counted as triaged"
  assert_grep "$stats" 'l1_sessions_already_done_at_start: 1' "precache count unaffected by gating (only cached1 was precached)"
  local ht; ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_grep "$(fdir "$root")/$ht.json" 'below_noise_gate' "gated session got the stub"
  rm -rf "$root"
}

test_noise_gate_env_override(){
  echo "# noise gate: AUTODREAM_MIN_USER_TURNS override changes the threshold"
  local root; root=$(setup_env)
  mk_trivial_session "$root" trivial1
  export AUTODREAM_MIN_USER_TURNS=1
  run_dream "$root"
  unset AUTODREAM_MIN_USER_TURNS
  local h; h=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "lowering the threshold keeps the 1-turn session out of the gate"
  rm -rf "$root"
}

test_oversized_gate_zero(){
  echo "# oversized gate (#12 measurement): both keys present at 0 on a normal run"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 0'   "no oversized sessions under the default threshold"
  assert_grep "$stats" 'oversized_errored: 0' "no oversized-errored sessions under the default threshold"
  rm -rf "$root"
}

test_oversized_gate_total(){
  echo "# oversized gate (#12 measurement): a session over a lowered AUTODREAM_SLIM_BYTES counts as oversized"
  local root; root=$(setup_env); mk_session "$root" sess1
  # mk_session's fixture is 205 bytes; a threshold of 100 puts it over the line
  # without needing a multi-KB fixture. slim-transcript.sh also fires at this
  # size (harmless — the mock still writes findings regardless of readpath).
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "one session counted as oversized"
  assert_grep "$stats" 'oversized_errored: 0' "the oversized session still triaged cleanly (no error key)"
  rm -rf "$root"
}

test_oversized_gate_errored(){
  echo "# oversized gate (#12 measurement): an oversized session that still errors is paired correctly"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Force the final-round metadata stub (carries a top-level "error" key) on an
  # oversized session, and verify oversized_errored pairs the right hash's
  # stats sidecar to the right findings JSON (not just a raw count).
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_incomplete AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "the incomplete session still counted as oversized"
  assert_grep "$stats" 'oversized_errored: 1' "its final-round error stub is paired and counted"
  rm -rf "$root"
}

test_stats_sidecar_ok(){
  echo "# sidecar health (#27): a normal run reports zero unparseable sidecars"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 0' "healthy sidecars report a real zero"
  rm -rf "$root"
}

test_stats_sidecar_missing_counted(){
  echo "# sidecar health (#27): a session-stats.sh that never runs is counted, not silently absorbed"
  local root; root=$(setup_env)
  mk_session "$root" sess1
  mk_session "$root" sess2
  # compute_session_stats deletes and regenerates every sidecar each run, so the
  # only way to force the broken-sidecar path is to break the generator itself.
  export AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 2' "both missing sidecars counted"
  rm -rf "$root"
}

test_stats_sidecar_missing_keeps_oversized_count(){
  echo "# sidecar health (#27): an oversized session does NOT vanish from oversized_total when its sidecar is missing"
  local root; root=$(setup_env); mk_session "$root" sess1
  # This is the issue's exact reproduction: a genuinely oversized session whose
  # sidecar never got written used to drop straight out of oversized_total, the
  # counter that gates #12, with nothing recording that it happened.
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "and the sidecar failure is recorded alongside it"
  rm -rf "$root"
}

test_stats_sidecar_malformed_counted(){
  echo "# sidecar health (#27): a sidecar that is a valid object but has no usable transcript_bytes is counted"
  local root; root=$(setup_env); mk_session "$root" sess1
  # compute_session_stats only validates `type == "object"`, so this stub survives
  # generation intact and breaks at read time instead — the quieter of the two paths.
  local stub="$root/stats-no-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"user_message_count\":5,\"tool_call_count\":9}" > "$2"' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$stub"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "missing transcript_bytes counts as unparseable"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  rm -rf "$root"
}

test_stats_sidecar_non_numeric_counted(){
  echo "# sidecar health (#27): a non-numeric transcript_bytes is counted, not clamped to 0 in silence"
  local root; root=$(setup_env); mk_session "$root" sess1
  local stub="$root/stats-bad-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"transcript_bytes\":\"lots\"}" > "$2"' > "$stub"
  export AUTODREAM_STATS_BIN="$stub"
  chmod +x "$stub"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "a string transcript_bytes is not a measurement"
  rm -rf "$root"
}

test_runner_provenance(){
  echo "# runner provenance (#29): run-stats.txt records which code produced it"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  # The suite runs run.sh from the repo checkout, so HEAD resolves and the stamp must be
  # the real short SHA rather than the "unknown" degradation path.
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  assert_grep "$stats" "runner_commit: $head" "stamps the commit the runner was checked out at"
  assert_grep "$stats" 'runner_dirty: \(yes\|no\)' "records whether the tree had uncommitted changes"
  assert_grep "$root/run.out" "runner: $head" "run log names the runner up front"
  rm -rf "$root"
}

test_runner_provenance_no_git(){
  echo "# runner provenance (#29): a non-git install degrades to unknown, never fails the run"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Copy the scripts out of the repo so SCRIPT_DIR resolves somewhere with no git
  # history at all — the tarball-install case, which must still produce a report.
  local bin="$root/bin"; mkdir -p "$bin"
  cp "$REPO"/bin/*.sh "$bin/"
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_commit: unknown' "no git history degrades to unknown"
  assert_grep "$stats" 'runner_dirty: no'       "dirty is not claimed when the commit is unknown"
  assert_file "$root/dreams/$DATE.md"           "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_through_symlink(){
  echo "# runner provenance (#29): the installed symlink layout still stamps the repo's sha"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Reproduce what install.sh actually leaves on disk, which is what the earlier tests
  # missed: ~/.claude/autodream is a REAL directory holding one symlink per script, not a
  # symlink to the checkout. `cd "$(dirname "$0")"` therefore lands in a directory with no
  # .git, and provenance has to follow the file's own link to find the working tree.
  # Six production runs through 2026-08-03 stamped "unknown" against a clean checkout.
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" "runner_commit: $head" "a symlinked runner reports the checkout it points at"
  assert_file "$root/dreams/$DATE.md"          "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_relative_symlink(){
  echo "# runner provenance (#29): a symlink with a relative target still finds the checkout"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  # install.sh writes absolute targets, so nothing in production exercises the walk's
  # relative-target branch. A hand-rolled install (ln -s ../../git/oss/cc-autodream/bin/…)
  # produces one, and a target resolved against $PWD instead of the link's own directory
  # silently lands nowhere.
  # Both sides must be physical paths before relpath: on macOS $TMPDIR sits under /var,
  # which is itself a link to /private/var, so a relative path computed from the logical
  # name walks up through a directory that does not exist and the link is born broken.
  local phys_ad phys_bin rel
  phys_ad=$(cd "$root/autodream" && pwd -P)
  phys_bin=$(cd "$REPO/bin" && pwd -P)
  rel=$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$phys_bin" "$phys_ad")
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$rel/$(basename "$f")" "$root/autodream/$(basename "$f")"; done
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  assert_grep "$(fdir "$root")/run-stats.txt" "runner_commit: $head" "a relative link target resolves against the link's own dir"
  assert_file "$root/dreams/$DATE.md" "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_unresolvable_chain(){
  echo "# runner provenance (#29): a chain past the hop cap says unknown, never a wrong sha"
  local root; root=$(setup_env); mk_session "$root" sess1
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  # A chain longer than the cap leaves the walk holding a path that is still a symlink.
  # Resolving it anyway would stamp the sha of whatever checkout that truncated path sits
  # in — here, this very repo, which is exactly the plausible-but-wrong answer #29 exists
  # to rule out. 12 hops clears the cap of 8 while staying under macOS's ELOOP limit of 16,
  # so bash still executes the script and only the provenance field degrades.
  local prev="$REPO/bin/run.sh" i
  for i in $(seq 1 12); do
    ln -sf "$prev" "$root/autodream/hop-$i.sh"
    prev="$root/autodream/hop-$i.sh"
  done
  ln -sf "$prev" "$root/autodream/run.sh"
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_commit: unknown' "an unresolved chain degrades instead of guessing"
  assert_grep "$stats" 'runner_dirty: no'       "dirty is not claimed when the commit is unknown"
  assert_file "$root/dreams/$DATE.md"           "the run still produced a report"
  rm -rf "$root"
}

test_oversized_gate_script(){
  echo "# oversized-gate.sh (#29): recomputes the #12 window from artifacts, including dates whose run-stats.txt lacks the keys"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  local fd; fd=$(fdir "$root")
  # Strip the keys to simulate a pre-#25 runner: the script must still recover the
  # numbers from the sidecars, which is the whole point of it existing.
  grep -v '^oversized_' "$fd/run-stats.txt" > "$fd/run-stats.tmp" && mv "$fd/run-stats.tmp" "$fd/run-stats.txt"
  assert_nogrep "$fd/run-stats.txt" 'oversized_total' "precondition: the keys really are gone"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE CLOSED'  "a clean window reports the gate closed"
  assert_grep "$root/gate.out" '1 oversized'  "recovered the oversized count without run-stats.txt"
  assert_grep "$root/gate.out" 'rule of three' "quotes the upper bound rather than implying 0% is certain"
  rm -rf "$root"
}

test_oversized_gate_script_open(){
  echo "# oversized-gate.sh (#29): an errored oversized session pushes the window over the threshold"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_incomplete AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE OPEN'    "1 of 1 errored is 100%, well over the 5% threshold"
  rm -rf "$root"
}

test_oversized_gate_script_empty(){
  echo "# oversized-gate.sh (#29): an empty window is not reported as a measured 0%"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local out; out=$(bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep  "$root/gate.out" 'nothing to measure' "no oversized sessions is not evidence either way"
  assert_nogrep "$root/gate.out" 'GATE CLOSED'       "and must not be reported as a closed gate"
  rm -rf "$root"
}

test_oversized_gate_script_args(){
  echo "# oversized-gate.sh (#29): argument validation, including the --days spin found in review"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  # `--days` with no value left $# at 1 while `shift 2` refused to shift, looping forever.
  # A hang in a nightly-adjacent script is worse than a wrong number, so it gets a test.
  # These are the only assertions in the suite that need GNU `timeout`. Stock macOS has
  # neither name; homebrew coreutils installs `gtimeout`, and `timeout` too if its gnubin
  # is on PATH. Resolve whichever exists and say so plainly when neither does — without
  # this, all four assertions come back as exit 127 and read like real regressions.
  local TO=""
  command -v timeout  >/dev/null 2>&1 && TO=timeout
  [ -n "$TO" ] || { command -v gtimeout >/dev/null 2>&1 && TO=gtimeout; }
  [ -n "$TO" ] || { no "oversized-gate arg tests need GNU timeout (brew install coreutils)"; return 0; }
  local out rc
  out=$( { "$TO" 10 bash "$GATE" --days; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days with no value exits 2 instead of hanging (124 would be the hang)"
  out=$( { "$TO" 10 bash "$GATE" --days abc; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days with a non-integer exits 2"
  out=$( { "$TO" 10 bash "$GATE" --days 0; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days 0 exits 2"
  out=$( { "$TO" 10 bash "$GATE" --bogus; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "an unknown option exits 2 rather than being read as a findings dir"
}

test_notify_count(){
  echo "# notify.sh counts from the open-questions marker, falling back to shape for older reports"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  # Pre-seed an executable stub at the branded-notifier path so the test neither
  # bootstraps a real app bundle nor posts a real banner. OSA backup off for the same
  # reason; SUBL points at true so no editor opens.
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  run_notify(){
    AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 SUBL=/usr/bin/true \
      "$NOTIFY" "$1" > "$root/notify.out" 2>&1
  }
  mk_report(){ # $1=date, stdin=Open questions section body
    local f="$root/$1.md"
    { printf '# Autodream — %s\n\n## Open questions for the user\n' "$1"; cat; printf '\n## Trailing section\n'; } > "$f"
    printf '%s' "$f"
  }

  # --- marker is authoritative, even when the section's shape says otherwise ---
  # This is the real 2026-07-24 shape: one numbered question, then a "dropped by the
  # gate" list. The old counter scored 6 here; the marker says 1.
  local f
  f=$(mk_report 2020-02-01 <<'EOF'
**One question survived the triviality gate.**

1. **A real question** — should we do the thing?

Other findings dropped by the gate:
- Pattern 1 already addressed on disk.
- Pattern 2 settled last week.
- Pattern 3 below threshold.
- Pattern 4 quarantined.

<!-- autodream:open-questions=1 -->
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-01-open-questions.md" '^# 1 open question$' "marker wins over the 6 list lines in the section"

  # --- marker of 0 must stay silent even though the section has prose and bullets ---
  f=$(mk_report 2020-02-02 <<'EOF'
None that clear the triviality gate this run.

- Pattern 1 was already fixed on disk.
- Pattern 2 is under a standing moratorium.

<!-- autodream:open-questions=0 -->
EOF
)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-02-open-questions.md" "marker=0 writes no inbox file despite a non-empty section"
  assert_grep "$root/notify.out" '0 open questions' "marker=0 reports zero"

  # --- no marker (pre-contract report): numbered items win over their sub-bullets ---
  f=$(mk_report 2020-02-03 <<'EOF'
1. First question?
   - supporting detail
   - more detail
2. Second question?
   - supporting detail
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-03-open-questions.md" '^# 2 open questions$' "no marker: 2 items, not 5 list lines"

  # --- no marker: bold topic titles beat the bullets underneath them ---
  f=$(mk_report 2020-02-04 <<'EOF'
**Scrape skill guardrail**
- Update step 3?
- Add a step-6 check?

**TLS-bypass rule**
- Add a rule?
- Where should it live?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-04-open-questions.md" '^# 2 open questions$' "no marker: 2 titles, not 4 bullets"

  # --- no marker: plain bullets are the questions ---
  f=$(mk_report 2020-02-05 <<'EOF'
- Raise the fanout?
- Drop the cache?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-05-open-questions.md" '^# 2 open questions$' "no marker: plain bullets counted"

  # --- no marker: bare prose still pops, since a non-empty section has something to say ---
  f=$(mk_report 2020-02-06 <<'EOF'
Should the fanout be raised to 12 given the recent session volume?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-06-open-questions.md" '^# 1 open question$' "no marker: prose falls back to 1"

  # --- no marker: a "None ..." lead-in is zero, not a prose question ---
  # Without this case the prose tier turns every quiet pre-marker night into a false pop.
  f=$(mk_report 2020-02-07 <<'EOF'
None that clear the triviality gate this run.
EOF
)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-07-open-questions.md" "no marker: a None lead-in stays silent"

  # --- genuinely empty section stays a quiet no-op ---
  f=$(mk_report 2020-02-08 </dev/null)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-08-open-questions.md" "empty section writes nothing"
  assert_grep "$root/notify.out" '0 open questions' "empty section reports zero"

  rm -rf "$root"
}

test_notify_open_command(){
  echo "# notify.sh opens the inbox via AUTODREAM_OPEN (multi-word commands, deprecated SUBL alias)"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  # A recorder standing in for an editor: logs every argument it was handed, one per
  # line, so the test can prove word-splitting and quoting rather than just exit status.
  printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done >> "%s/opened.log"\n' "$root" > "$root/fake-editor"
  chmod +x "$root/fake-editor"

  printf '# Autodream — 2020-03-01\n\n## Open questions for the user\n1. A question?\n\n<!-- autodream:open-questions=1 -->\n' \
    > "$root/2020-03-01.md"

  # single-word command
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" "2020-03-01-open-questions.md" "AUTODREAM_OPEN received the inbox path"
  assert_grep "$root/notify.out" 'opened .* with:' "log names the command it opened with"

  # multi-word command: the flag and the path must arrive as separate arguments
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor --flag" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" '^--flag$'    "multi-word command word-splits into its own argument"
  assert_eq "$(wc -l < "$root/opened.log" | tr -d ' ')" "2" "exactly two arguments: the flag and the path"

  # a path with a space must stay ONE argument, not split by sh -c
  : > "$root/opened.log"
  mkdir -p "$root/dir with space"
  printf '# Autodream — 2020-03-02\n\n## Open questions for the user\n1. A question?\n\n<!-- autodream:open-questions=1 -->\n' \
    > "$root/dir with space/2020-03-02.md"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/dir with space/2020-03-02.md" > "$root/notify.out" 2>&1
  assert_eq "$(wc -l < "$root/opened.log" | tr -d ' ')" "1" "a spaced path arrives as a single argument"

  # SUBL still honored as the deprecated alias, so existing setups keep working
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 SUBL="$root/fake-editor" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" "2020-03-01-open-questions.md" "deprecated SUBL alias still opens the file"

  # AUTODREAM_OPEN wins when both are set
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 \
    AUTODREAM_OPEN="$root/fake-editor --winner" SUBL=/usr/bin/false \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" '^--winner$' "AUTODREAM_OPEN takes precedence over SUBL"

  # a broken open command must not fail the run — the inbox file is the durable output
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/does-not-exist" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_eq "$?" "0" "a failing open command still exits 0"
  assert_grep "$root/notify.out" 'failed to open' "and says so instead of pretending it opened"
  assert_file "$root/inbox/2020-03-01-open-questions.md" "inbox file written regardless"

  rm -rf "$root"
}

test_notify_dryrun(){
  echo "# notify.sh dry run reports the count without writing, posting, or opening anything"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  # Deliberately NO stub notifier here. That is the whole point: a real sweep pointed
  # AUTODREAM_DIR at a temp dir and assumed that was enough, but with no branded bundle
  # present the resolution falls through to a system terminal-notifier and posts for
  # real. Dry run has to be safe without any stubbing at all.
  printf '#!/bin/sh\necho "$@" >> "%s/opened.log"\n' "$root" > "$root/fake-editor"
  chmod +x "$root/fake-editor"
  printf '# Autodream — 2020-04-01\n\n## Open questions for the user\n1. One?\n2. Two?\n\n<!-- autodream:open-questions=2 -->\n' \
    > "$root/2020-04-01.md"

  local out; out=$(AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_DRYRUN=1 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-04-01.md" 2>&1)
  printf '%s' "$out" > "$root/dry.out"
  assert_grep    "$root/dry.out" 'dry run'          "says it was a dry run"
  assert_grep    "$root/dry.out" '2 open questions' "still reports the real count"
  assert_no_file "$root/inbox/2020-04-01-open-questions.md" "dry run writes no inbox file"
  assert_no_file "$root/opened.log"                 "dry run opens nothing"

  # And the same report without the flag DOES do the work, so the guard isn't just off.
  # NOW seed the stub notifier: this call reaches the posting code, and without a stub at
  # the branded path the resolution falls through to a system terminal-notifier and fires
  # a real banner. That is the very accident this feature exists to prevent, and writing
  # the test without the stub reproduced it — the suite posted a live notification for a
  # fixture dated 2020-04-01. The dry-run assertions above stay stub-free on purpose.
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-04-01.md" > "$root/wet.out" 2>&1
  assert_file "$root/inbox/2020-04-01-open-questions.md" "without the flag the inbox file is written"
  assert_file "$root/opened.log"                         "without the flag the open command runs"

  # A zero-question report is quiet either way, and must not claim to be a dry run.
  printf '# Autodream — 2020-04-02\n\n## Open questions for the user\nNone that clear the gate.\n\n<!-- autodream:open-questions=0 -->\n' \
    > "$root/2020-04-02.md"
  out=$(AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_DRYRUN=1 "$NOTIFY" "$root/2020-04-02.md" 2>&1)
  printf '%s' "$out" > "$root/dry0.out"
  assert_grep   "$root/dry0.out" '0 open questions' "zero-count report still reports zero"
  assert_nogrep "$root/dry0.out" 'dry run'          "the zero path exits before the dry-run notice"

  rm -rf "$root"
}

test_runner_dirty_ignores_untracked(){
  echo "# runner_dirty (#29 follow-up): an untracked scratch file is not a dirty runner"
  local root; root=$(setup_env); mk_session "$root" sess1
  # A clean checkout with a stray untracked file reported runner_dirty: yes on the first
  # production run. Only tracked modifications mean "code that exists in nobody's history".
  local repo="$root/repo"; mkdir -p "$repo"
  cp -R "$REPO/bin" "$repo/bin"; cp -R "$REPO/prompts" "$repo/prompts"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" add -A 2>/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  printf 'scratch\n' > "$repo/untracked-scratch.txt"
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$repo/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_dirty: no' "an untracked file alone does not mark the runner dirty"

  # A tracked modification still does.
  printf '\n# tracked edit\n' >> "$repo/bin/session-stats.sh"
  rm -rf "$(fdir "$root")" "$root/dreams/$DATE.md"
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$repo/bin/run.sh" "$DATE" > "$root/run2.out" 2>&1
  assert_grep "$(fdir "$root")/run-stats.txt" 'runner_dirty: yes' "a tracked modification still marks the runner dirty"
  rm -rf "$root"
}

test_overlap_pair(){
  echo "# overlap (#14): two alternating-close sessions count as ONE pair regardless of qualifying turn-pairs"
  local root; root=$(setup_env)
  # A: 10:00, 10:20   B: 10:05, 10:25 — every A/B turn combo is within 30 min
  # (A0-B0=5m, A0-B1=25m, A1-B0=15m, A1-B1=5m), so four turn-pairs qualify but
  # the {A,B} pair must be counted exactly once.
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z" "2026-07-20T10:20:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z" "2026-07-20T10:25:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 1'         "exactly one distinct pair counted"
  assert_grep "$stats" 'sessions_with_overlap: 2'  "both sessions counted as involved"
  rm -rf "$root"
}

test_overlap_triple(){
  echo "# overlap (#14): three pairwise-overlapping sessions -> 3 pairs, 3 sessions"
  local root; root=$(setup_env)
  # A@10:00, B@10:10, C@10:20 — every pair (A-B=10m, B-C=10m, A-C=20m) is within 30 min.
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:10:00Z"
  mk_timed_session "$root" sessC "2026-07-20T10:20:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 3'         "all three pairs counted"
  assert_grep "$stats" 'sessions_with_overlap: 3'  "all three sessions counted as involved"
  rm -rf "$root"
}

test_overlap_none(){
  echo "# overlap (#14): sessions more than 30 minutes apart -> both stats 0, keys still present"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T11:00:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  # This is the genuine-zero case (#26): the pass DID run, it just found nothing to
  # pair. overlap_measured must positively say so — that's the whole point of the fix,
  # distinguishing this from a pass that never ran.
  assert_grep "$stats" 'overlap_measured: yes'     "genuine zero overlap is still a real measurement"
  assert_grep "$stats" 'overlap_events: 0'         "no pairs when sessions are far apart"
  assert_grep "$stats" 'sessions_with_overlap: 0'  "no sessions involved when sessions are far apart"
  rm -rf "$root"
}

test_overlap_not_measured_missing_bin(){
  echo "# overlap (#26): AUTODREAM_OVERLAP_BIN pointed at a nonexistent path -> not measured, counts still 0"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  export AUTODREAM_OVERLAP_BIN="$root/does-not-exist.sh"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "missing overlap-stats.sh binary is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_empty_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints nothing -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  local stub="$root/overlap-empty.sh"
  printf '#!/bin/bash\nexit 0\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "empty overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_malformed_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints non-JSON -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  local stub="$root/overlap-malformed.sh"
  printf '#!/bin/bash\necho "not json at all"\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "malformed overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

# ---------------------------------------------------------------------------

[ -x "$RUN" ]  || { echo "FATAL: $RUN not executable"; exit 1; }
[ -x "$MOCK" ] || { echo "FATAL: $MOCK not executable"; exit 1; }

echo "cc-autodream integration tests (mock claude)"
echo
test_happy
test_session_stats
test_unreadable
test_incomplete
test_idempotent
test_revalidates_garbage
test_no_sessions
test_framing
test_changelog
test_prune_helper
test_self_session_excluded
test_skip_empty_sessions
test_skip_empty_disabled
test_l1_retry
test_idempotency_guard
test_self_audit_stats
test_self_audit_stats_failure_denominator
test_self_audit_stats_precached_disambiguation
test_normalize_project
test_slim_transcript
test_facet_fields_plumbed
test_noise_gate_trivial
test_noise_gate_short_duration
test_noise_gate_subagent_carveout
test_noise_gate_stats
test_noise_gate_env_override
test_oversized_gate_zero
test_oversized_gate_total
test_oversized_gate_errored
test_stats_sidecar_ok
test_stats_sidecar_missing_counted
test_stats_sidecar_missing_keeps_oversized_count
test_stats_sidecar_malformed_counted
test_stats_sidecar_non_numeric_counted
test_runner_provenance
test_runner_provenance_no_git
test_runner_provenance_through_symlink
test_runner_provenance_relative_symlink
test_runner_provenance_unresolvable_chain
test_oversized_gate_script
test_oversized_gate_script_open
test_oversized_gate_script_empty
test_oversized_gate_script_args
test_notify_count
test_notify_open_command
test_notify_dryrun
test_runner_dirty_ignores_untracked
test_overlap_pair
test_overlap_triple
test_overlap_none
test_overlap_not_measured_missing_bin
test_overlap_not_measured_empty_output
test_overlap_not_measured_malformed_output
test_notes_no_surfaces
test_notes_from_notes_file
test_notes_from_vault_inbox
test_notes_vault_expired_dropped
test_notes_vault_archived_after_report
test_notes_vault_not_archived_without_report
test_notes_vault_report_published
test_notes_vault_unreadable_note_stays
test_config_file_sourced
test_config_env_wins_over_config
test_notes_header_only_file_does_not_abort
test_notes_icloud_placeholder_is_counted
test_notes_placeholder_and_real_file_counted_once
test_notes_expiry_uses_report_date
test_force_rebuild_failed_l2_does_not_consume
test_unmovable_stale_report_disarms_consuming
test_partial_report_does_not_consume
test_partial_report_keeps_previous
test_partial_report_does_not_block_retry
test_complete_report_retires_partials
test_dead_stdout_does_not_kill_the_run
test_unassembled_dates_are_surfaced
test_unassembled_ignores_a_finished_date
test_no_sessions_stub_carries_marker
test_old_date_reprocess_does_not_consume
test_config_unbound_var_does_not_kill_run
# ---- Multi-root session scanning (SESSION_ROOTS) + root-probe ----

# A run that scans more than one projects dir: primary + one alt, both holding sessions
# touched into the target day. Works by NOT exporting PROJECTS_DIR (so autodetect runs)
# and overriding HOME into the sandbox so root-probe discovers the sandbox's claude dirs
# rather than the host's.
run_dream_autodetect(){ # $1=root — like run_dream but with HOME inside the sandbox, no PROJECTS_DIR
  AUTODREAM_GC=0 AUTODREAM_CHANGELOG=0 OMP_BIN="$MOCK" \
  AUTODREAM_CONFIG="$1/autodream/config" \
  AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  HOME="$1/home" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
}
setup_env_altroot(){ # like setup_env, but with HOME inside the sandbox; uses OMP session store path
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/home/.omp/agent/sessions/proj-a" \
           "$root/autodream" "$root/dreams" "$root/cap"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$root/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$root/autodream/PROMPT.md"
  printf '%s' "$root"
}
mk_session_in(){ # $1=dir $2=name — OMP transcript shape
  local f="$1/$2.jsonl"
  printf '%s\n' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"start the task"}]}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"keep going"}]}}' \
    '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Read","intent":"read"}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}

# Mark an alt root as decided-index so probe_roots scans it.
decide_index(){ # $1=root-dir — writes $AUTODREAM_DIR/root-choices.conf
  mkdir -p "$1/autodream"
  printf '%s=index\n' "$2" >> "$1/autodream/root-choices.conf"
}

# ---- OMP single-root autodetect: HOME inside the sandbox, no PROJECTS_DIR ----
# The OMP port collapsed Claude's multi-profile dirs (~/.claude-ds4/projects,
# ~/.claude-sigint/projects) into ONE session store: $HOME/.omp/agent/sessions.
# These tests assert the ported reality: root-probe autodetects that single root
# under a sandboxed HOME, run.sh triages sessions found there, and no stale
# Claude-profile dirs are flagged. Multi-root discovery was removed by design.
test_omp_singleroot_autodetect(){
  echo "# single-root: OMP session store under sandbox HOME is autodetected and triaged"
  local root; root=$(setup_env_altroot)
  mk_session_in "$root/home/.omp/agent/sessions/proj-a" s1
  run_dream_autodetect "$root"
  local fdir="$root/autodream/findings/$DATE"
  assert_grep "$root/run.out" "session roots: $root/home/.omp/agent/sessions" "probe_roots resolved the OMP session store"
  assert_file "$fdir/$(printf '%s' "$root/home/.omp/agent/sessions/proj-a/s1.jsonl" | shasum | cut -c1-12).json" "session in the OMP store has a findings JSON"
  assert_grep "$fdir/sessions.txt.raw" "$root/home/.omp/agent/sessions/proj-a/s1.jsonl" "OMP store session enumerated"
  assert_grep "$fdir/run-stats.txt" "session_roots: 1" "run-stats reports the single OMP root"
  # The primary root is never flagged as unindexed.
  assert_nogrep "$fdir/unindexed-roots.txt" "$root/home/.omp/agent/sessions" "the OMP root is never flagged"
  rm -rf "$root"
}

test_omp_singleroot_empty_store_no_abort(){
  echo "# single-root: an absent OMP session store does not abort (autodetect falls back cleanly)"
  local root; root=$(setup_env_altroot)
  run_dream_autodetect "$root"
  local fdir="$root/autodream/findings/$DATE"
  assert_file "$fdir/sessions.txt.raw" "sessions.txt.raw written (empty store, empty list)"
  assert_file "$root/dreams/$DATE.md" "stub report written for an empty store"
  rm -rf "$root"
}

# ---- root-probe.sh unit tests (no run.sh) ----
rp(){ AUTODREAM_DIR="$T/ad" HOME="$T/home" "$REPO/bin/root-probe.sh" "$@"; }

test_rootprobe_remembers_choice(){
  echo "# root-probe: --default-index on the single OMP root records nothing unasked, stays idempotent"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.omp/agent/sessions" "$T/ad"
  rp --default-index >/dev/null 2>&1
  # The OMP session store is the always-index primary root; with no unasked roots,
  # --default-index writes no choice lines.
  assert_no_file "$T/ad/root-choices.conf" "no choice file written (only the always-index primary root exists)"
  # The primary root is reported as index and consolidated without a choice file.
  local out; out=$(rp --list 2>&1)
  assert_grep <(printf '%s' "$out") "$T/home/.omp/agent/sessions" "the OMP root is listed"
  assert_grep <(printf '%s' "$out") "index" "the OMP root is reported as index"
  out=$(rp --consolidated 2>&1)
  assert_eq "$out" "$T/home/.omp/agent/sessions" "consolidated emits the single OMP root"
  rm -rf "$T"
}

test_rootprobe_no_write_mode_flags_but_does_not_write(){
  echo "# root-probe: nightly mode (no --ask/--default-index) flags but never writes choices"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.omp/agent/sessions" "$T/ad"
  rp --unindexed >/dev/null 2>&1 || true
  assert_no_file "$T/ad/root-choices.conf" "no choice file written by a nightly-mode run"
  rm -rf "$T"
}

test_rootprobe_empty_home(){
  echo "# root-probe: a machine with no claude dirs at all must not abort (empty roots, set -u)"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home" "$T/ad"
  # Capture the exit code before any `|| true` swallows it.
  local out rc
  out=$(HOME="$T/home" AUTODREAM_DIR="$T/ad" "$REPO/bin/root-probe.sh" --list 2>&1)
  rc=$?
  assert_eq "$rc" "0" "root-probe --list exits 0 with no claude dirs (got $rc)"
  local n; n=$(printf '%s\n' "$out" | grep -c .)
  assert_eq "$n" "0" "no roots are listed (got $n)"
  out=$(HOME="$T/home" AUTODREAM_DIR="$T/ad" "$REPO/bin/root-probe.sh" --consolidated 2>&1)
  rc=$?
  assert_eq "$rc" "0" "root-probe --consolidated exits 0 with no claude dirs (got $rc)"
  rm -rf "$T"
}

# ---- run the new tests ----
test_omp_singleroot_autodetect
test_omp_singleroot_empty_store_no_abort
test_rootprobe_remembers_choice
test_rootprobe_no_write_mode_flags_but_does_not_write
test_rootprobe_empty_home

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
