#!/bin/bash
# Count how many consecutive reports have carried the same open question, and escalate the
# ones that have gone unanswered too long.
#
# WHY THIS EXISTS
#
# Detection was never the problem. The X bookmarks walk broke on 2026-09-05; every report
# from then to 09-14 said `x_queryid_source: failed`, and the Open questions section asked
# "Fix the X bookmarks walker, or turn the feature off?" six times. Ten nights, six asks,
# one banner a night that looked exactly like every other banner — and nothing changed
# until the user happened to notice the other install had gone quiet. A signal that repeats
# at constant volume is a signal you learn to skim.
#
# So this counts the repeats mechanically and makes the Nth one look different from the
# first. L2 already writes "Sixth ask" into its own prose, but that is the model counting
# its own history from context, which is exactly the kind of number that drifts. This one
# is derived from the reports on disk.
#
# HOW A QUESTION IS IDENTIFIED
#
# By its bolded title, normalized. Verified against five consecutive cc-autodream reports
# (2026-09-10..14): the body prose is rewritten every night, but the title is BYTE-identical
# across all of them —
#   **Fix the X bookmarks walker, or turn the feature off?**
#   **Where should autodream's memory pins go now that markdown memory is retired?**
# so an exact key on the normalized title matches without any fuzzy scoring. Keying on the
# body instead is not an option precisely because the body is rewritten nightly.
#
# PROMPT.md treats the bold lead-in as REQUIRED for this reason. It used to call it
# optional, and a plain numbered question would then parse as nothing while its siblings
# parsed fine — the streak would vanish with no warning. The guard against that living on
# the prompt alone is the parsed-vs-marker check below: any disagreement between the number
# of questions parsed and the report's own count marker refuses to touch state and says so.
# Freezing every streak at its last value is the failure that would switch this feature off
# silently, which is exactly what `overlap_measured` and `stats_sidecars_unparseable` exist
# to prevent elsewhere in this repo.
#
# A streak counts CONSECUTIVE REPORTS, not calendar days: a night that produced no report
# must not reset a streak, because the whole point is to survive the nights that fail. A
# question absent from a report that WAS produced is treated as resolved and forgotten —
# including a report with zero questions, which is why run.sh calls this on the
# nothing-was-triaged path too.
#
# RERUNS
#
# Updates are idempotent per report date and refuse to go backwards. `AUTODREAM_FORCE=1
# run.sh <today>` rebuilds the same report and must not advance a streak to a false
# escalation; rebuilding an OLDER date must not clobber the live state with history. Both
# are decided from the stored last-seen date rather than trusted not to happen.
#
# Usage:
#   question-streaks.sh update <report.md> [findings-dir]   # count, escalate, notify
#   question-streaks.sh status                              # print current streaks
#   question-streaks.sh clear all|<key>                     # forget a streak once acted on
#
# Environment:
#   AUTODREAM_DIR                    default $HOME/.claude/autodream
#   AUTODREAM_QUESTION_STATE         streak store   default $AUTODREAM_DIR/question-streaks.tsv
#   AUTODREAM_QUESTION_ESCALATE_AT   escalate at N consecutive reports   default 3
#   AUTODREAM_NOTIFY_DRYRUN          1 = never post a banner (tests, dry runs)
#
# Exit: always 0 on `update`. This runs at the end of a nightly pipeline and a bookkeeping
# helper must never be the thing that costs a night its report. `clear` DOES report a
# failed write, because an operator who is told a streak is forgotten must not find it
# still escalating tomorrow.
set -uo pipefail

# install.sh links this script into the install's own AUTODREAM_DIR, so a bare invocation
# (status, clear, or run.sh's early empty-night path) finds the store there, the same way
# run.sh finds its install dir. The legacy ~/.claude/autodream stays the last resort
# (Codex review of 232c94c).
if [ -z "${AUTODREAM_DIR:-}" ]; then
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -n "$self_dir" ] && { [ -f "$self_dir/config" ] || [ -f "$self_dir/l1-no-advisor.yml" ]; }; then
    AUTODREAM_DIR="$self_dir"
  fi
fi
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
STATE="${AUTODREAM_QUESTION_STATE:-$AUTODREAM_DIR/question-streaks.tsv}"
ESCALATE_AT="${AUTODREAM_QUESTION_ESCALATE_AT:-3}"

case "$ESCALATE_AT" in ''|*[!0-9]*) ESCALATE_AT=3 ;; esac
[ "$ESCALATE_AT" -ge 1 ] || ESCALATE_AT=3

