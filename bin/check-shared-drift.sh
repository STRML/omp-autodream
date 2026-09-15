#!/bin/bash
# Fail when a script this repo shares verbatim with its sibling has drifted.
#
# WHY THIS EXISTS
#
# cc-autodream and omp-autodream are separate repos with separate installs
# (~/.claude/autodream and ~/.omp/agent/autodream), and both are live on this host at
# once. Most of the code has genuinely diverged — run.sh differs by ~1000 code lines,
# because omp-autodream is a port, not a copy. But a handful of helpers are byte-identical
# by intent, and a fix to one of those is a fix only half-delivered.
#
# That is not hypothetical. On 2026-09-11 the X bookmarks queryId walk was fixed in
# omp-autodream after X moved to 16-character webpack chunk hashes. The identical file in
# cc-autodream was never touched, so that install kept failing every night. Its reports
# said `x_queryid_source: failed` ten nights running and asked about it six times before
# anyone noticed the fix had landed in one repo only. Nothing in either repo could have
# told you: each one's tests passed, because each one was internally consistent.
#
# WHAT IT COMPARES
#
# Only the files named in shared-with-sibling.txt, and only their code. FULL-LINE comments
# are stripped before the compare, so each repo can date its own incident notes in a
# comment block without tripping this.
#
# Inline trailing comments are NOT stripped, and that is deliberate rather than an
# oversight: `sed 's/#.*//'` cannot tell a comment from a `#` inside a string or a regex,
# and silently corrupting the thing you are diffing is worse than being slightly strict.
# So `foo  # note` differing from `foo  # other note` DOES report drift. For files that
# are meant to be identical that is the right answer anyway — port the comment too.
#
# WHEN THE SIBLING IS ABSENT
#
# It reports SKIPPED and exits 0, loudly, naming the path it looked for. This check is
# only meaningful on a machine holding both checkouts; in CI it cannot run at all. That is
# the repo's standing rule about degraded measurements — say so rather than reading as a
# pass. A silent skip here would be worse than no check, because it would look green on
# exactly the setup it cannot inspect.
#
# Usage:
#   check-shared-drift.sh            # compare against the auto-detected sibling
#   AUTODREAM_SIBLING_REPO=<path> check-shared-drift.sh
# Exit: 0 ok or skipped, 1 drift found, 2 manifest missing/unreadable.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/shared-with-sibling.txt"
SELF_NAME="$(basename "$REPO_ROOT")"

[ -r "$MANIFEST" ] || { echo "check-shared-drift: no manifest at $MANIFEST" >&2; exit 2; }

# The sibling is the other repo of the pair. Auto-detect by name next to this checkout,
# because that is how they live on this host; override for any other layout.
# A git worktree has a directory name of its own (omp-autodream-pr25), so name the checkout
# by its main working tree, which git reports as the parent of the common .git dir. A name
# that is still unknown is a check that cannot run here, which is a loud skip, not a
# failure: exiting 2 failed the whole suite in every worktree.
BASE_DIR="$(dirname "$REPO_ROOT")"
common_git="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" || common_git=""
case "$common_git" in
  '') ;;
  /*) ;;
  *) common_git="$REPO_ROOT/$common_git" ;;
esac
if [ -n "$common_git" ] && [ "$(basename "$common_git")" = ".git" ]; then
  main_root="$(cd "$(dirname "$common_git")" 2>/dev/null && pwd)" || main_root=""
  if [ -n "$main_root" ]; then
    SELF_NAME="$(basename "$main_root")"
    BASE_DIR="$(dirname "$main_root")"
  fi
fi
if [ -n "${AUTODREAM_SIBLING_REPO:-}" ]; then
  SIBLING="$AUTODREAM_SIBLING_REPO"
else
  case "$SELF_NAME" in
    omp-autodream) SIBLING="$BASE_DIR/cc-autodream" ;;
    cc-autodream)  SIBLING="$BASE_DIR/omp-autodream" ;;
    *)
      echo "check-shared-drift: SKIPPED — cannot infer the sibling for '$SELF_NAME'; set AUTODREAM_SIBLING_REPO"
      echo "  This check has verified nothing."
      exit 0
      ;;
  esac
fi

if [ ! -d "$SIBLING" ]; then
  echo "check-shared-drift: SKIPPED — sibling repo not found at $SIBLING"
  echo "  This check only runs where both checkouts exist. It has verified nothing."
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
strip_comments() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }

drift=0 checked=0 missing=0
while IFS= read -r rel; do
  case "$rel" in ''|\#*) continue ;; esac
  mine="$REPO_ROOT/$rel"; theirs="$SIBLING/$rel"
  if [ ! -f "$mine" ] || [ ! -f "$theirs" ]; then
    echo "DRIFT  $rel — missing on one side (this: $([ -f "$mine" ] && echo yes || echo no), sibling: $([ -f "$theirs" ] && echo yes || echo no))"
    missing=$(( missing + 1 )); drift=$(( drift + 1 )); continue
  fi
  # strip_comments hides read errors, so two unreadable files used to strip to two empty
  # outputs and compare equal (Codex review of 232c94c). Unread is unverified: call it drift.
  if [ ! -r "$mine" ] || [ ! -r "$theirs" ]; then
    echo "DRIFT  $rel — unreadable on one side (this: $([ -r "$mine" ] && echo yes || echo no), sibling: $([ -r "$theirs" ] && echo yes || echo no))"
    drift=$(( drift + 1 )); continue
  fi
  strip_comments "$mine"   > "$TMP/a"
  strip_comments "$theirs" > "$TMP/b"
  checked=$(( checked + 1 ))
  if ! diff -q "$TMP/a" "$TMP/b" >/dev/null 2>&1; then
    n=$(diff "$TMP/a" "$TMP/b" | grep -c '^[<>]')
    echo "DRIFT  $rel — $n code line(s) differ from $SIBLING/$rel"
    drift=$(( drift + 1 ))
  fi
done < "$MANIFEST"

if [ "$drift" -gt 0 ]; then
  echo
  echo "$drift shared file(s) have drifted from $SELF_NAME's sibling."
  echo "Port the change to $SIBLING (or drop the file from $MANIFEST if the two are"
  echo "meant to diverge now). A fix in one repo is half a fix while both installs run."
  exit 1
fi

echo "check-shared-drift: ok — $checked shared file(s) match $SIBLING"
exit 0
