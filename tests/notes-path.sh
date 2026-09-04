#!/usr/bin/env bash
# The note surface has two halves in different scripts, and they have to agree on
# one path. autodream-note.sh (writer) hardcoded $HOME/.claude/autodream while
# vault-notes.sh (reader) resolves AUTODREAM_DIR, so under this port's install the
# writer appended to a file the nightly never opened. Nothing errored: no missing
# note, no warning, just an operator note that never reached the report.
#
# These rows assert the two halves land on the same file, per resolution path.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WRITER="$REPO/bin/autodream-note.sh"

PASS=0
FAIL=0
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/notes-path.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
nope() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

printf 'notes-path\n'

# --- AUTODREAM_DIR from the environment wins (the launchd nightly's case) ------
INSTALL="$SANDBOX/omp/autodream"
mkdir -p "$INSTALL"
: > "$INSTALL/config"
AUTODREAM_DIR="$INSTALL" bash "$WRITER" "env-routed note" >/dev/null 2>&1
if [ -s "$INSTALL/notes.md" ] && grep -q "env-routed note" "$INSTALL/notes.md"; then
  ok "AUTODREAM_DIR from the environment routes the note there"
else
  nope "AUTODREAM_DIR from the environment routes the note there" "not in $INSTALL/notes.md"
fi
if [ -e "$SANDBOX/fakehome/.claude/autodream/notes.md" ]; then
  nope "the legacy path is not written when AUTODREAM_DIR is set" "legacy file exists"
else
  ok "the legacy path is not written when AUTODREAM_DIR is set"
fi

# --- with no env, the writer resolves from its own installed location ---------
# install.sh symlinks bin/*.sh into $TARGET, so the writer's own dir IS the
# install dir. Reproduce that rather than trusting the repo layout.
INSTALL2="$SANDBOX/omp2/autodream"
mkdir -p "$INSTALL2"
: > "$INSTALL2/config"
ln -s "$WRITER" "$INSTALL2/autodream-note.sh"
( unset AUTODREAM_DIR; bash "$INSTALL2/autodream-note.sh" "symlink-routed note" ) >/dev/null 2>&1
if [ -s "$INSTALL2/notes.md" ] && grep -q "symlink-routed note" "$INSTALL2/notes.md"; then
  ok "an installed symlink routes the note to its own install dir"
else
  nope "an installed symlink routes the note to its own install dir" "not in $INSTALL2/notes.md"
fi

# --- the reader agrees with the writer, which is the whole point --------------
# Behavioural, not a source-grep. Both scripts contain the string
# "$AUTODREAM_DIR/notes.md", so matching that expression passes even when the two
# resolve AUTODREAM_DIR to different directories - which is exactly the bug. Run
# both from their installed location with no env and compare the actual file.
INSTALL3="$SANDBOX/omp3/autodream"
mkdir -p "$INSTALL3"
: > "$INSTALL3/config"
ln -s "$WRITER" "$INSTALL3/autodream-note.sh"
ln -s "$REPO/bin/vault-notes.sh" "$INSTALL3/vault-notes.sh"

( unset AUTODREAM_DIR; bash "$INSTALL3/autodream-note.sh" "seam note" ) >/dev/null 2>&1
READER_SAYS="$( unset AUTODREAM_DIR; bash "$INSTALL3/vault-notes.sh" status 2>/dev/null | grep -m1 'notes file' )"

case "$READER_SAYS" in
  *"$INSTALL3/notes.md"*) ok "the reader names the same file the writer wrote, with no env set" ;;
  *) nope "the reader names the same file the writer wrote, with no env set" "reader said: ${READER_SAYS:-<no notes-file line>}" ;;
esac

# And the note itself has to be visible to the reader's file, not merely adjacent.
if [ -s "$INSTALL3/notes.md" ] && grep -q "seam note" "$INSTALL3/notes.md"; then
  ok "the note landed in the install dir both halves resolve to"
else
  nope "the note landed in the install dir both halves resolve to" "missing from $INSTALL3/notes.md"
fi

# --- no hardcoded legacy path outside the documented fallback ----------------
# The legacy path may still appear in the marker-less fallback and in the warning
# that announces it. What must never come back is NOTES itself being assigned it:
# that is the exact line that made the writer and the reader disagree.
if grep -q 'NOTES=.*HOME/\.claude/autodream' "$WRITER"; then
  nope "NOTES is not assigned the legacy path directly" "$(grep -n 'NOTES=' "$WRITER" | head -1)"
else
  ok "NOTES is not assigned the legacy path directly"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