# Line count that is 0 for an empty or missing file. NOT `grep -c . || echo 0`: grep -c
# prints 0 AND exits 1 on no match, so the fallback fires too and the value becomes "0\n0".
# That trap is documented in this repo's CLAUDE.md and it still shipped in the first draft
# of this file, where it logged "clearing 0 0 streak(s)".
nlines() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# Title -> stable key. Lowercase and collapse whitespace only. The titles are identical
# night to night, so heavier normalization would buy nothing and would risk collapsing two
# genuinely different questions onto one key, which silently merges their streaks.
key_of() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed 's/^ //; s/ $//' \
    | shasum | cut -c1-12
}

# Pull the bolded titles out of the Open questions section. Bounded to that section so a
# bold run anywhere else in the report cannot register as a question.
# Tolerates leading indent and `1)` as well as `1.`. Deliberately still anchored to a
# NUMBERED item: PROMPT.md mandates numbering and review.sh walks the questions in order,
# so a bulleted question is already broken for other reasons. The real safety net against
# a format change is the parsed-vs-marker check in cmd_update, not the breadth of this
# pattern — a regex loose enough to match anything would start matching sub-bullets.
titles_of() { # $1=report
  sed -n '/^## Open questions/,/^<!-- *autodream:open-questions/p' "$1" 2>/dev/null \
    | grep -oE '^[[:space:]]*[0-9]+[.)][[:space:]]*\*\*[^*]+\*\*' \
    | sed 's/^[[:space:]]*[0-9]*[.)][[:space:]]*\*\*//; s/\*\*$//'
}

# Serialize the read-modify-write. STATE is one shared file per install, and the scheduled
# nightly and an `autodream-now.sh` run carry different launchd labels, so launchd's
# one-instance-per-label rule does not keep them apart. Two overlapping runs would each
# read the old state and the second write would discard the first's increment.
#
# mkdir is the atomic primitive; a stale directory from a killed run is reclaimed by age so
# one crash cannot wedge the feature forever. Failure to acquire SKIPS the update rather
# than blocking — a missed increment costs one night of escalation latency, while a
# bookkeeping helper that hangs would hold up the pipeline behind it.
LOCK="$STATE.lock"

# ONE FILE, ONE WRITE
#
# The newest counted report date is the first line of STATE, `#last<TAB>YYYY-MM-DD`, above
# the streak rows. A question-free report leaves only that line, so the watermark survives
# an empty board. Every write replaces the whole file: a temp file in the same directory,
# then one rename. The watermark used to live in a second file, and three reviews in a row
# (Codex on 232c94c, 4eea84d and 600e6dd) each found a write order or a failure between the
# two files that let an older rebuild recreate a streak. One rename cannot leave the board
# and its watermark disagreeing, so there is no order left to get wrong:
#
#   failure                                STATE afterwards
#   temp file cannot be created            unchanged
#   temp write fails (disk full)           unchanged, temp removed
#   rename fails                           unchanged, temp removed
#   killed between write and rename        unchanged, a stray STATE.XXXXXX left behind
#   STATE exists but cannot be read        unchanged; update refuses, it is not an empty board
rows_of() { awk '!/^#/ && NF' "$STATE" 2>/dev/null; }
nrows()   { rows_of | wc -l | tr -d ' '; }
newest_of() {
  awk -F'\t' '/^#last\t/ {print $2} !/^#/ && NF>=4 {print $4}' "$STATE" 2>/dev/null \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort | tail -1
}
unreadable_state() { [ -e "$STATE" ] && { [ ! -f "$STATE" ] || [ ! -r "$STATE" ]; }; }
write_state() { # $1=rows file  $2=watermark date, or empty for none
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  local t; t=$(mktemp "$STATE.XXXXXX" 2>/dev/null) || return 1
  if ( { [ -z "$2" ] || printf '#last\t%s\n' "$2"; } && cat "$1" ) > "$t" 2>/dev/null \
     && mv -f "$t" "$STATE" 2>/dev/null; then
    return 0
  fi
  rm -f "$t" 2>/dev/null
  return 1
}
acquire_lock() {
  local i=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    if [ -d "$LOCK" ]; then
      local age; age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) ))
      [ "$age" -gt 120 ] && { rmdir "$LOCK" 2>/dev/null; continue; }
    fi
    i=$(( i + 1 ))
    [ "$i" -gt 15 ] && return 1
    sleep 1
  done
  return 0
}
release_lock() { rmdir "$LOCK" 2>/dev/null || true; }

