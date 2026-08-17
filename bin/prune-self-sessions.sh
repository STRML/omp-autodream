#!/bin/bash
# Find (and optionally delete) autodream's OWN session transcripts.
#
# Every headless worker autodream spawns used to persist its own session JSONL into
# ~/.claude/projects/-Users-<you>/. The next night's run would then triage those as
# if they were real sessions — ~190 self-generated files/night, ~90% of the corpus,
# pure noise and wasted model spend. run.sh now passes --no-session-persistence (and
# the OMP port's workers run `omp` with --no-session), so new runs leave no
# transcript. Older runs predating those fixes still littered the real session
# bucket with full transcripts; this script cleans them up and is the single source
# of truth for the "is this one of ours?" predicate (run.sh calls `--filter`).
#
# Usage:
#   prune-self-sessions.sh                 # list self-sessions under $PROJECTS_DIR (dry run)
#   prune-self-sessions.sh --delete        # delete them
#   prune-self-sessions.sh --quiet         # just the summary line, no per-file paths
#   prune-self-sessions.sh /path/sessions  # scan a specific sessions dir
#   prune-self-sessions.sh --filter        # stdin: session paths; stdout: only NON-self ones
#
# Env:
#   PROJECTS_DIR   default $HOME/.omp/agent/sessions

set -u

# A session is autodream's own when its FIRST user turn is one of our inlined
# prompts. Anchored to the start of the message content so a human session that
# merely *discusses* autodream (mentions SESSION_PATH= mid-conversation) is NOT
# matched. Covers both the current literal-path framing and the legacy KEY=value
# framing from earlier runs, on either transcript shape:
#   - Claude stores user content in a string:   {"type":"user",...,"content":"…"}
#   - OMP stores an array of items:             {"type":"message","message":{"role":"user","content":[{"type":"text","text":"…"}]}}
# The `"(content":"|text":")` anchor matches both.
SELF_RE='"(content":"|text":")(Session transcript to analyze \(literal absolute path\)|Findings directory to aggregate \(literal absolute path\)|SESSION_PATH=|FINDINGS_DIR=)'

# The FIRST user-turn record, whichever shape the transcript uses. Claude persists
# user turns as {"type":"user",...}; OMP as {"type":"message",...} with a message
# object whose role is "user" (assistant/system records never match). `-m1` stops at
# the first record matching either shape, so callers always get the first user turn.
first_user_turn() { # $1 = jsonl path → first user-turn record line (or nothing)
  grep -m1 -E '"type":"user"|"type":"message".*"message":\{"role":"user"' "$1" 2>/dev/null
}

# Second vector: an orphan AI-title stub. Claude Code's async title generation writes
# a one-line `{"type":"ai-title",...}` record into the worker's session bucket even
# under --no-session-persistence (which only suppresses the full transcript). These
# stubs carry NO conversation, so the first-user-turn rule above never catches them.
# We match them by the model-generated title, which paraphrases our L1/L2 prompts
# (e.g. "Analyze Claude session findings", "Triage coding session for findings",
# "Aggregate daily findings into report"). Safety comes from REQUIRING the file to be
# an orphan stub — no user turn anywhere. A real session is a single file containing
# its title alongside its turns, so it always has a user turn and is never matched;
# only headless calls that didn't persist a transcript leave a title-only orphan. And
# we still demand the title describe session triage / findings aggregation, so a real
# headless orphan about an unrelated task (e.g. "GCU Rush firmware development") is
# spared. Tuned against the real backlog: catches the L1/L2 title variants, spares
# terminal-tab-title stubs and unrelated work-session orphans.
is_self_title() { # $1 = jsonl path → exit 0 if it's an autodream orphan title stub
  first_user_turn "$1" | grep -q . && return 1   # has conversation → not an orphan
  local t
  t=$(sed -n 's/.*"aiTitle":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1)
  [ -n "$t" ] || return 1
  # L2 aggregator: aggregating per-session findings into the daily report
  printf '%s' "$t" | grep -qiE 'aggregate.*findings|findings.*(into|report)' && return 0
  # L1 triage, "session triage … findings" phrasings (verb may follow the noun)
  printf '%s' "$t" | grep -qiE 'session triage|triage.*findings|findings.*extraction' && return 0
  # L1 triage: a verb acting on a session/transcript, producing findings/triage/analysis
  printf '%s' "$t" | grep -qiE '(analyz|triag|process|review|debug).*(session|transcript)' \
    && printf '%s' "$t" | grep -qiE 'findings|transcript|triage|analysis|extract|emit|structured' \
    && return 0
  return 1
}

is_self() { # $1 = jsonl path → exit 0 if it's an autodream-generated session
  first_user_turn "$1" | grep -qE "$SELF_RE" && return 0
  is_self_title "$1"
}

# ---- --filter: stdin paths -> stdout the ones we should still triage ----
if [ "${1:-}" = "--filter" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_self "$f" || printf '%s\n' "$f"
  done
  exit 0
fi

# ---- scan/list/delete ----
DELETE=0; QUIET=0; SCAN_DIR=""
for a in "$@"; do
  case "$a" in
    --delete) DELETE=1 ;;
    --quiet)  QUIET=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) SCAN_DIR="$a" ;;
  esac
done
PROJECTS_DIR="${SCAN_DIR:-${PROJECTS_DIR:-$HOME/.omp/agent/sessions}}"

[ -d "$PROJECTS_DIR" ] || { echo "no such projects dir: $PROJECTS_DIR" >&2; exit 1; }

count=0; bytes=0
while IFS= read -r f; do
  is_self "$f" || continue
  count=$((count + 1))
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' '); bytes=$((bytes + ${sz:-0}))
  [ "$QUIET" = 1 ] || echo "$f"
  [ "$DELETE" = 1 ] && rm -f "$f"
done < <(find "$PROJECTS_DIR" -type f -name '*.jsonl' 2>/dev/null)

mb=$(( bytes / 1048576 ))
if [ "$DELETE" = 1 ]; then
  echo "deleted $count autodream-own session file(s) (~${mb} MB) under $PROJECTS_DIR"
else
  echo "found $count autodream-own session file(s) (~${mb} MB) under $PROJECTS_DIR  (re-run with --delete to remove)"
fi
