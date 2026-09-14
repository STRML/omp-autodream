#!/bin/bash
# Issue #12 measurement gate: what share of oversized transcripts still failed to triage?
#
# The gate is a trailing-window judgment ("sustained oversized_errored/oversized_total
# >= 5% over a week opens #12"), but run.sh only ever records one night at a time, and a
# run whose runner predated the counters (#29) records nothing at all. This recomputes
# the window from the *.stats.json sidecars and findings JSONs still on disk, so a date
# whose run-stats.txt is missing the keys is recoverable rather than lost.
#
# It reads only artifacts. No model calls, no network, safe to re-run.
#
# Usage:
#   oversized-gate.sh                       # trailing 7 dated dirs under the findings root
#   oversized-gate.sh --days 14             # trailing 14
#   oversized-gate.sh <findings-dir>...     # exactly these dirs
#
# Environment:
#   AUTODREAM_DIR         default: $HOME/.claude/autodream
#   AUTODREAM_SLIM_BYTES  oversized threshold, matches run.sh   default: 262144

set -u

AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
THRESHOLD="${AUTODREAM_SLIM_BYTES:-262144}"
DAYS=7
DIRS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    # Validate rather than defaulting a missing value: `--days` with nothing after it
    # used to leave $# at 1 while `shift 2` silently refused to shift, spinning forever.
    --days)
      [ "$#" -ge 2 ] || { echo "--days needs a value" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "--days needs a positive integer, got: $2" >&2; exit 2 ;; esac
      [ "$2" -gt 0 ] || { echo "--days needs a positive integer, got: $2" >&2; exit 2; }
      DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) DIRS+=("$1"); shift ;;
  esac
done

if [ "${#DIRS[@]}" -eq 0 ]; then
  root="$AUTODREAM_DIR/findings"
  [ -d "$root" ] || { echo "no findings root at $root" >&2; exit 1; }
  while IFS= read -r d; do
    [ -n "$d" ] && DIRS+=("$d")
  done < <(find "$root" -maxdepth 1 -type d -name '2[0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]' \
    | sort | tail -n "$DAYS")
fi

[ "${#DIRS[@]}" -gt 0 ] || { echo "no dated findings dirs found" >&2; exit 1; }

# A session's size comes from its sidecar's transcript_bytes; when that is missing or
# unusable, fall back to measuring the transcript directly. transcript_bytes is only ever
# `wc -c` of that same file, so the fallback is the same quantity from its original
# source (#27). Sessions whose transcript is also gone are counted as unmeasurable and
# excluded from the ratio rather than silently sized at 0.
total_oversized=0
total_errored=0
total_silent=0
total_unmeasurable=0

# A silent worker death is an error stub whose .err shows exit 0 AND empty stdout: the
# worker never reached the model, so the failure says nothing about transcript size.
# Same predicate as run.sh's oversized loop (oversized_errored_silent). A missing .err
# is no proof of anything, so that session stays in the size-attributable count.
is_silent_death() {
  grep -q '^worker exit code: 0 after ' "$1" 2>/dev/null && grep -qx 'worker stdout was empty' "$1" 2>/dev/null
}

printf '%-12s %7s %10s %9s %7s %8s  %s\n' DATE SESSIONS OVERSIZED ERRORED SILENT SHARE SOURCE
for d in "${DIRS[@]}"; do
  date_label=$(basename "$d")
  list="$d/sessions.txt"
  [ -r "$list" ] || { printf '%-12s %7s %10s %9s %7s %8s  %s\n' "$date_label" - - - - - "no sessions.txt"; continue; }

  sessions=0; oversized=0; errored=0; silent=0; from_sidecar=0; unmeasurable=0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    sessions=$((sessions + 1))
    hash=$(printf '%s' "$session" | shasum -a 1 | cut -c1-12)
    sidecar="$d/$hash.stats.json"
    size=""
    [ -s "$sidecar" ] && size=$(jq -r '.transcript_bytes | numbers | floor' "$sidecar" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size="" ;; esac
    if [ -n "$size" ]; then
      from_sidecar=$((from_sidecar + 1))
    else
      size=$(wc -c < "$session" 2>/dev/null | tr -d ' ')
      case "$size" in ''|*[!0-9]*) size="" ;; esac
      if [ -z "$size" ]; then
        unmeasurable=$((unmeasurable + 1))
        continue
      fi
    fi
    if [ "$size" -gt "$THRESHOLD" ]; then
      oversized=$((oversized + 1))
      findings="$d/$hash.json"
      if [ -f "$findings" ] && grep -q '"error":' "$findings" 2>/dev/null; then
        errored=$((errored + 1))
        is_silent_death "$findings.err" && silent=$((silent + 1))
      fi
    fi
  done < "$list"

  total_oversized=$((total_oversized + oversized))
  total_errored=$((total_errored + errored))
  total_silent=$((total_silent + silent))
  total_unmeasurable=$((total_unmeasurable + unmeasurable))

  # SHARE is the size-attributable share: silent deaths leave both sides of the ratio.
  if [ "$((oversized - silent))" -gt 0 ]; then
    share=$(awk -v e="$((errored - silent))" -v o="$((oversized - silent))" 'BEGIN{printf "%.1f%%", 100*e/o}')
  else
    share="n/a"
  fi
  source_note="$from_sidecar/$sessions from sidecars"
  [ "$unmeasurable" -gt 0 ] && source_note="$source_note, $unmeasurable unmeasurable"
  printf '%-12s %7s %10s %9s %7s %8s  %s\n' "$date_label" "$sessions" "$oversized" "$errored" "$silent" "$share" "$source_note"
done

echo
if [ "$total_oversized" -eq 0 ]; then
  echo "No oversized transcripts in this window. The gate has nothing to measure;"
  echo "that is not the same as a measured 0% and should not close #12 on its own."
  exit 0
fi

printf 'Window: %s oversized, %s errored, %s silent' "$total_oversized" "$total_errored" "$total_silent"
[ "$total_unmeasurable" -gt 0 ] && printf ' (%s session(s) unmeasurable, excluded)' "$total_unmeasurable"
printf '\n'

# Silent worker deaths leave both sides of the ratio. When nothing else is left, the
# window measured the worker, not transcript size, and must not read as open or closed.
measured=$((total_oversized - total_silent))
size_errored=$((total_errored - total_silent))
if [ "$measured" -eq 0 ]; then
  echo "Every oversized session failed as a silent worker death (exit 0, empty stdout), so there"
  echo "are no size-attributable failures to judge #12 by. Fix the worker, then re-measure."
  exit 0
fi

share=$(awk -v e="$size_errored" -v o="$measured" 'BEGIN{printf "%.2f", 100*e/o}')
printf 'Size-attributable: %s errored of %s, %s%%\n' "$size_errored" "$measured" "$share"
# Rule of three: with 0 failures in n trials the 95% upper bound is about 3/n. Quoting it
# keeps a clean run from being read as stronger evidence than the sample size supports.
if [ "$size_errored" -eq 0 ]; then
  bound=$(awk -v n="$measured" 'BEGIN{printf "%.1f", 100*3/n}')
  echo "Zero failures in $measured samples; 95% upper bound about $bound% (rule of three)."
fi
if awk -v s="$share" 'BEGIN{exit !(s + 0 >= 5)}'; then
  echo "GATE OPEN: at or above the 5% threshold. Issue #12 (chunk-summarize) is unblocked."
else
  echo "GATE CLOSED: below the 5% threshold. The existing fallback stack is coping."
fi
