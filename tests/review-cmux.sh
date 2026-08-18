#!/bin/bash
# Tests for bin/review.sh's cmux triage-surface launch path.
#
# Drives the real review.sh against fixture reports with a mock cmux binary,
# and asserts on the same-day dedup marker contract: only one workspace opens
# per report, a failed create releases the claim, --force bypasses it, and the
# marker binds to the report's content digest (a rebuilt report gets a fresh
# marker). No network, no model calls, and crucially no real cmux workspace.
#
# The marker scheme under test:
#   claim dir    $LOGS_DIR/review-launched-$DATE-$DIGEST     (atomic mkdir)
#   confirmed    $LOGS_DIR/review-launched-$DATE-$DIGEST.confirmed (written
#                only after cmux returns success — dedup keys on THIS, so an
#                unconfirmed claim can age out and be reclaimed)
#   legacy file  $LOGS_DIR/review-launched-$DATE   (round-1 touch-marker,
#                migrated into a confirmed token on first run)
#
# The mock cmux (like the mock claude in review-skip.sh) records that it was
# invoked and can be told to fail. review.sh runs cmux as
# `"$CMUX" workspace create --name ... --command ...`, so the mock only needs
# to accept that shape and echo a workspace ref back (the tab-title rename loop
# that follows runs `"$CMUX" tab-action ...` in a detached background block —
# the mock handles it as a no-op, and review.sh never waits on it).
#
# Usage:  tests/review-cmux.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
REVIEW="$REPO/bin/review.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
assert_grep(){ grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){ grep -q -- "$2" "$1" 2>/dev/null && no "$3 (/ $2 / unexpectedly in $1)" || ok "$3"; }

# Sandbox: a dreams/ dir plus a mock cmux that records invocations. The mock
# exits with CMUX_EXIT (default 0) and prints a workspace ref like the real
# tool does, so the WS_REF parse in review.sh is exercised too.
setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccrevcmux.XXXXXX")
  mkdir -p "$root/dreams" "$root/autodream"
  cat > "$root/cmux-mock.sh" <<'MOCK'
#!/bin/bash
# Mock cmux: log every argv to the file named by CMUX_LOG, then act on the
# subcommand. workspace create is the only interesting one; tab-action (the
# rename loop) and anything else is a silent no-op.
echo "$@" >> "$CMUX_LOG"
case "$1" in
  workspace)
    [ "${CMUX_EXIT:-0}" -eq 0 ] || exit "${CMUX_EXIT}"
    echo "workspace:42"
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$root/cmux-mock.sh"
  : > "$root/cmux.log"
  printf '%s' "$root"
}

mk_report(){ # $1=root $2=date $3=body
  printf '%s\n' "$3" > "$1/dreams/$2.md"
}

# The marker path review.sh will use for a given report: claim dir keyed by
# content digest, confirmed as a sibling token.
marker_dir(){ # $1=root $2=date
  local key; key=$(shasum -a 256 "$1/dreams/$2.md" | awk '{print $1}')
  printf '%s/autodream/logs/review-launched-%s-%s\n' "$1" "$2" "$key"
}
marker_confirmed(){ printf '%s.confirmed\n' "$(marker_dir "$1" "$2")"; }

# Run review.sh against the mock cmux with a pinned downstream date (2020-01-02,
# same fixture dates as review-skip.sh) and an install-dir marker forest in the
# sandbox. AUTODREAM_DIR must be set to the sandbox dir so review.sh's same-day
# marker lands inside the sandbox — unset, it would derive from $0 and fall to
# the real ~/.claude/autodream, writing the claim into the host's install dir.
# AUTODREAM_CONFIG pins the load of the host's own config (surface=cmux) out of
# the picture: we set the surface explicitly below.
run_review(){ # $1=root ; rest = args ; override env via $REVIEW_ENV
  local root="$1"; shift
  env $REVIEW_ENV \
  AUTODREAM_DIR="$root/autodream" \
  AUTODREAM_CONFIG="$root/nonexistent-config" \
  AUTODREAM_TRIAGE_SURFACE=cmux \
  CMUX_BIN="$root/cmux-mock.sh" \
  CMUX_LOG="$root/cmux.log" \
  DREAMS_DIR="$root/dreams" \
  bash "$REVIEW" "$@" > "$root/out" 2>&1
}
REVIEW_ENV=""

