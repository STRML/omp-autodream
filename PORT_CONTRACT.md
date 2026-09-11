# omp-autodream port contract (2026-08-17)

Cross-slice interfaces for porting cc-autodream to OMP. All slices agree on these.

## Engine binary
- L1/L2 workers invoke `omp` = `/opt/homebrew/bin/omp` (env `OMP_BIN`, default `/opt/homebrew/bin/omp`).
- Never invoke `claude` in the OMP variant.
- Headless invocation pattern per worker:
  `$OMP_BIN --allow-home -p --permission-mode bypassPermissions --no-session-persistence --strict-mcp-config --disable-slash-commands --config "$NO_ADVISOR_CFG" [--model <L1_MODEL>]`
- Tools grant: L1 workers get `--tools=Read,Write` (read the transcript, write the findings JSON); the L2 aggregator gets `--tools=Glob,Read` — no Write/Edit, because L2 emits the report on stdout only and must never touch files. Both flags are accepted by omp.

## Advisor-off overlay (REQUIRED on every worker)
- File: `$AUTODREAM_DIR/l1-no-advisor.yml` (written by install.sh), content:
  ```yaml
  advisor:
    enabled: false
    subagents: false
  ```
- Passed as `--config` to every L1 worker AND the L2 aggregator so no headless worker boots the opus advisor (verified: it DOES fire in print mode otherwise). env `NO_ADVISOR_CFG`.

## Session roots (OMP)
- OMP sessions live at `$HOME/.omp/agent/sessions/<project-encoded>/<TS>_<uuid>.jsonl`, one JSONL per session dir, project-encoded dirs like `-git-rush-rushautoworks`/`--private-tmp--`.
- Replace Claude's `~/.claude*/projects` scanning with: `SESSION_ROOTS` default `$HOME/.omp/agent/sessions`.
  - root-probe.sh: probe `$HOME/.omp/agent/sessions` (single root; OMP has one config dir). Keep the index/ignore conf machinery but with OMP path default.
- Self-prune: `omp -p` workers with `--no-session-persistence` leave no transcript; fall back to pruning any transcript whose FIRST user turn is an inlined autodream prompt (same predicate, works on OMP shape).

## OMP transcript format (for session-stats.sh and any parsing)
- Records are newline-JSON. User turns: `{"type":"message","message":{"role":"user","content":[{"type":"text","text":...}]}}`.
- Assistant turns: `{"type":"message","message":{"role":"assistant","content":[...]}}`.
- Tool usage: separate records `{"type":"custom","customType":"tool_execution_start","data":{"toolCallId","toolName","startedAt","args","intent"...}}`. Count `tool_call_count` from these.
- NO `isMeta` field on OMP messages; meta/UI content is `{"type":"custom_message",...}` records (never counted as user turns).
- Model provenance: `{"type":"model_change","model":"..."}` records; `models_used` from these.
- Any `message` with `message.role=="user"` and a text content item = one user message.
- User-turn timestamps: from the record's own `timestamp` field (ISO).
- Sidechain/subagent: OMP marks subagent transcripts — use custom_type markers; default `isSidechain:false` unless a `custom` record signals subagent (e.g. `agent`/`subagent` custom types). Keep bias-to-triage on unknown.

## Findings/reports/state
- `findings/<date>/`, `dreams/<date>.md`, `notes.md`, `inbox/`, `run-stats.txt`, report-complete marker `autodream:open-questions=`, L1 idempotency (findings JSON with `.findings` key), retry rounds, SIGPIPE hardening, consume gates. The port keeps all of these.
- L2 report delivery changed: the aggregator has NO Write tool. It prints the report on stdout ending with an `AUTODREAM_REPORT_END` line; run.sh strips everything from the LAST sentinel into `dreams/<date>.md` (atomic tmp+rename) and appends the post-sentinel `report:` + 3-line summary to the run log. A capture is a validated delivery only with the sentinel present AND the `autodream:open-questions=` marker.

## L1/L2 models
- L1: `deepseek/deepseek-flash` (env `AUTODREAM_L1_MODEL`, default that). This said
  `runinfra/deepseek-v4-flash` until 2026-09-11 while the code ran `anthropic/claude-haiku`;
  nothing sets the env var, so the invocation's `:-` default is the model in force, and
  that runinfra id is not in `models.yml`. Alternate measured the same day:
  `zai/glm-5.3-flash`, ~4x slower, static apiKey instead of OAuth.
- L2: `anthropic/claude-opus-5` (env `AUTODREAM_L2_MODEL`, default that). Auth: agent.db OAuth (file-based, safe at 3am).
- L1 auth: `deepseek` uses `auth: oauth` from `models.yml`, so no key is needed and none is
  read. The keychain mitigation described here before 2026-09-11 was never implemented —
  `run.sh` sources `$AUTODREAM_DIR/x-credentials` and has no keychain fallback, and the
  installed x-credentials holds only the X/Twitter cookie pair. A key that lives solely in
  the keychain reaches the workers unset.
- Both layers serialize one throwaway model call before the L1 fan-out (`l1_warmup` in
  run-stats, `AUTODREAM_L1_WARMUP=0` to disable) so a cold token is refreshed once rather
  than raced by every worker.

## Tests
- `tests/run-all.sh` must pass. `tests/mock-claude.sh` → add `tests/mock-omp.sh` emitting minimal `{type:"message"}` transcripts; keep existing fixtures' intent.
