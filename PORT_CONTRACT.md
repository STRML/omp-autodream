# omp-autodream port contract (2026-08-17)

Cross-slice interfaces for porting cc-autodream to OMP. All slices agree on these.

## Engine binary
- L1/L2 workers invoke `omp` = `/opt/homebrew/bin/omp` (env `OMP_BIN`, default `/opt/homebrew/bin/omp`).
- Never invoke `claude` in the OMP variant.
- Headless invocation pattern per worker:
  `$OMP_BIN --allow-home -p --permission-mode bypassPermissions --no-session-persistence --strict-mcp-config --disable-slash-commands --config "$NO_ADVISOR_CFG" [--model <L1_MODEL>]`
- Tools grant: keep `--tools Read Write` (L1) and `--tools Glob Read Write Edit` (L2) if omp accepts the same flag; if omp rejects `--tools`, drop it (L1/L2 already get a scoped tool surface via system prompt).

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

## Findings/reports/state — UNCHANGED by the port
- `findings/<date>/`, `dreams/<date>.md`, `notes.md`, `inbox/`, `run-stats.txt`, report-complete marker `autodream:open-questions=`, L1 idempotency (findings JSON with `.findings` key), retry rounds, SIGPIPE hardening, consume gates. Port does NOT touch these.

## L1/L2 models
- L1: `runinfra/deepseek-v4-flash` (env `AUTODREAM_L1_MODEL`, default that).
- L2: `anthropic/claude-opus-5` (env `AUTODREAM_L2_MODEL`, default that). Auth: agent.db OAuth (file-based, safe at 3am).
- L1 auth risk: runinfra key is in the login keychain (`!security` escape). At 3am a locked keychain would kill L1. MITIGATION: run.sh sources `RUNINFRA_API_KEY` from `$AUTODREAM_DIR/x-credentials` (chmod 600) if present, else falls back to keychain; documented. (x-credentials already exists for x-bookmarks.)

## Tests
- `tests/run-all.sh` must pass. `tests/mock-claude.sh` → add `tests/mock-omp.sh` emitting minimal `{type:"message"}` transcripts; keep existing fixtures' intent.