cmux_calls(){ # $1=root — count `workspace create` invocations in the mock log
  # Only count the create line; the rename loop's tab-action lines (detached,
  # 3x sleep 3) may land in the log long after the create returned and would
  # make a raw `wc -l` flaky. grep -c on an empty log prints 0 AND exits 1, so
  # `|| true` (not `|| echo 0`) keeps the single 0 without a duplicate.
  grep -c '^workspace create ' "$1/cmux.log" 2>/dev/null || true
}

# --- fixtures (same shapes review-skip.sh uses) ----------------------------

REPORT_OPEN='# Autodream — 2020-01-02

## Open questions for the user
1. **Thing** — decide X?

<!-- autodream:open-questions=3 -->'

# --- tests -----------------------------------------------------------------

# First trigger opens exactly one workspace and stamps the confirmed token. The
# marker key is the content digest: a rebuilt report (new digest) must NOT be
# swallowed by a stale marker (see marker_binds_to_report below).
test_first_trigger_opens_workspace(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 1 "first trigger calls cmux exactly once"
  local dir; dir=$(marker_dir "$root" 2020-01-02)
  local conf; conf=$(marker_confirmed "$root" 2020-01-02)
  [ -d "$dir" ] && ok "claim dir stamped ($(basename "$dir"))" \
    || no "claim dir not found at $dir"
  [ -f "$conf" ] && ok "confirmed token written after successful create" \
    || no "confirmed token missing at $conf"
}

# Second trigger same date + same report digest must be deduped: no second cmux
# call, exit 0, and a notice pointing at --force.
test_second_trigger_is_deduped(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 1 "second trigger does not open a second workspace"
  local rc=0
  AUTODREAM_DIR="$root/autodream" \
  AUTODREAM_CONFIG="$root/nonexistent-config" \
  AUTODREAM_TRIAGE_SURFACE=cmux \
  CMUX_BIN="$root/cmux-mock.sh" \
  CMUX_LOG="$root/cmux.log" \
  DREAMS_DIR="$root/dreams" \
  bash "$REVIEW" 2020-01-02 > "$root/out2" 2>&1 || rc=$?
  assert_eq "$rc" 0 "deduped trigger still exits 0"
  assert_grep "$root/out2" 'triage already launched for this report' "dedup notice names the date"
  assert_grep "$root/out2" '\-\-force' "dedup notice offers --force"
}

# --force must bypass the marker even when a fresh confirmed token is sitting
# there. It must ALSO stamp its own confirmed token on a first-ever force run
# (round-3 finding 1: gating the write on CLAIMED meant a first force launch
# left no token, so the next scheduled trigger opened a duplicate workspace).
test_force_bypasses_marker(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  local before; before=$(cmux_calls "$root")
  run_review "$root" --force 2020-01-02              # first run is a force
  assert_eq "$(cmux_calls "$root")" "$((before + 1))" "--force opens despite the marker"
  [ -f "$(marker_confirmed "$root" 2020-01-02)" ] \
    && ok "--force stamps its own confirmed token" \
    || no "--force left no confirmed token (next trigger would re-pop)"
  # The stamped token must then dedup the routine trigger.
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" "$((before + 1))" "token stamped by --force dedups the next trigger"
}

# A failed create must release the claim (rmdir) so the next trigger retries,
# and must exit non-zero so a scheduled job can't think the triage happened.
test_failed_create_releases_marker(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  local rc=0
  REVIEW_ENV="CMUX_EXIT=1" run_review "$root" 2020-01-02 || rc=$?
  assert_eq "$rc" 1 "failed create exits non-zero"
  local dir; dir=$(marker_dir "$root" 2020-01-02)
  [ ! -e "$dir" ] && ok "failed create leaves no claim dir behind" \
    || no "failed create left a claim dir"
  [ ! -e "$(marker_confirmed "$root" 2020-01-02)" ] \
    && ok "failed create leaves no confirmed token" \
    || no "failed create left a confirmed token"
  assert_grep "$root/out" 'cmux workspace create failed' "failure names cmux"
  # Retry after the failure must succeed (claim was released, not latched). The
  # log holds the failed create line plus the retried one, hence 2.
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 2 "retry after failure opens the workspace"
}

