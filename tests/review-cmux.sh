#!/bin/bash
# Tests for bin/review.sh's cmux triage-surface launch path.
#
# Drives the real review.sh against fixture reports with a mock cmux binary,
# and asserts on the same-day dedup marker contract: only one workspace opens
# per report, a failed create releases the claim, --force bypasses it, and the
# marker binds to the report's mtime (a rebuilt report gets a fresh marker).
# No network, no model calls, and crucially no real cmux workspace.
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
  mkdir -p "$root/dreams"
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

# Run review.sh against the mock cmux with a pinned downstream date (2020-01-02,
# same fixture dates as review-skip.sh) and an install-dir marker forest in the
# sandbox. AUTODREAM_DIR must be set to the sandbox dir so review.sh's same-day
# marker lands inside the sandbox — unset, it would derive from $0 and fall to
# the real ~/.claude/autodream, writing the claim into the host's install dir.
# AUTODREAM_CONFIG pins the load of the host's own config (surface=cmux) out of
# the picture: we set the surface explicitly below.
run_review(){ # $1=root ; rest = args
  local root="$1"; shift
  AUTODREAM_DIR="$root/autodream" \
  AUTODREAM_CONFIG="$root/nonexistent-config" \
  AUTODREAM_TRIAGE_SURFACE=cmux \
  CMUX_BIN="$root/cmux-mock.sh" \
  CMUX_LOG="$root/cmux.log" \
  DREAMS_DIR="$root/dreams" \
  bash "$REVIEW" "$@" > "$root/out" 2>&1
}

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

# First trigger opens exactly one workspace and stamps the marker. The marker
# path is LOGS_DIR/review-launched-$DATE-$REPORT_MTIME — the report mtime is the
# discriminator, so a rebuilt report (new mtime) must NOT be swallowed by a
# stale marker (see marker_binds_to_report probe below).
test_first_trigger_opens_workspace(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 1 "first trigger calls cmux exactly once"
  local mtime; mtime=$(stat -f %m "$root/dreams/2020-01-02.md")
  local marker="$root/autodream/logs/review-launched-2020-01-02-$mtime"
  [ -d "$marker" ] && ok "marker stamped with date+report mtime ($marker)" \
    || no "marker dir not found at $marker"
}

# Second trigger same date + same report mtime must be deduped: no second cmux
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

# --force must bypass the marker even when a fresh claim is sitting there.
test_force_bypasses_marker(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02                     # stamps marker, 1 create
  local before; before=$(cmux_calls "$root")
  run_review "$root" --force 2020-01-02
  assert_eq "$(cmux_calls "$root")" "$((before + 1))" "--force opens despite the existing marker"
}

# A failed create must release the claim (rmdir) so the next trigger retries,
# and must exit non-zero so a scheduled job can't think the triage happened.
test_failed_create_releases_marker(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  local rc=0
  AUTODREAM_DIR="$root/autodream" \
  AUTODREAM_CONFIG="$root/nonexistent-config" \
  AUTODREAM_TRIAGE_SURFACE=cmux \
  CMUX_BIN="$root/cmux-mock.sh" \
  CMUX_LOG="$root/cmux.log" \
  CMUX_EXIT=1 \
  DREAMS_DIR="$root/dreams" \
  bash "$REVIEW" 2020-01-02 > "$root/out" 2>&1 || rc=$?
  assert_eq "$rc" 1 "failed create exits non-zero"
  local mtime; mtime=$(stat -f %m "$root/dreams/2020-01-02.md")
  [ ! -e "$root/autodream/logs/review-launched-2020-01-02-$mtime" ] \
    && ok "failed create leaves no marker behind" \
    || no "failed create left a marker"
  assert_grep "$root/out" 'cmux workspace create failed' "failure names cmux"
  # Retry after the failure must succeed (claim was released, not latched). The
  # log holds the failed create line plus the retried one, hence 2.
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 2 "retry after failure opens the workspace"
}

# The marker binds to the report's mtime: rebuild the report (different mtime)
# and a normal review must open again, not be swallowed by the old marker.
test_marker_binds_to_report_mtime(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  run_review "$root" 2020-01-02                      # stamps marker for mtime A
  # Rebuild: same DATE basename, forced different mtime.
  mk_report "$root" 2020-01-02 'completely rewritten report body' >/dev/null
  touch -t 202006151200 "$root/dreams/2020-01-02.md"  # any distinct later stamp
  run_review "$root" 2020-01-02
  assert_eq "$(cmux_calls "$root")" 2 "rebuilt report (new mtime) opens again"
  # The old marker (from the first run) is a different directory; the assert
  # above already proves a second create happened, which is only possible if the
  # marker name differed. Confirm the new marker landed.
  local mtimeA
  mtimeA=$(stat -f %m "$root/dreams/2020-01-02.md")       # current (rebuilt) mtime
  [ -d "$root/autodream/logs/review-launched-2020-01-02-$mtimeA" ] \
    && ok "new marker stamped for rebuilt report" \
    || no "new marker missing for rebuilt report"
}

# Stale markers get reaped so the marker forest cannot grow unbounded. A marker
# older than 14 days must be deleted when review.sh runs.
test_stale_markers_are_pruned(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  mkdir -p "$root/autodream/logs"
  local stale="$root/autodream/logs/review-launched-2000-01-01-0"
  mkdir -p "$stale"
  touch -t 200001010000 "$stale"           # 2000 → far older than 14 days
  run_review "$root" 2020-01-02
  [ ! -e "$stale" ] && ok "stale marker (>14d) reaped" \
    || no "stale marker still present"
}

# The dedup key is (date, report mtime). Two different dates must never share a
# marker even when their reports carry the same mtime — otherwise the second
# date's triage would be silently swallowed the moment the first date opened.
test_different_dates_with_same_mtime_do_not_collide(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-01 "$REPORT_OPEN"
  mk_report "$root" 2020-01-02 "$REPORT_OPEN"
  local stamp="202002021200"
  touch -t "$stamp" "$root/dreams/2020-01-01.md"
  touch -t "$stamp" "$root/dreams/2020-01-02.md"   # identical mtimes
  run_review "$root" 2020-01-01                      # 1 create, marker for 01
  run_review "$root" 2020-01-02                      # same mtime, different date
  assert_eq "$(cmux_calls "$root")" 2 "different dates, same mtime, both open"
}

# ---------------------------------------------------------------------------

[ -x "$REVIEW" ] || { echo "FATAL: $REVIEW not executable"; exit 1; }

echo "cc-autodream review.sh cmux-surface tests (mock cmux)"
echo
test_first_trigger_opens_workspace
test_second_trigger_is_deduped
test_force_bypasses_marker
test_failed_create_releases_marker
test_marker_binds_to_report_mtime
test_stale_markers_are_pruned
test_different_dates_with_same_mtime_do_not_collide
echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
