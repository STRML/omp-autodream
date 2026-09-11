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
#   MOCK_MODE=l1_partial_then_stall  exactly ONE session ever succeeds (claimed via an
#                            atomic mkdir under MOCK_STATE_DIR, which the test must set);
#                            round 1 recovers something, every later round recovers
#                            nothing. Pins the circuit breaker's no-progress streak.
#   MOCK_MODE=l1_incomplete  L1 writes nothing (simulates a worker that exits
#                            without producing JSON); L2 still emits its report.
#   MOCK_MODE=l1_exit124     L1 exits 124 immediately; MOCK_MODE=l1_exit137 SIGKILLs
#                            itself. Both are what GNU timeout returns for a real
#                            deadline, so they prove classification is not by rc alone.
#   MOCK_MODE=l1_hang        L1 never exits and leaves a child behind, which is the
#                            shape of the 2026-08-19/08-22 wedge. Pair with a small
#                            AUTODREAM_L1_TIMEOUT and MOCK_HANG_PIDS=<file> to assert
#                            the child was reaped with the process group.
#   MOCK_MODE=l2_fail        L2 emits nothing and exits 1 (simulates the
#                            aggregator dying to a mid-run sleep). L1 is unaffected.
#                            Pair with AUTODREAM_L2_ATTEMPTS=1 so the test doesn't
#                            sit through the retry loop.
#   MOCK_MODE=l2_partial_marker  L2 emits a COMPLETE-LOOKING report — it carries the
#                            autodream:open-questions marker — but NO
#                            AUTODREAM_REPORT_END sentinel, then exits 0. This is the
#                            P1 bug shape: any completion test that trusts only the
#                            marker would call this delivered. run.sh must treat the
#                            missing sentinel as non-delivery (retry, move the
#                            capture aside, never consume against it).
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

# ---- Pre-fanout auth warmup ----
# run.sh pipes the single word `ping` before dispatching L1. It is neither layer, and
# without this branch it fell through to the L2 aggregator below, where line2 is empty and
# the report destination resolves to nothing. Handle it first and explicitly.
#
# In the failure modes it answers the way a dead omp does — exit 0, NOTHING on stdout, the
# usual chatter on stderr. That is the whole signature the warmup exists to catch, and a
# fixture that always printed something made `l1_warmup: ok` unfalsifiable.
if [ "$line1" = "ping" ]; then
  printf 'Working...\n' >&2
  case "$mode" in
    l1_incomplete|l1_noisy_fail|l1_hang|l1_exit124|l1_exit137) : ;;
    *) echo ok ;;
  esac
  exit 0
fi

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
    l1_malformed)                       # non-empty output that is not a findings JSON.
      # The runner used to accept any non-empty file as success, delete both diagnostics,
      # and hand this to L2 on the final round.
      printf 'this is not json at all\n' > "$out"
      echo done
      exit 0 ;;
    l1_wrongtype)                       # .findings present but a STRING, not an array.
      # jq -e .findings is truthy for this, so it used to pass both the idempotency read
      # and the outbound validation and reach L2 as a successful result.
      printf '{"session_path":"x","findings":"oops"}' > "$out"
      echo done
      exit 0 ;;
    l1_noisy_fail)                      # writes nothing, but says WHY on stdout and exits
      # nonzero. This is the real shape: omp puts its diagnosis on stdout and only
      # "Working..." on stderr, and run.sh sent stdout to /dev/null, so every failure
      # arrived looking identical. Pins the exit-code and stdout capture.
      echo "provider error: 429 rate_limit_exceeded"
      exit 7 ;;
    l1_exit124) exit 124 ;;             # intrinsic 124, no deadline involved. GNU timeout
                                        # propagates a child's own status, so this arrives
                                        # looking exactly like a timeout; only elapsed tells
                                        # them apart.
    l1_exit137) kill -9 $$ ;;           # intrinsic 137, same reasoning
    l1_hang)                            # never exit, and leave a child behind. The child is
      # the point: it outlives a kill aimed at this process alone, so a test that
      # finds it gone proves the timeout signalled the whole process group, which
      # is what stops the real node_repl/mnemopi_embed orphans from piling up.
      sleep 600 & printf '%s\n' "$!" >> "${MOCK_HANG_PIDS:-/dev/null}"
      sleep 600 ;;
    l1_badproject) write_badproject ;;  # wrong project + real path — exercises normalization
    l1_flaky)                           # fail the first dispatch per session, succeed on retry
      if [ -f "$out.attempt" ]; then write_findings; else : > "$out.attempt"; fi ;;
    l1_partial_then_stall)
      # Exactly one session ever succeeds; every other one fails forever. Round 1 therefore
      # RECOVERS something while later rounds recover nothing — the shape that exposed the
      # circuit breaker's off-by-one, where comparing a round's ending count against the
      # previous round's ending count called two rounds barren as soon as the second was.
      #
      # mkdir, not a file test: workers run at FANOUT 8, so a test-then-create would let
      # several of them win the claim at once and the fixture would recover a different
      # number of sessions per run. mkdir succeeds for exactly one caller.
      if mkdir "${MOCK_STATE_DIR:?l1_partial_then_stall needs MOCK_STATE_DIR}/one-succeeded" 2>/dev/null; then
        write_findings
      fi ;;
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
  # l2_partial_marker: an otherwise complete report (it carries the open-questions
  # marker report_complete() checks) but no AUTODREAM_REPORT_END sentinel. Report
  # marker alone must not count as delivery — the sentinel is the completion proof.
  if [ "$mode" = "l2_partial_marker" ]; then
    printf '# Autodream — mock\n\nmock aggregate report\n\n<!-- autodream:open-questions=0 -->\n'
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
