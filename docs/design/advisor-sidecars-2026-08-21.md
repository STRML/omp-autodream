# Design doc: OMP advisor sidecars get a restricted triage schema

Implemented 2026-08-21. Resolves the 2026-08-19 report's open question 1, after the same
contamination recurred on 2026-08-20.

## Problem

OMP writes an `__advisor.jsonl` next to a session's own transcript. It records an *advisor*:
a second model that tails the primary session, reviews each completed turn, and injects
advice back. It is an observability record, not an agent session — the Agent Hub lists
advisor rows as un-messageable for exactly this reason.

`bin/run.sh`'s enumeration is `find … -name '*.jsonl'`, so these were triaged as if they
were sessions. Three distinct failures followed.

**1. False findings, concentrated in three categories.** An advisor's default toolset is
`read`, `grep`, and `glob` — nothing else, unless a `WATCHDOG.yml` roster entry grants it
(none is configured on this machine). So `Tool "bash" not available` and
`Tool "write" not available` are the transcript type's *normal shape*. L1 read them as
`sandbox_friction`, and read repeated attempts against those unavailable tools as
`tool_loop`. A third category, `missed_skill`, fired on `tool_call_count: 0`.

Seven false findings across two nights, five rated high:

| Date | Finding | Category | Actual cause |
|---|---|---|---|
| 08-19 | `bf6c16fbd46b` | `sandbox_friction` high + `tool_loop` high | no bash in advisor toolset |
| 08-19 | `cb9daa2c91d2` | `sandbox_friction` high | same |
| 08-19 | `9577d6911bf1` | `missed_skill` high, naming no skill | `tool_call_count: 0` is normal here |
| 08-20 | `759d229af657` et al. | `sandbox_friction` high (report pattern #2, 6 sessions) | same |
| 08-20 | `-sites-console-mode` advisor | `missed_skill` high | parent *had* invoked both skills |

The 08-20 run also spent a whole open question asking whether the missing bash was a
`omp-bash-classifier` plugin defect. It is not, and cannot be: that plugin registers a
`tool_call` handler **for `bash` only**, and an advisor never reaches it, because `bash`
is absent from the toolset before any handler runs.

**2. Turn counts inflated past the point of meaning.** On 2026-08-19, 8 of 53 non-gated
sessions were advisor sidecars carrying 4,813 of 6,551 turns — 73% of the reported total,
and 0 of 2,253 tool calls. The headline activity number described the reviewer, not the work.

**3. Overlap saturated at 100%.** An advisor inherits its parent's user-turn timestamps by
construction, so it overlaps its parent every time. `sessions_with_overlap` read 90 of 90
on 08-19 and 629 of 629 on 08-20. A statistic that fires on every session carries no
information, and the "multi-clauding" signal it was built for (#14) was lost entirely.

## Why not skip them at discovery

A one-line basename filter was the obvious fix and is the wrong one. Advisor streams
carry content that appears nowhere else: the 08-19 report names `2364298c8c9d`'s DFlash2
benchmark narrative and `b6b063ceb72d`'s Bartender integration as visible *only* through
the advisor, since neither parent transcript surfaced a finding. Every contaminated
finding was in a **tool-behavior** category, which is precisely the axis where an advisor
is structurally different from an agent. Suppressing that axis is narrower than dropping
the transcript, and it costs nothing else.

## Mechanism

Detection is by filename, computed mechanically in `bin/session-stats.sh` — no model call,
and no dependence on transcript contents that a slimming pass might remove:

```sh
case "$(basename "$transcript")" in
  __advisor.jsonl|__advisor-*.jsonl) is_advisor=true ;;
  *) is_advisor=false ;;
esac
```

The stem is reserved by OMP (`blob-artifact-architecture.md`: "the reserved advisor
transcript stem is never allocated unchanged"), so the name cannot collide with a real
session. Matching is anchored: `my__advisor.jsonl` does not flag, and there is a test for it.

`is_advisor` lands in the `*.stats.json` sidecar, which `dispatch_l1` already injects into
the L1 prompt as an authoritative block (`bin/run.sh:652-656`). No dispatch change was
needed. Three consumers read it:

- **`prompts/SESSION_TRIAGE.md`** — forbids `sandbox_friction`, `tool_loop`, and
  `missed_skill` on advisor transcripts; explicitly keeps `buggy_code_shipped`,
  `fabricated_id`, `memory_miss`, `stop_projection`, and `drift_after_compaction` in scope;
  requires `is_advisor: true` on the output object.
- **`bin/overlap-stats.sh`** — drops these sidecars from the pairing corpus.
- **`prompts/PROMPT.md`** — excludes advisor `turn_count` from the reported session-turn
  total, treats any tool-behavior finding still arriving from an advisor as an L1 rule
  violation belonging under Triage failures, and forbids an advisor finding and its
  parent's finding from both counting toward one pattern's session count.

## Compatibility

`is_advisor` is absent from every sidecar written before this change. `overlap-stats.sh`
tests `.is_advisor != true`, so `null` keeps the record and historical findings directories
pair exactly as they did before. Re-running an old date is not required, and does not change
its numbers unless its sidecars are regenerated.

## What this does not fix

The 1:1 double-count is *reduced*, not eliminated: an advisor still occupies a session slot
in the count of sessions triaged, and L2 is instructed rather than mechanically prevented
from ranking an advisor finding alongside its parent's. Folding advisor content into the
parent's finding record was considered and deferred — it needs the parent↔advisor pairing to
be resolved at enumeration time (same directory, same UUID), which is a larger change to
`dispatch_l1`'s keying than this fix warrants.

## Verification

Against the real 2026-08-20 advisor transcript that produced report pattern #2
(`-sites-omp-bash-classifier/2026-08-20T16-30-01-870Z_01a02002.../__advisor.jsonl`):

```
{"is_advisor":true,"turn_count":2461,"tool_call_count":0,
 "user_message_count":2213,"duration_minutes":1284.2}
```

2,461 turns and **zero** tool calls over 21 hours — the shape this whole change exists to
stop mistaking for sandbox friction. `tests/run-all.sh`: 320 passed, 0 failed (was 312
before, +8 assertions covering filename anchoring, the sidecar field inventory, and the
overlap exclusion).

Note that this repo's `bin/session-stats.sh` parses OMP's record shape (`type: "message"`,
`custom`/`tool_execution_start`, `model_change`) per `PORT_CONTRACT.md`. The upstream
`cc-autodream` parser walks Claude's `type: "user"/"assistant"` shape and returns
`turn_count: 0` on the same file — which is why this fix lives here and was not ported
upstream: Claude Code has no advisor subsystem and never writes an `__advisor.jsonl`.
