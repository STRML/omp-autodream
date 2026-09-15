#!/usr/bin/env bash
# Decide which launchd label this install owns.
#
# install.sh and bin/autodream-now.sh both need this answer, and while they
# derived it separately they derived it wrong the same way: any plist whose
# body mentioned run.sh was treated as ours. On a host that already ran
# cc-autodream, installing omp-autodream therefore adopted the Claude label and
# rewrote that job in place. Nothing failed loudly - the OMP job ran fine every
# night while Claude-side triage sat dead for 18 days (#14).
#
# Ownership is decided by the runner a plist actually invokes, not by the label
# it carries and not by AUTODREAM_DIR (a hand-written plist may have no
# environment block, but it always names its program).
#
# Usage: scheduler-label.sh <install-dir>
#   stdout  the base label, on every path; the -review and .ondemand siblings
#           suffix it
#   exit 0  label decided
#   exit 3  the default label is held by a plist running a different install.
#           stdout still carries that label. That other install builds the same
#           "<label>.ondemand", so autodream-now adds a per-install suffix on this
#           status rather than share it. A caller that would WRITE the plist -
#           install.sh - must abort on this status instead of overwriting.
#
# Env: LAUNCH_AGENTS_DIR, PLISTBUDDY (tests point these at a sandbox).

set -euo pipefail

TARGET="${1:?usage: scheduler-label.sh <install-dir>}"
LA_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

# A trailing slash, or a symlink anywhere in the path, makes the string compare
# below miss our own plist. The miss is invisible: it yields a fresh label on
# every re-install instead of an error.
norm_dir() {
  local d="${1%/}"
  ( cd "$d" 2>/dev/null && pwd -P ) || printf '%s\n' "$d"
}

TARGET_REAL="$(norm_dir "$TARGET")"
DEFAULT_LABEL="com.$(id -un | tr -dc 'a-zA-Z0-9').omp-autodream"

# The directory of the run.sh a plist invokes, or non-zero if it invokes none.
# ProgramArguments is short (bash, script, at most a -c form), so a fixed walk
# beats parsing the whole array.
runner_dir_of() {
  local plist="$1" i arg
  for i in 0 1 2 3 4 5; do
    arg="$("$PLISTBUDDY" -c "Print :ProgramArguments:$i" "$plist" 2>/dev/null)" || break
    case "$arg" in
      */run.sh) norm_dir "$(dirname "$arg")"; return 0 ;;
    esac
  done
  return 1
}

label=""
conflict=""
# Every plist, not just *autodream*.plist. launchd keys a job by its Label, never
# by its filename, so a foreign job holding the default label in backup.plist is
# still the job install.sh would boot out and overwrite. The same goes for our own
# job renamed to a file without "autodream" in it: a name-based glob missed both.
for plist in "$LA_DIR"/*.plist; do
  [ -e "$plist" ] || continue
  l="$("$PLISTBUDDY" -c 'Print :Label' "$plist" 2>/dev/null)" || continue
  # .ondemand is autodream-now's transient sibling. It writes that plist to
  # $AUTODREAM_DIR rather than here, so this glob does not normally see one;
  # the skip is for a copy someone dropped in by hand, where adopting it would
  # nest a second .ondemand suffix onto the label. It goes by Label, not filename:
  # a foreign job holding the default label in backup.ondemand.plist is still a
  # conflict (Codex review of 0129fc0).
  case "$l" in *.ondemand) continue ;; esac
  if rdir="$(runner_dir_of "$plist")" && [ "$rdir" = "$TARGET_REAL" ]; then
    # Our own prior install. Keep its label so a re-install stays idempotent
    # even when that label is not the default one.
    label="$l"
    break
  fi
  # The default label held by anything that is not our runner is a conflict,
  # including a job that runs no run.sh at all.
  [ "$l" = "$DEFAULT_LABEL" ] && conflict="$plist"
done

if [ -n "$label" ]; then
  printf '%s\n' "$label"
  exit 0
fi

if [ -n "$conflict" ]; then
  printf 'scheduler-label: %s is already scheduled by %s, which runs a different install.\n' \
    "$DEFAULT_LABEL" "$conflict" >&2
  printf 'scheduler-label: refusing to overwrite it. Give that job a distinct label, or re-run with --no-schedule.\n' >&2
  printf '%s\n' "$DEFAULT_LABEL"
  exit 3
fi

printf '%s\n' "$DEFAULT_LABEL"