# The marker binds to the report's content digest: rebuild the report (new
# digest) and a normal review must open again, not be swallowed by the old
# marker.
test_marker_binds_to_report_digest(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02                      # stamps confirmed for digest A
  mk_report "$root" 2020-01-02 'completely rewritten report body' >/dev/null
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 2 "rebuilt report (new digest) opens again"
  [ -f "$(marker_confirmed "$root" 2020-01-02)" ] \
    && ok "new confirmed token stamped for rebuilt report" \
    || no "new confirmed token missing for rebuilt report"
}

# Stale claims and confirmed tokens get reaped so the marker forest cannot grow
# unbounded. A claim dir + token older than 14 days must be deleted when
# review.sh runs. The confirmed token is created inside cls... as a sibling
# file, so the prune must be able to delete both the (empty) claim dir and its
# token — a `-delete` prune that only handles empty dirs would leave the token
# behind, silently.
test_stale_markers_are_pruned(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  mkdir -p "$root/autodream/logs"
  local stale_dir="$root/autodream/logs/review-launched-2000-01-01-olddigest"
  local stale_conf="$stale_dir.confirmed"
  mkdir -p "$stale_dir"
  touch "$stale_conf"
  touch -t 200001010000 "$stale_dir" "$stale_conf"  # 2000 → far older than 14d
  run_review "$root" 2020-01-02
  [ ! -e "$stale_dir" ] && ok "stale claim dir (>14d) reaped" \
    || no "stale claim dir still present"
  [ ! -e "$stale_conf" ] && ok "stale confirmed token (>14d) reaped" \
    || no "stale confirmed token still present"
}

# A confirmed launch past the grace window must STILL be deduped (the age-based
# reclaim only ever looks at *unconfirmed* claims). Aging the confirmed pair
# beyond the 900s grace but under the 14-day forest prune makes MARKER_AGE big
# enough that a naive reclaim would misfire while the (now unconditional) 14-day
# reap does not scavenge the fixture — pinning that confirmation wins over age.
test_confirmed_marker_survives_grace(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02                      # 1 create, confirmed stamped
  local dir; dir=$(marker_dir "$root" 2020-01-02)
  local conf; conf=$(marker_confirmed "$root" 2020-01-02)
  touch -t "$(date -v-2d +%Y%m%d%H%M.%S)" "$dir" "$conf"   # >900s grace, <14d prune
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 1 "confirmed launch is deduped even past the grace window"
}

# An unconfirmed claim that is OLDER than the grace window is an abandoned
# launch (the process died while cmux was blocked). It must be reclaimed so the
# popup can finally open, instead of suppressing triggers forever.
test_abandoned_claim_is_reclaimed(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  local dir; dir=$(marker_dir "$root" 2020-01-02)
  mkdir -p "$dir"
  touch -t "$(date -v-2d +%Y%m%d%H%M.%S)" "$dir"     # unconfirmed, >grace, <14d prune
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 1 "abandoned claim is reclaimed and the popup opens"
  assert_grep "$root/out" 'reclaiming abandoned claim' "reclaim is reported"
  [ -f "$(marker_confirmed "$root" 2020-01-02)" ] \
    && ok "reclaimed claim ends with a fresh confirmed token" \
    || no "reclaimed claim has no confirmed token"
}

# An unconfirmed claim that is YOUNG is a launch still in progress by another
# trigger — the popup must not open twice while the first is still starting.
test_in_progress_claim_suppresses(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  local dir; dir=$(marker_dir "$root" 2020-01-02)
  mkdir -p "$dir"                                    # fresh, unconfirmed
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 0 "young unconfirmed claim suppresses a concurrent trigger"
  assert_grep "$root/out" 'already in progress' "in-progress notice is emitted"
}

