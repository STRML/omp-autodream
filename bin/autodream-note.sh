#!/usr/bin/env bash
# autodream-note.sh — leave a free-text note for the next autodream run.
#
# The L2 aggregator reads $AUTODREAM_DIR/notes.md (via vault-notes.sh) and addresses
# each active note in its "Operator notes" report section (usage counts, is-it-working
# reads, etc.). Notes past their --expires date are ignored and flagged for removal, so
# the file self-retires.
#
# Usage:
#   autodream-note.sh "evaluate how often /graphify is used"
#   autodream-note.sh --expires 2026-10-01 "evaluate how well graphify works"
set -euo pipefail

# Resolve the install dir the same way notify.sh and review.sh do. Hardcoding
# $HOME/.claude/autodream here made the writer and the reader disagree the moment
# this port installed under ~/.omp/agent: vault-notes.sh takes AUTODREAM_DIR from
# the launchd plist, so every note landed in a file the nightly never opened. No
# error, no missing note reported - the same silent-divergence shape as #14.
AUTODREAM_DIR="${AUTODREAM_DIR:-}"
if [ -z "$AUTODREAM_DIR" ]; then
  AUTODREAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -z "$AUTODREAM_DIR" ] || { [ ! -f "$AUTODREAM_DIR/config" ] && [ ! -f "$AUTODREAM_DIR/l1-no-advisor.yml" ]; }; then
    echo "autodream-note.sh: WARNING no install markers next to $0; falling back to legacy $HOME/.claude/autodream" >&2
    AUTODREAM_DIR="$HOME/.claude/autodream"
  fi
fi
NOTES="${AUTODREAM_NOTES_FILE:-$AUTODREAM_DIR/notes.md}"
EXPIRES=""
if [ "${1:-}" = "--expires" ]; then EXPIRES="${2:-}"; shift 2; fi
TEXT="${*:-}"
[ -n "$TEXT" ] || { echo "usage: autodream-note.sh [--expires YYYY-MM-DD] \"note text\"" >&2; exit 2; }

mkdir -p "$(dirname "$NOTES")"
if [ ! -f "$NOTES" ]; then
  printf '# Operator notes for autodream\n\nFree-text notes the next run should address in its "Operator notes" section.\nFormat: `- [added] (expires DATE) text` — expiry optional; expired notes are ignored.\n\n' > "$NOTES"
fi

TODAY="$(date +%F)"
if [ -n "$EXPIRES" ]; then
  printf -- '- [%s] (expires %s) %s\n' "$TODAY" "$EXPIRES" "$TEXT" >> "$NOTES"
else
  printf -- '- [%s] %s\n' "$TODAY" "$TEXT" >> "$NOTES"
fi
echo "noted -> $NOTES"
