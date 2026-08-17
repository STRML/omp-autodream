#!/bin/bash
# Emit minimal OMP-format session transcripts for cc-autodream integration tests.
#
# run.sh scans $HOME/.omp/agent/sessions/<project>/<TS>_<uuid>.jsonl. This helper
# stands in for a real OMP session file: it writes the OMP record shape that
# bin/session-stats.sh now parses — `message` records (role user/assistant) for
# turns, `custom` records for tool_execution_start / model_change, and
# customType "agent"/"subagent" to mark a sidechain. It replaces the
# Claude-shaped fixtures ($type:"user"/"assistant", tool_use-in-content, isMeta)
# that mock-claude.sh-era tests used, per PORT_CONTRACT.md §OMP transcript format.
#
# GUARD: only emits when MOCK is set in the environment, so a stray invocation
# can never clobber real session files. Set MOCK=1 (or a fixture name) to enable.
#
# Usage:  MOCK=1 tests/mock-omp.sh <output.jsonl> <fixture>
#   fixture: minimal (default) | carriers | timestamps | text-image | sidechain
# Exit:   0 on success, 2 on bad usage. Non-zero is never a "session" failure.

set -u

output="${1:-}"
fixture="${2:-minimal}"

if [ -z "${MOCK:-}" ]; then
  echo "mock-omp.sh: refusing to emit transcripts (MOCK env not set)" >&2
  exit 0
fi
[ -n "$output" ] || {
  echo "usage: MOCK=1 $0 <output.jsonl> <fixture>" >&2
  exit 2
}

emit(){ # $@ = one JSON record per arg; last literal arg may be raw "not json"
  : > "$output"
  for r in "$@"; do printf '%s\n' "$r" >> "$output"; done
}

case "$fixture" in
  minimal)
    # A couple message records (role user/assistant) + one custom
    # tool_execution_start — the minimal shape session-stats.sh expects.
    emit \
      '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"start the task"}]}}' \
      '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}' \
      '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Read","intent":"read"}}'
    ;;
  carriers)
    # OMP has no tool-result-carrier user messages: tool results are separate
    # message records (role=="toolResult") excluded from user_message_count AND
    # turn_count. A non-JSON line is dropped by the parser. This pins that the
    # OMP parser counts only real user/assistant message records.
    emit \
      '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"human question"}]}}' \
      '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"thinking"}]}}' \
      '{"type":"message","message":{"role":"toolResult","toolUseId":"a","content":"result"}}' \
      'not json' \
      '{"type":"message","message":{"role":"toolResult","toolUseId":"b","content":"result"}}'
    ;;
  timestamps)
    # Duration uses the widest/fractional timestamps on any record; models come
    # from model_change records; <synthetic> is dropped; user_turn_timestamps is
    # the single fraccional-truncated real user turn's epoch.
    emit \
      '{"type":"message","timestamp":"2026-07-20T10:00:00.500Z","message":{"role":"user","content":[{"type":"text","text":"start"}]}}' \
      '{"type":"message","message":{"role":"assistant","content":"middle"}}' \
      '{"type":"progress","timestamp":"2026-07-20T10:01:00.250Z"}' \
      '{"type":"model_change","model":"claude-opus"}' \
      '{"type":"model_change","model":"<synthetic>"}' \
      '{"type":"message","timestamp":"2026-07-20T10:02:30.750Z","message":{"role":"assistant","content":"end"}}'
    ;;
  text-image)
    # A text + image human turn still counts as exactly one user message.
    emit \
      '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"caption"},{"type":"image","source":{"type":"base64","data":"abc"}}]}}'
    ;;
  sidechain)
    # A subagent transcript: customType "subagent" flips isSidechain; its tool
    # calls arrive as custom tool_execution_start records (counted mechanically).
    # Composes to user_message_count 1, turn_count 5, tool_call_count 3.
    emit \
      '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"subagent task"}]}}' \
      '{"type":"custom","customType":"subagent","timestamp":"2026-07-20T10:00:00Z","data":{}}' \
      '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"running"}]}}' \
      '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Write"}}' \
      '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Bash"}}' \
      '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"Read"}}' \
      '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"more"}]}}' \
      '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}' \
      '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"end"}]}}'
    ;;
  *)
    echo "mock-omp.sh: unknown fixture <$fixture>" >&2
    exit 2
    ;;
esac

exit 0
