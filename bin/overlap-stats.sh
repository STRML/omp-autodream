#!/bin/bash
# Deterministic, model-free global overlap pass for cc-autodream (GitHub issue #14).
#
# Cross-session computation: given a findings directory already populated with
# per-session *.stats.json sidecars (written by session-stats.sh's user_turn_timestamps
# field), compute how many distinct session pairs had a user turn within 30 minutes of
# each other ("multi-clauding" — the same human working two sessions concurrently).
#
# Definition (issue #14, unit pinned to seconds):
#   overlap_events        = number of DISTINCT unordered session-id pairs {A,B} such
#                            that some user turn of A and some user turn of B occur
#                            within WINDOW_SECONDS of each other. Pair-set semantics:
#                            a pair counts ONCE no matter how many turn-pairs qualify.
#   sessions_with_overlap = number of distinct session ids appearing in at least one
#                            such pair.
#
# Session identity: the sidecar's filename stem, i.e. the 12-char sha1 hash of the
# session path that run.sh already uses as the findings-file key (see hash_of /
# compute_session_stats in bin/run.sh). Stable per session, no need to re-derive it
# from session_path.
#
# Gating note: run.sh's noise gate (#7) decides per-session whether to skip the L1
# model call, but it runs AFTER compute_session_stats has already written every
# session's *.stats.json sidecar. Gated sessions' sidecars still exist and still carry
# user_turn_timestamps, so they STILL participate in overlap here — this stat measures
# concurrent human activity, not triage-worthiness, and this script has no visibility
# into (and does not care about) the gate decision.
#
# Advisor exclusion: sidecars with `is_advisor: true` are DROPPED from the corpus.
# An OMP advisor sidecar is a reviewer model tailing its parent session, so it inherits
# the parent's user-turn timestamps by construction and overlaps it 100% of the time.
# Including them made the stat read 90-of-90 sessions on 2026-08-19 and 629-of-629 on
# 2026-08-20 — a measure that fires on every session carries no information. This is
# the one exclusion the gate note above does NOT cover: gated sessions are real
# concurrent human activity that simply wasn't worth triaging, whereas an advisor pair
# is the same human activity counted twice.
#
# Usage: overlap-stats.sh <findings_dir> [window_seconds]   (default window: 1800 = 30 min)
# Prints a single-line JSON object {"overlap_events":N,"sessions_with_overlap":N} to
# stdout. Never fails the caller: an empty/missing findings dir yields 0/0.

set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <findings_dir> [window_seconds]" >&2
  exit 2
fi

findings_dir="$1"
window="${2:-1800}"

if [ ! -d "$findings_dir" ]; then
  printf '{"overlap_events":0,"sessions_with_overlap":0}\n'
  exit 0
fi

# NDJSON: one {"id":..., "ts":[...]} line per sidecar. Missing/empty user_turn_timestamps
# (pre-#14 sidecars, or sessions with no timestamped user turns) become [] and simply
# can't form a pair — jq's has_overlap already short-circuits on an empty array.
# Advisor sidecars emit no line at all (see the header note). `is_advisor` is absent on
# pre-2026-08-21 sidecars, and `null != true` keeps them, so old findings dirs pair
# exactly as they did before.
build_session_list() {
  local f id
  for f in "$findings_dir"/*.stats.json; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .stats.json)
    jq -c --arg id "$id" 'select(.is_advisor != true) | {id: $id, ts: (.user_turn_timestamps // [])}' "$f" 2>/dev/null
  done
}

build_session_list | jq -s --argjson w "$window" '
  # Two-pointer sweep over two sorted epoch-second arrays: true iff some pair is
  # within $w seconds of each other. O(|a| + |b|) — deliberately not a cross product,
  # since a long session can carry hundreds of user-turn timestamps.
  def has_overlap($a; $b; $w):
    ($a | length) as $la | ($b | length) as $lb
    | if $la == 0 or $lb == 0 then false
      else
        { i: 0, j: 0, found: false }
        | until(
            .found or (.i >= $la) or (.j >= $lb);
            ($a[.i]) as $x | ($b[.j]) as $y
            | (($x - $y) | if . < 0 then -. else . end) as $d
            | if $d <= $w then .found = true
              elif $x < $y then .i += 1
              else .j += 1
              end
          )
        | .found
      end;

  [ .[] | select((.ts | length) > 0) ] as $sessions
  | ($sessions | length) as $n
  | reduce range(0; $n) as $i (
      { events: 0, involved: {} };
      reduce range($i + 1; $n) as $j (
        .;
        if has_overlap($sessions[$i].ts; $sessions[$j].ts; $w)
        then
          .events += 1
          | .involved[$sessions[$i].id] = true
          | .involved[$sessions[$j].id] = true
        else . end
      )
    )
  | { overlap_events: .events, sessions_with_overlap: (.involved | keys | length) }
'