# Users upgrading from the round-1 code have a touch-created FILE
# review-launched-$DATE (date-only key). It must be honored as a real launch
# AND migrated into a confirmed token, so the same report doesn't pop up a
# second workspace right after upgrade.
test_legacy_marker_is_migrated(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  mkdir -p "$root/autodream/logs"
  touch "$root/autodream/logs/review-launched-2020-01-02"
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 0 "legacy marker suppresses a duplicate launch"
  assert_grep "$root/out" 'migrating legacy marker' "migration is reported"
  [ -f "$(marker_confirmed "$root" 2020-01-02)" ] \
    && ok "legacy marker becomes a confirmed token" \
    || no "legacy marker was not migrated"
  [ ! -e "$root/autodream/logs/review-launched-2020-01-02" ] \
    && ok "legacy marker file no longer lingers" \
    || no "legacy marker file still present"
}

# The scheduled review job forces AUTODREAM_TRIAGE_SURFACE=cmux. If cmux is
# missing, review.sh must fail non-zero (no headless inline claude from a
# launchd job) when stdin is not a TTY — a manual terminal still gets the
# inline fallback.
test_headless_missing_cmux_fails(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  local rc=0
  # `</dev/null` makes stdin non-interactive, like a launchd job.
  env AUTODREAM_DIR="$root/autodream" \
      AUTODREAM_CONFIG="$root/nonexistent-config" \
      AUTODREAM_TRIAGE_SURFACE=cmux \
      CMUX_BIN="$root/nonexistent-cmux" \
      DREAMS_DIR="$root/dreams" \
      PATH="$root:/usr/bin:/bin" \
      bash "$REVIEW" 2020-01-02 < /dev/null > "$root/out" 2>&1 || rc=$?
  assert_eq "$rc" 1 "headless run with missing cmux exits non-zero"
  assert_grep "$root/out" 'not a TTY' "headless guard names the TTY condition"
  assert_nogrep "$root/out" 'falling back to inline' "headless run does not fall back to inline"
}

# Interactive terminal (stdin is a TTY) with missing cmux keeps the inline
# fallback, so a manual `review.sh` on a cmux-less host still triages inline.
test_interactive_missing_cmux_falls_back_inline(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  # A pseudo-TTY keeps `[ -t 0 ]` true even with a redirected command.
  local rc=0
  env AUTODREAM_DIR="$root/autodream" \
      AUTODREAM_CONFIG="$root/nonexistent-config" \
      AUTODREAM_TRIAGE_SURFACE=cmux \
      CMUX_BIN="$root/nonexistent-cmux" \
      DREAMS_DIR="$root/dreams" \
      PATH="$root:/usr/bin:/bin" \
      CLAUDE_BIN="$root/cmux-mock.sh" \
      script -q /dev/null bash "$REVIEW" 2020-01-02 > "$root/out" 2>&1 || rc=$?
  assert_eq "$rc" 0 "interactive run with missing cmux exits 0 (inline fallback)"
  assert_grep "$root/out" 'falling back to inline' "interactive run falls back to inline"
}

# A logs dir that can't be created (e.g. a file is in the way) must exit
# non-zero with a real message, not silently pretend the triage was skipped.
test_logs_dir_failure_exits_nonzero(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  mkdir -p "$root/autodream"
  printf 'not a dir\n' > "$root/autodream/logs"      # block the logs dir
  local rc=0
  run_review "$root" 2020-01-02 || rc=$?
  assert_eq "$rc" 1 "uncreatable logs dir exits non-zero"
  assert_grep "$root/out" 'cannot create logs dir' "logs-dir failure is named"
}

# A logs dir that EXISTS but cannot be written (mkdir -p passes, the claim
# mkdir fails) must exit non-zero for the I/O error — not report "already in
# progress" and exit 0, which silently drops triage.
test_unwritable_claim_dir_fails(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  mkdir -p "$root/autodream/logs"
  chmod 500 "$root/autodream/logs"                   # owned+r, not writable
  local rc=0
  env AUTODREAM_DIR="$root/autodream" \
    AUTODREAM_CONFIG="$root/nonexistent-config" \
    AUTODREAM_TRIAGE_SURFACE=cmux \
    CMUX_BIN="$root/cmux-mock.sh" \
    CMUX_LOG="$root/cmux.log" \
    DREAMS_DIR="$root/dreams" \
    bash "$REVIEW" 2020-01-02 > "$root/out" 2>&1 || rc=$?
  chmod 700 "$root/autodream/logs"                   # restore so sandbox can rm
  assert_eq "$rc" 1 "unwritable claim dir exits non-zero (not 'in progress')"
  assert_grep "$root/out" 'cannot create claim' "claim I/O error is named"
  assert_eq "$(cmux_calls "$root")" 0 "no cmux launch when the claim could not be written"
}

