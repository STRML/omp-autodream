#!/bin/bash
# Write the "Open questions" section of an autodream report to a text file, post a
# persistent macOS notification, and pop it open in the user's editor. Quiet no-op if
# there are no questions.
#
# The banner is the reliable signal: the nightly run fires ~3am under launchd, when a
# GUI window open silently fails to surface. `display notification` posts to
# Notification Center, which persists until dismissed, so the alert is waiting whenever
# the Mac is next used. The direct open stays as a best-effort convenience on top.
#
# Usage: notify.sh <report.md>
#
# Environment overrides:
#   AUTODREAM_DIR   scripts + state           default: $HOME/.claude/autodream
#   AUTODREAM_OPEN  command that opens the inbox file. Run through `sh -c`, so flags
#                   work: "subl", "code -g", "open -a Obsidian".
#                   default: open (macOS hands the file to the default .md app)
#   SUBL            deprecated alias for AUTODREAM_OPEN, honored for existing setups
#   AUTODREAM_NOTIFY_DRYRUN
#                   1 = report the question count and exit. Writes no inbox file, posts
#                   no banner, opens nothing. Use this to check what a report WOULD do.

set -u

REPORT="${1:?Usage: notify.sh <report.md>}"
DATE=$(basename "$REPORT" .md)
# The install symlinks the scripts INTO $AUTODREAM_DIR (install.sh), so a bare
# shell invocation with no env resolves the install dir from this script's own
# location instead of the legacy ~/.claude/autodream default (the OMP port
# installs under ~/.omp/agent/autodream). Env still wins; the derived dir is
# only trusted when it carries an install marker file (install.sh writes both).
AUTODREAM_DIR="${AUTODREAM_DIR:-}"
if [ -z "$AUTODREAM_DIR" ]; then
  AUTODREAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -z "$AUTODREAM_DIR" ] || { [ ! -f "$AUTODREAM_DIR/config" ] && [ ! -f "$AUTODREAM_DIR/l1-no-advisor.yml" ]; }; then
    echo "notify.sh: WARNING no install markers next to $0; falling back to legacy $HOME/.claude/autodream" >&2
    AUTODREAM_DIR="$HOME/.claude/autodream"
  fi
fi
# Exported so child processes (make-notifier.sh) resolve the same install dir.
# Without this, the child's own AUTODREAM_DIR default falls back to the legacy
# ~/.claude/autodream and the branded notifier bundle lands in the wrong place.
export AUTODREAM_DIR
INBOX_DIR="$AUTODREAM_DIR/inbox"
# How the inbox file gets opened. This is a shell snippet, not a binary path, so an
# editor that needs flags ("code -g") works without a wrapper. The default is plain
# `open`, which hands the file to whatever the user's Mac already opens .md with —
# the tool ships with a LICENSE and an install script, so the out-of-the-box path
# cannot assume one particular editor is installed. SUBL stays honored as a
# deprecated alias so setups that predate this keep working untouched.
OPEN_CMD="${AUTODREAM_OPEN:-${SUBL:-open}}"

# Resolve the notifier. Prefer our rebranded bundle so banners read "cc-autodream"
# instead of "terminal-notifier"; bootstrap it once via make-notifier.sh if it's
# missing but terminal-notifier is installed. Fall back to plain terminal-notifier,
# then to an osascript banner (not clickable). Resolve make-notifier.sh next to this
# script (repo + ~/.claude/autodream symlink both work), then the install dir.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAKE_NOTIFIER="$SCRIPT_DIR/make-notifier.sh"
[ -x "$MAKE_NOTIFIER" ] || MAKE_NOTIFIER="$AUTODREAM_DIR/make-notifier.sh"
BRANDED="$AUTODREAM_DIR/cc-autodream.app/Contents/MacOS/terminal-notifier"
if [ ! -x "$BRANDED" ] && command -v terminal-notifier >/dev/null 2>&1 && [ -x "$MAKE_NOTIFIER" ]; then
  "$MAKE_NOTIFIER" >/dev/null 2>&1 || true
