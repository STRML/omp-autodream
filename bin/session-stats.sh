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

mkdir -p "$(dirname "$output")" || exit 1

jq -R -s \
  --argjson transcript_bytes "${bytes:-0}" \
  --argjson transcript_mtime "${mtime:-0}" \
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
  # Skill INVOCATION. OMP records it exactly one way: a custom_message of customType
  # "skill-prompt" whose content opens with the bracket line below and then inlines the
  # whole skill. There is no skill tool call and no other customType, so this record is
  # the only mechanical trace a skill ever leaves. Verified against all 204 transcripts in
  # the OMP store on 2026-09-05: 7 such records, every one matching this pattern.
  #
  # This field used to be filled in by haiku, and it was unmeasurable, not merely noisy —
  # the 2026-09-04 report read `skills_invoked: []` on a session that called manage_skill
  # ten times and concluded the ~200-skill inventory never fires. Those calls were skill
  # AUTHORING, which is why $skills_authored below is counted separately: "wrote five
  # skills, invoked none" and "ignored the inventory" are different findings.
  | [
      $lines[]
      | select(.type == "custom_message" and (.customType? // "") == "skill-prompt")
      | .content
      | select(type == "string")
      | (try (capture("^\\[IMPORTANT: User invoked the \"(?<name>[^\"]+)\" skill") | .name) catch empty)
    ] as $skills_invoked
  # Both record shapes, unioned. PORT_CONTRACT.md documents tool usage as
  # custom/tool_execution_start records, and those DO carry a data.args payload —
  # measured across the OMP store on 2026-09-06: 20,185 of 26,308 such records have it.
  # For manage_skill specifically they carry data.intent and no args, so the skill NAME
  # is only present in the assistant toolCall block; a parse of the documented shape
  # alone returns nothing for this field. Reading both is the only version that is right
  # whichever shape a given provider emits, and it costs one extra pass over $lines.
  | ([
      $lines[]
      | select(.type == "message")
      | .message.content
      | select(type == "array")
      | .[]
      | select(type == "object" and .type == "toolCall" and ((.name? // .toolName? // "") == "manage_skill"))
      | .arguments
      | select(type == "object")
      | .name
      | select(type == "string" and length > 0)
    ] + [
      $lines[]
      | select(.type == "custom" and .customType == "tool_execution_start")
      | .data
      | select(type == "object" and (.toolName? == "manage_skill"))
      | .args
      | select(type == "object")
      | .name
      | select(type == "string" and length > 0)
    ]) as $skills_authored
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
      skills_invoked: ($skills_invoked | unique | sort),
      skills_invoked_count: ($skills_invoked | length),
      # PROMPT.md asks for "top 5 skills by count", which the unique list cannot answer
      # and the bare total answers for the wrong question: two runs of one skill and one
      # run each of two others both come out as 3. Name to count, so the ranking is real.
      skills_invoked_counts: ($skills_invoked | group_by(.) | map({key: .[0], value: length}) | from_entries),
      skills_authored: ($skills_authored | unique | sort),
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
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
