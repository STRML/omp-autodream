#!/bin/bash
# Deterministic, model-free session statistics sidecar for cc-autodream L1 triage.

set -u

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <transcript.jsonl> <out.stats.json>" >&2
  exit 2
fi

transcript="$1"
output="$2"

[ -r "$transcript" ] || {
  echo "session-stats: transcript is not readable: $transcript" >&2
  exit 1
}

bytes=$(wc -c < "$transcript" | tr -d ' ')
mtime=$(stat -f %m "$transcript" 2>/dev/null) || {
  echo "session-stats: could not read transcript mtime: $transcript" >&2
  exit 1
}

# OMP advisor sidecars (`__advisor.jsonl`, `__advisor-<name>.jsonl`) are observability
# records of a reviewer model watching a primary session — not agent sessions. Per omp's
# advisor-watchdog docs the advisor's default toolset is read/grep/glob only, so
# `Tool "bash" not available` and `tool_call_count: 0` are its normal shape, not sandbox
# friction. They also pair 1:1 with a separately-triaged parent transcript in the same
# session dir, so counting their turns or pairing them for overlap double-counts one
# session. Flagged here (mechanically, from the filename — no dependence on transcript
# content a slimming pass might drop) so L1 can restrict its schema and overlap-stats.sh
# can drop them from the pairing corpus. The stem is reserved by omp, so it cannot
# collide with a real session. See docs/design/advisor-sidecars-2026-08-21.md.
case "$(basename "$transcript")" in
  __advisor.jsonl|__advisor-*.jsonl) is_advisor=true ;;
  *) is_advisor=false ;;
esac

mkdir -p "$(dirname "$output")" || exit 1

jq -R -s \
  --argjson transcript_bytes "${bytes:-0}" \
  --argjson transcript_mtime "${mtime:-0}" \
  --argjson is_advisor "$is_advisor" \
  '
  [
    split("\n")[]
    | fromjson?
    | select(type == "object")
  ] as $lines
  | [
      $lines[]
      | select(.type == "message" and (.message.role? // "") == "user")
      | .message.content
      | select(
          type == "string"
          or (
            type == "array"
            and any(.[]?; .type == "text")
            and all(.[]?; .type != "tool_result")
          )
        )
    ] as $user_messages
  | (
      [
        $lines[]
        | select(.type == "message" and (.message.role? // "") == "user")
        | select(
            (.message.content) as $c
            | ($c | type) == "string"
            or (
              ($c | type) == "array"
              and any($c[]?; .type == "text")
              and all($c[]?; .type != "tool_result")
            )
          )
        | .timestamp
        | select(type == "string")
        | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
      ] | sort
    ) as $user_turn_timestamps
  | [
      $lines[]
      | select(
          .type == "message"
          and (((.message.role? // "") == "user") or ((.message.role? // "") == "assistant"))
        )
    ] as $turns
  | [
      $lines[]
      | select(.type == "custom" and .customType == "tool_execution_start")
    ] as $tool_uses
  | [
      $lines[]
      | select(.type == "model_change")
      | .model
      | select(type == "string" and length > 0 and . != "<synthetic>")
    ] as $models
  | [
      $lines[]
      | select(has("timestamp"))
      | .timestamp
      | select(type == "string")
      | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
    ] as $timestamps
  | {
      user_message_count: ($user_messages | length),
      turn_count: ($turns | length),
      tool_call_count: ($tool_uses | length),
      tools_used: (
        $tool_uses
        | map(.data.toolName)
        | map(select(type == "string"))
        | unique
        | sort
      ),
      models_used: ($models | unique | sort),
      duration_minutes: (
        if ($timestamps | length) < 2 then 0
        else (((($timestamps | max) - ($timestamps | min)) / 60) * 10 | round) / 10
        end
      ),
      # compliance_markers retired 2026-08-08: the detector was correct
      # (line-start, non-sidechain, fence-aware) but no session in the entire
      # transcript archive ever emitted one. It measured only silence.
      transcript_bytes: $transcript_bytes,
      transcript_mtime: $transcript_mtime,
      isSidechain: (any($lines[]?; ((.customType? // "") == "agent") or ((.customType? // "") == "subagent"))),
      is_advisor: $is_advisor,
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