fi
NOTIFIER=""
[ -x "$BRANDED" ] && NOTIFIER="$BRANDED" || NOTIFIER="$(command -v terminal-notifier || true)"

mkdir -p "$INBOX_DIR"

[ -f "$REPORT" ] || { echo "notify.sh: no such report: $REPORT" >&2; exit 1; }

QUESTIONS=$(awk '
  /^## Open questions for the user/ { capture=1; next }
  capture && /^## / { exit }
  capture && /^---[[:space:]]*$/ { exit }
  capture { print }
' "$REPORT")
QUESTIONS=$(printf "%s" "$QUESTIONS" | awk 'NF{p=1} p')
# How many questions the report is actually ASKING. PROMPT.md requires L2 to close the
# Open questions section with `<!-- autodream:open-questions=N -->`, where N is the count
# that survived its triviality gate — the same marker review.sh reads to decide whether
# the morning triage session is worth opening. That marker is authoritative because it is
# the only source that knows which candidates L2 considered and dropped; everything else
# is counting list markers and hoping they line up with questions.
#
# They don't. Measured against the 14 reports on disk when this was written, the old
# single-pass grep disagreed with the marker on 4 of the 9 reports that carry one. The
# 2026-07-24 report is the clearest: 1 real question, counted as 6, because the "Other
# findings dropped by the gate" bullets below it each scored. A banner claiming six
# questions over one is how you teach someone to stop reading banners.
#
# Reports written before the marker contract have none, so they fall back to a tiered
# heuristic — take the FIRST format tier that matches, since L2 has emitted this section
# as a numbered list, as bullets under bold subheadings, as plain bullets, and as bare
# prose, and counting every tier at once double-counts the sub-bullets under an item.
# A "None ..." lead-in is the shape review.sh already recognises as zero and must stay
# silent; without that case the prose tier turns every quiet night into a false pop.
MARKER=$(sed -n 's/.*<!-- *autodream:open-questions=\([0-9][0-9]*\) *-->.*/\1/p' "$REPORT" | head -1)
count_matching(){ printf "%s\n" "$QUESTIONS" | grep -cE "$1" || true; }
if [ -n "$MARKER" ]; then
  COUNT="$MARKER"
elif [ -z "$QUESTIONS" ]; then
  COUNT=0
else
  first=$(printf '%s\n' "$QUESTIONS" | grep -v '^[[:space:]]*$' | head -1 | tr '[:upper:]' '[:lower:]')
  case "$first" in
    none*) COUNT=0 ;;
    *)
      COUNT=$(count_matching '^[[:space:]]*[0-9]+\.[[:space:]]')                # numbered items
      [ "$COUNT" -eq 0 ] && COUNT=$(count_matching '^\*\*.+\*\*')               # bold titles
      [ "$COUNT" -eq 0 ] && COUNT=$(count_matching '^[[:space:]]*[-*][[:space:]]')  # bullets
      [ "$COUNT" -eq 0 ] && COUNT=1                                             # bare prose
      ;;
  esac
fi

if [ -z "$QUESTIONS" ] || [ "$COUNT" -eq 0 ]; then
  echo "notify.sh: $DATE has 0 open questions; nothing to pop"
  exit 0
fi

# Everything above is pure computation; everything below has side effects a human sees.
# The split matters because verifying the count is a thing people legitimately want to do
# over a pile of OLD reports — replaying the counter across the archive is how the marker
# logic was validated in the first place — and doing that with the real script posts a
# real banner per report. That happened on 2026-07-28: a verification sweep fired banners
# for reports up to eleven days old, and because the sweep had pointed the open command at
# a stub, clicking them did nothing. Pointing AUTODREAM_DIR at a temp dir is NOT enough to
# make this safe: the branded bundle is absent there, so the notifier resolution falls
# through to a system terminal-notifier and posts for real.
if [ "${AUTODREAM_NOTIFY_DRYRUN:-0}" = "1" ]; then
  echo "notify.sh: [dry run] $DATE has $COUNT open question$([ "$COUNT" -eq 1 ] || echo s); nothing written or posted"
  exit 0
