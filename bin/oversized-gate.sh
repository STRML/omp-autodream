#!/bin/bash
# Issue #12 measurement gate: what share of oversized transcripts still failed to triage?
#
# The gate is a trailing-window judgment: size failures divided by oversized sessions
# that have no silent, provider, or unclassified failure. A sustained share >= 5% over
# a week opens #12. run.sh records one night at a time, and an old runner (#29) may omit
# the counters, so this recomputes the window from sidecars, findings, and .err artifacts.
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
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FAILURE_CLASS="$SCRIPT_DIR/failure-class.sh"
[ -r "$FAILURE_CLASS" ] || FAILURE_CLASS="$AUTODREAM_DIR/failure-class.sh"
if [ ! -r "$FAILURE_CLASS" ]; then
  printf 'fatal: required failure classifier not found: %s\n' "$FAILURE_CLASS" >&2
  exit 1
fi
# shellcheck source=./failure-class.sh
. "$FAILURE_CLASS"
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
total_provider=0
total_unclassified=0
total_deferred=0
total_nolist=0
total_unmeasurable=0
dates_measured=0

printf '%-12s %7s %10s %9s %7s %8s %8s %8s  %s\n' \
  DATE SESSIONS OVERSIZED ERRORED SILENT PROVIDER UNCLASS SHARE SOURCE
for d in "${DIRS[@]}"; do
  date_label=$(basename "$d")
  list="$d/sessions.txt"
  if [ ! -r "$list" ]; then
    printf '%-12s %7s %10s %9s %7s %8s %8s %8s  %s\n' "$date_label" - - - - - - - "no sessions.txt"
    total_nolist=$((total_nolist + 1))
    continue
  fi
  # A network-deferred run stopped before its workers finished. Its oversized sessions were
  # counted, but the ones that never ran have no stub, so its share reads lower than the
  # evidence supports. PROMPT.md already says to keep it out of the trailing week.
  if grep -qx 'network_deferred: yes' "$d/run-stats.txt" 2>/dev/null; then
    printf '%-12s %7s %10s %9s %7s %8s %8s %8s  %s\n' "$date_label" - - - - - - - "network-deferred run, excluded"
    total_deferred=$((total_deferred + 1))
    continue
  fi

  sessions=0; oversized=0; errored=0; silent=0; provider=0; unclassified=0
  from_sidecar=0; unmeasurable=0
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
        failure_class=$(classify_failure "$findings.err")
        case "$failure_class" in
          silent) silent=$((silent + 1)) ;;
          provider) provider=$((provider + 1)) ;;
          unclassified) unclassified=$((unclassified + 1)) ;;
        esac
      fi
    fi
  done < "$list"

  total_oversized=$((total_oversized + oversized))
  total_errored=$((total_errored + errored))
  total_silent=$((total_silent + silent))
  total_provider=$((total_provider + provider))
  total_unclassified=$((total_unclassified + unclassified))
  total_unmeasurable=$((total_unmeasurable + unmeasurable))
  # A date counts as measured only when at least one of its sessions was sized. A list of
  # transcripts that are all gone says nothing about size (Codex review of cdfdf3b).
  if [ $((sessions - unmeasurable)) -gt 0 ]; then
    dates_measured=$((dates_measured + 1))
  fi

  # SHARE includes only sessions whose artifacts leave size as the explanation.
  measured=$((oversized - silent - provider - unclassified))
  size_errored=$((errored - silent - provider - unclassified))
  if [ "$measured" -gt 0 ]; then
    share=$(awk -v e="$size_errored" -v o="$measured" 'BEGIN{printf "%.1f%%", 100*e/o}')
  else
    share="n/a"
  fi
  source_note="$from_sidecar/$sessions from sidecars"
  [ "$unmeasurable" -gt 0 ] && source_note="$source_note, $unmeasurable unmeasurable"
  printf '%-12s %7s %10s %9s %7s %8s %8s %8s  %s\n' \
    "$date_label" "$sessions" "$oversized" "$errored" "$silent" "$provider" "$unclassified" "$share" "$source_note"
done

echo
[ "$total_deferred" -gt 0 ] && echo "Excluded $total_deferred network-deferred date(s): no worker ran for part of those corpora."
[ "$total_nolist" -gt 0 ] && echo "Excluded $total_nolist date(s) with no sessions.txt."
# Every date excluded says nothing about size, and saying "no oversized transcripts" would
# claim a measurement that never happened (Auditor verification of 6ca1584).
if [ "$dates_measured" -eq 0 ]; then
  echo "No date in this window could be measured. The gate has no evidence either way."
  exit 0
fi
if [ "$total_oversized" -eq 0 ]; then
  echo "No oversized transcripts in this window. The gate has nothing to measure;"
  echo "that is not the same as a measured 0% and should not close #12 on its own."
  [ "$total_unmeasurable" -gt 0 ] && echo "$total_unmeasurable session(s) could not be sized at all, so some may have been oversized."
  exit 0
fi

printf 'Window: %s oversized, %s errored, %s silent, %s provider, %s unclassified' \
  "$total_oversized" "$total_errored" "$total_silent" "$total_provider" "$total_unclassified"
[ "$total_unmeasurable" -gt 0 ] && printf ' (%s session(s) unmeasurable, excluded)' "$total_unmeasurable"
printf '\n'

# Every explained non-size failure leaves both sides of the ratio. When nothing else is
# left, the window has no evidence about transcript size and gets no verdict.
measured=$((total_oversized - total_silent - total_provider - total_unclassified))
size_errored=$((total_errored - total_silent - total_provider - total_unclassified))
if [ "$measured" -eq 0 ]; then
  echo "The window measured nothing about size after excluding silent, provider, and"
  echo "unclassified failures. Fix those causes, then re-measure."
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
