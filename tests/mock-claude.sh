#!/bin/bash
# Mock `claude` binary for cc-autodream integration tests.
#
# run.sh invokes the real claude CLI for both layers. Here we stand in for it:
# read the prompt on stdin, find the two literal-path lines run.sh inlined, and
# produce output — no model, no network. Which layer we are is decided by line 1
# of the prompt. L1 writes its findings JSON; L2 no longer claims Write — it emits
# the report on stdout, ending with AUTODREAM_REPORT_END (run.sh writes the file).
#
# Env knobs (all optional):
#   MOCK_MODE=good           write findings (L1) / emit report on stdout (L2). [default]
#   MOCK_MODE=l1_incomplete  L1 writes nothing (simulates a worker that exits
#                            without producing JSON); L2 still emits its report.
#   MOCK_MODE=l2_fail        L2 emits nothing and exits 1 (simulates the
#                            aggregator dying to a mid-run sleep). L1 is unaffected.
#                            Pair with AUTODREAM_L2_ATTEMPTS=1 so the test doesn't
#                            sit through the retry loop.
#   MOCK_CAPTURE_DIR=<dir>   dump each layer's stdin + argv to <dir>/l{1,2}-*.txt
#                            so tests can assert on the exact prompt framing.
#   MOCK_CALL_LOG=<file>     append the L1 output path for every invocation of
#                            this mock, one per line — lets a test prove the
#                            model was (or was not) invoked for a given session
#                            (e.g. a noise-gated session should never appear).

input=$(cat)
mode="${MOCK_MODE:-good}"
line1=$(printf '%s\n' "$input" | sed -n '1p')
line2=$(printf '%s\n' "$input" | sed -n '2p')

if printf '%s' "$line1" | grep -q '^Session transcript'; then
  # ---- Layer 1: triage worker ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l1-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l1-args.txt"
  fi
  out=$(printf '%s' "$line2" | sed 's/^Write your findings JSON to this literal absolute path: //')
  sess=$(printf '%s' "$line1" | sed 's/^Session transcript to analyze (literal absolute path): //')
  [ -n "${MOCK_CALL_LOG:-}" ] && printf '%s\n' "$out" >> "$MOCK_CALL_LOG"
  write_findings() { printf '{"session_path":"x","project":"proj-a","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"underlying_goal":null,"outcome":"fully_achieved","satisfaction_signals":{"happy":0,"satisfied":1,"dissatisfied":0,"frustrated":0},"instructions_given":["always run tests after edits"],"findings":[]}' > "$out"; }
  # Emit a real session_path but a deliberately WRONG project (what nondeterministic
  # haiku does), so run.sh's path-based normalization pass has something to correct.
  write_badproject() { printf '{"session_path":"%s","project":"WRONG-PROJECT","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"findings":[]}' "$sess" > "$out"; }
  case "$mode" in
    l1_incomplete) : ;;                 # never write — simulates a worker that exits empty
    l1_badproject) write_badproject ;;  # wrong project + real path — exercises normalization
    l1_flaky)                           # fail the first dispatch per session, succeed on retry
      if [ -f "$out.attempt" ]; then write_findings; else : > "$out.attempt"; fi ;;
    *) write_findings ;;
  esac
  echo done
else
  # ---- Layer 2: aggregator ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l2-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l2-args.txt"
  fi
  rep=$(printf '%s' "$line2" | sed 's/^Report destination (literal absolute path): //')
  if [ "$mode" = "l2_fail" ]; then
    echo "mock: aggregator failed" >&2
    exit 1
  fi
  # l2_partial: a NON-EMPTY report with no AUTODREAM_REPORT_END sentinel — what a
  # mid-output kill leaves behind. run.sh keeps the whole capture as a degraded report;
  # `-s` cannot tell that from a good report, which is why run.sh checks the marker.
  if [ "$mode" = "l2_partial" ]; then
    printf '# Autodream — mock\n\n## Top patterns\n\n1. truncated mid-w'
    echo "mock: partial stdout, no sentinel" >&2
    exit 0
  fi
  # The open-questions marker is part of the real contract (PROMPT.md mandates it) and
  # run.sh treats its absence as a truncated report, so the mock's good path emits it
  # too — on stdout, ending with the AUTODREAM_REPORT_END sentinel the runner strips.
  printf '# Autodream — mock\n\nmock aggregate report\n\n<!-- autodream:open-questions=0 -->\n'
  echo "AUTODREAM_REPORT_END"
  echo "report: $rep"
  echo "sessions reviewed: 1"
  echo "findings: 0"
fi