fi

OUT="$INBOX_DIR/$DATE-open-questions.md"
cat > "$OUT" <<EOF
# Autodream — $DATE
# $COUNT open question$([ "$COUNT" -eq 1 ] || echo s)
#
# Full report: $REPORT
# Triage interactively: $AUTODREAM_DIR/review.sh $DATE
#
# ────────────────────────────────────────────────────────

$QUESTIONS
EOF

# Persistent banner — survives the 3am launchd run regardless of GUI state.
# Best-effort: a notification failure must never break the run.
#
# Resilience note (learned the hard way, 2026-06): a banner's exit code does NOT prove it
# was shown. If the sender's notification permission is off — or a Focus/Do-Not-Disturb
# suppresses it — macOS silently drops the banner to Notification Center and the command
# still exits 0. The branded cc-autodream.app bundle is its OWN sender, so when branding
# was introduced macOS treated it as a new app defaulting to notifications-off, and every
# nightly banner vanished for a week while the log read "posted". That auth state is
# TCC-protected and unreadable from a script, so we cannot detect the drop.
#
# Defense: fire BOTH senders. terminal-notifier gives the CLICKABLE, branded banner
# (-execute opens the inbox in Sublime; -group collapses repeats). osascript posts through
# the system's already-trusted sender as a backup floor, so one blacked-out sender can't
# black out the whole alert. The osascript backup is silent (no -sound) to avoid a double
# chime when both land; set AUTODREAM_NOTIFY_OSA_BACKUP=0 to suppress the backup entirely.
# NOTE: for click-to-open, the cc-autodream sender's style must be "Alerts" (not "Banners",
# which auto-dismiss) in System Settings ▸ Notifications, and allowed through any Focus.
plural=$([ "$COUNT" -eq 1 ] || echo s)
OSA_BACKUP="${AUTODREAM_NOTIFY_OSA_BACKUP:-1}"
posted=0

if [ -n "$NOTIFIER" ]; then
  "$NOTIFIER" \
    -title "Autodream — $DATE" \
    -message "$COUNT open question$plural — click to open" \
    -execute "$OPEN_CMD '$OUT'" \
    -group "autodream-$DATE" \
    -sound Glass >/dev/null 2>&1 \
    && { echo "notify.sh: posted clickable notification for $DATE ($COUNT open question$plural)"; posted=1; } \
    || echo "notify.sh: terminal-notifier post failed (continuing)"
fi

# osascript is the primary when there's no terminal-notifier, otherwise the backup sender.
if command -v osascript >/dev/null 2>&1 && { [ -z "$NOTIFIER" ] || [ "$OSA_BACKUP" != "0" ]; }; then
  if [ -n "$NOTIFIER" ]; then osa_sound=""; osa_role="backup"; else osa_sound=' sound name "Glass"'; osa_role="primary"; fi
  osascript -e "display notification \"$COUNT open question$plural — see inbox\" with title \"Autodream — $DATE\"$osa_sound" >/dev/null 2>&1 \
    && { echo "notify.sh: posted osascript $osa_role banner for $DATE"; posted=1; } \
    || echo "notify.sh: osascript notification post failed (continuing)"
fi

[ "$posted" -eq 1 ] || echo "notify.sh: WARNING no banner posted for $DATE (inbox written to $OUT)"

# sh -c word-splits a multi-word command ("open -a Obsidian") while $OUT is passed as
# a positional and stays a single argument no matter what is in the path.
if sh -c "$OPEN_CMD \"\$1\"" _ "$OUT" 2>/dev/null; then
  echo "notify.sh: opened $OUT with: $OPEN_CMD"
else
  echo "notify.sh: '$OPEN_CMD' failed to open $OUT (file still written)"
fi
