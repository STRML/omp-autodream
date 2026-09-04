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
# vault-notes.sh resolves NOTES_FILE as $AUTODREAM_DIR/notes.md; assert the
# writer's target matches that expression for the same AUTODREAM_DIR.
READER_EXPR="$(grep -m1 'NOTES_FILE=' "$REPO/bin/vault-notes.sh")"
case "$READER_EXPR" in
  *'$AUTODREAM_DIR/notes.md'*) ok "vault-notes.sh reads \$AUTODREAM_DIR/notes.md" ;;
  *) nope "vault-notes.sh reads \$AUTODREAM_DIR/notes.md" "found: $READER_EXPR" ;;
esac
if grep -q 'NOTES="\${AUTODREAM_NOTES_FILE:-\$AUTODREAM_DIR/notes.md}"' "$WRITER"; then
  ok "autodream-note.sh writes the same expression"
else
  nope "autodream-note.sh writes the same expression" "writer does not resolve via AUTODREAM_DIR"
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