marker_of() { # $1=report -> the report's own question count, or empty
  sed -n 's/.*<!-- *autodream:open-questions=\([0-9][0-9]*\) *-->.*/\1/p' "$1" 2>/dev/null | head -1
}

cmd_update() {
  local report="${1:?usage: question-streaks.sh update <report.md> [findings-dir]}"
  local findings="${2:-}"
  [ -s "$report" ] || { echo "question-streaks: no report at $report; nothing to count"; return 0; }
  local date; date=$(basename "$report" .md)

  if ! acquire_lock; then
    echo "question-streaks: another run holds $LOCK; skipping this update"
    return 0
  fi
  # ONE trap for both the lock and the scratch dir. A second `trap ... RETURN` later in
  # this function would silently replace this one rather than adding to it, leaking
  # whichever cleanup was registered first — and a leaked lock dir wedges the next 120s.
  local tmp=""
  trap 'release_lock; [ -n "$tmp" ] && rm -rf "$tmp"' RETURN

  # Refuse to go backwards. Rebuilding an old date would otherwise drop every streak that
  # old report does not mention and rewrite the live state with history.
  # A state file that cannot be read is not an empty board. Reading it as empty would drop
  # the watermark and restart every streak.
  if unreadable_state; then
    echo "question-streaks: cannot read $STATE; leaving streaks untouched"
    return 0
  fi
  local newest; newest=$(newest_of)
  if [ -n "$newest" ] && [ "$date" \< "$newest" ]; then
    echo "question-streaks: $date is older than the last counted report ($newest); leaving streaks untouched"
    return 0
  fi
  # Same date means a rebuild of a report already counted. Refresh membership, hold counts.
  local same_date=0
  [ -n "$newest" ] && [ "$date" = "$newest" ] && same_date=1

  tmp="$(mktemp -d)" || return 0

  titles_of "$report" > "$tmp/titles" 2>/dev/null || : > "$tmp/titles"
  local n marker; n=$(nlines "$tmp/titles"); marker=$(marker_of "$report")

  # The marker is the report's own count. Any disagreement means the format moved and some
  # questions parsed as nothing — refuse to touch state rather than silently dropping a
  # streak or freezing every one of them at its last value.
  if [ -n "$marker" ] && [ "$marker" -ne "$n" ]; then
    echo "question-streaks: WARNING $date says $marker open question(s) but $n parsed — the title format changed; streaks not updated"
    # Banner, not just a log line. This feature exists because a signal buried in a place
    # nobody looks gets skimmed, and a parser breakage hidden in the run log is that same
    # failure one level up: every streak silently frozen, no escalation ever again, and no
    # way to tell that from a quiet week. The safety net going down has to be louder than
    # the thing it was watching for.
    post_banner "$date" 1 "parser broke: $marker question(s), $n parsed — escalation is DOWN"
    return 0
  fi

  if [ "${n:-0}" -eq 0 ]; then
    echo "question-streaks: no open questions in $date; clearing $(nrows) streak(s)"
    write_state /dev/null "$date" || echo "question-streaks: could not write $STATE; streaks untouched (continuing)"
    return 0
  fi

  : > "$tmp/next"; : > "$tmp/escalations"
  local escalated=0
  while IFS= read -r title; do
    [ -n "$title" ] || continue
    local k count first
    k=$(key_of "$title")
    count=$(awk -F'\t' -v k="$k" '$1==k {print $2}' "$STATE" 2>/dev/null | head -1)
    first=$(awk -F'\t' -v k="$k" '$1==k {print $3}' "$STATE" 2>/dev/null | head -1)
    case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
    # A rebuild of an already-counted report holds the count where it is; a question that
    # is new even on a rebuild still starts at 1.
    if [ "$same_date" -eq 1 ] && [ "$count" -gt 0 ]; then :; else count=$(( count + 1 )); fi
    [ -n "$first" ] || first="$date"
    printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$count" "$first" "$date" "$title" >> "$tmp/next"
    if [ "$count" -ge "$ESCALATE_AT" ]; then
      printf '%s consecutive reports (since %s): %s\n' "$count" "$first" "$title" >> "$tmp/escalations"
      escalated=$(( escalated + 1 ))
    fi
  done < "$tmp/titles"

  write_state "$tmp/next" "$date" || { echo "question-streaks: could not write $STATE; streaks untouched (continuing)"; return 0; }

  echo "question-streaks: $n question(s) in $date, $escalated at or past $ESCALATE_AT consecutive"
  [ "$escalated" -eq 0 ] && return 0

  {
    printf '# Open questions autodream has now asked %s+ times\n\n' "$ESCALATE_AT"
    printf 'These have survived several reports unanswered. Either act on one or tell the\n'
    printf 'nightly to stop asking; a question that repeats at constant volume stops being read.\n\n'
    cat "$tmp/escalations"
  } > "$tmp/block"

  cat "$tmp/block"
  [ -n "$findings" ] && [ -d "$findings" ] && cp "$tmp/block" "$findings/question-escalations.txt" 2>/dev/null || true

  # A rebuild of an already-counted report must not re-post last night's banner.
  if [ "$same_date" -eq 1 ]; then
    echo "question-streaks: rebuild of $date; escalation written but no banner re-posted"
  else
    post_banner "$date" "$escalated" "$(head -1 "$tmp/escalations" | cut -c1-90)"
  fi
  return 0
}