# A legacy date-only marker that predates the current report (the date was
# triaged, then the report rebuilt with new content before upgrade) must NOT be
# migrated onto the new digest — that would mark unreviewed content confirmed
# and swallow its triage. The report must open again.
test_legacy_marker_stale_is_not_migrated(){
  local root; root=$(setup_env)
  mkdir -p "$root/autodream/logs"
  # Legacy marker OLDER than the report: touch a stale marker at an ancient
  # mtime, then write the report after it.
  touch -t 202006010000 "$root/autodream/logs/review-launched-2020-01-02"
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 1 "stale legacy marker does not suppress a rebuilt report"
  assert_grep "$root/out" 'predates the current report' "stale legacy marker is reported as not migrated"
  [ -f "$(marker_confirmed "$root" 2020-01-02)" ] \
    && ok "rebuilt report gets its own confirmed token" \
    || no "rebuilt report has no confirmed token"
}

# cmux exiting 0 is the creation contract: confirmation is bound immediately
# even if the stdout ref does not parse (round-4 executor #2: a kill between
# create and confirm, or a stdout-format change, must NEVER let the age-reclaim
# open a duplicate). An empty ref only costs the cosmetic tab-title rename.
test_empty_ref_still_confirms(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  cat > "$root/cmux-noref.sh" <<'MOCK'
#!/bin/bash
echo "$@" >> "$CMUX_LOG"              # log so cmux_calls can count us
echo "created workspace"            # success exit, no workspace:NN ref
exit 0
MOCK
  chmod +x "$root/cmux-noref.sh"
  local rc=0
  env AUTODREAM_DIR="$root/autodream" \
    AUTODREAM_CONFIG="$root/nonexistent-config" \
    AUTODREAM_TRIAGE_SURFACE=cmux \
    CMUX_BIN="$root/cmux-noref.sh" \
    CMUX_LOG="$root/cmux.log" \
    DREAMS_DIR="$root/dreams" \
    bash "$REVIEW" 2020-01-02 > "$root/out" 2>&1 || rc=$?
  assert_eq "$rc" 0 "empty ref on rc-0 still exits 0"
  [ -f "$(marker_confirmed "$root" 2020-01-02)" ] \
    && ok "rc-0 confirm is bound regardless of parseable ref" \
    || no "rc-0 launch left no confirmed token (next trigger could duplicate)"
  # The bind must hold: a second run for the same report dedups.
  env AUTODREAM_DIR="$root/autodream" \
    AUTODREAM_CONFIG="$root/nonexistent-config" \
    AUTODREAM_TRIAGE_SURFACE=cmux \
    CMUX_BIN="$root/cmux-noref.sh" \
    CMUX_LOG="$root/cmux.log" \
    DREAMS_DIR="$root/dreams" \
    bash "$REVIEW" 2020-01-02 > "$root/out2" 2>&1 || rc=$?
  assert_eq "$(cmux_calls "$root")" 1 "confirmed empty-ref launch dedups the next trigger"
  assert_grep "$root/out2" 'already launched for this report' "dedup notice fired"
}

# ---------------------------------------------------------------------------

[ -x "$REVIEW" ] || { echo "FATAL: $REVIEW not executable"; exit 1; }

echo "cc-autodream review.sh cmux-surface tests (mock cmux)"
echo
test_first_trigger_opens_workspace
test_second_trigger_is_deduped
test_force_bypasses_marker
test_failed_create_releases_marker
test_marker_binds_to_report_digest
test_stale_markers_are_pruned
test_confirmed_marker_survives_grace
test_abandoned_claim_is_reclaimed
test_in_progress_claim_suppresses
test_legacy_marker_is_migrated
test_legacy_marker_stale_is_not_migrated
test_headless_missing_cmux_fails
test_interactive_missing_cmux_falls_back_inline
test_logs_dir_failure_exits_nonzero
test_unwritable_claim_dir_fails
test_empty_ref_still_confirms
echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