# The banner is the point: it is the one surface that looks different from last night's.
# Best-effort and never fatal, same posture as notify.sh.
post_banner() { # $1=date $2=count $3=lead line
  [ "${AUTODREAM_NOTIFY_DRYRUN:-0}" = "1" ] && { echo "question-streaks: dry run, no banner"; return 0; }
  command -v osascript >/dev/null 2>&1 || { echo "question-streaks: no osascript; banner skipped"; return 0; }
  local plural=""; [ "$2" -ne 1 ] && plural="s"
  local msg="$2 question$plural unanswered $ESCALATE_AT+ nights: $3"
  # Quotes and backslashes in a question title would otherwise end the AppleScript string
  # and turn the whole -e into a syntax error, which osascript reports on a stderr this
  # drops — so the banner would vanish for exactly the questions with punctuation in them.
  msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
  osascript -e "display notification \"$msg\" with title \"Autodream — still unanswered\"" >/dev/null 2>&1 \
    && echo "question-streaks: posted escalation banner for $1" \
    || echo "question-streaks: banner post failed (continuing)"
  return 0
}

cmd_status() {
  unreadable_state && { echo "question-streaks: cannot read $STATE" >&2; return 1; }
  [ "$(nrows)" -gt 0 ] || { echo "question-streaks: no streaks recorded ($STATE)"; return 0; }
  printf '%-14s %-6s %-12s %-12s %s\n' KEY COUNT FIRST LAST TITLE
  rows_of | awk -F'\t' '{ printf "%-14s %-6s %-12s %-12s %s\n", $1, $2, $3, $4, $5 }'
  return 0
}

# Unlike update, this reports failure. Telling an operator a streak is forgotten while it
# is still on disk means tomorrow's escalation looks like the feature is broken.
cmd_clear() {
  local what="${1:?usage: question-streaks.sh clear all|<key>}"
  # Same lock as update. Without it an update that already read the old state writes it
  # back after this clear, and the streak the operator just cleared returns (Codex review
  # of 232c94c). The lock comes BEFORE the empty check: an update holding it may be about
  # to write the first streak onto an empty board (Codex review of 4eea84d). With no state
  # directory there is no lock to hold and nothing to clear, so that case stays a no-op
  # rather than waiting out the lock and failing.
  [ -d "$(dirname "$STATE")" ] || { echo "question-streaks: nothing to clear"; return 0; }
  if ! acquire_lock; then
    echo "question-streaks: FAILED to clear: another run holds $LOCK" >&2
    return 1
  fi
  trap 'release_lock' RETURN
  unreadable_state && { echo "question-streaks: FAILED to clear: cannot read $STATE" >&2; return 1; }
  [ "$(nrows)" -gt 0 ] || { echo "question-streaks: nothing to clear"; return 0; }
  # Forget streaks, keep the watermark: an older rebuild after a clear is still history.
  local tmp; tmp="$(mktemp)" || { echo "question-streaks: FAILED to stage a rewrite of $STATE" >&2; return 1; }
  rows_of | awk -F'\t' -v k="$what" 'k != "all" && $1 != k' > "$tmp"
  if write_state "$tmp" "$(newest_of)"; then
    rm -f "$tmp"; echo "question-streaks: cleared $what"; return 0
  fi
  rm -f "$tmp"
  echo "question-streaks: FAILED to clear $what from $STATE" >&2; return 1
}

case "${1:-}" in
  update) shift; cmd_update "$@" ;;
  status) shift; cmd_status "$@" ;;
  clear)  shift; cmd_clear  "$@" ;;
  *) echo "usage: question-streaks.sh update <report.md> [findings-dir] | status | clear all|<key>" >&2; exit 2 ;;
esac
