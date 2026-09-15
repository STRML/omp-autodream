#!/bin/bash
# Autodream runner — invoked by launchd at ~3am local time.
#
# Two-layer pipeline:
#   L1: For each of yesterday's session JSONLs, spawn a parallel `omp --model deepseek-flash`
#       running SESSION_TRIAGE.md → writes one findings.json per session.
#   L2: One `omp --model claude-opus-5` running PROMPT.md → reads all findings JSONs,
#       writes $DREAMS_DIR/YYYY-MM-DD.md.
#
# Usage:
#   ./run.sh             # process yesterday
#   ./run.sh 2026-05-24  # process a specific date
#   FANOUT=4 ./run.sh    # tune L1 parallelism (default 8)
#
# Environment overrides (all optional):
#   OMP_BIN        path to omp CLI      default: resolved from PATH, then
#                  ~/.local/bin, ~/.bun/bin, /opt/homebrew/bin, /usr/local/bin
#   NO_ADVISOR_CFG path to the advisor-off yaml passed as --config to every worker
#                  (keeps the opus advisor from booting on headless runs)
#                                                        default: $AUTODREAM_DIR/l1-no-advisor.yml
#   PROJECTS_DIR   single root: where session JSONLs live (kept for compat; one root)
#                  default: $HOME/.claude/projects
#   SESSION_ROOTS  colon-separated dirs to scan for session JSONLs. Takes precedence
#                  over PROJECTS_DIR. If neither is set, every $HOME/.claude*/projects
#                  that exists is scanned (primary always first) — each CLAUDE_CONFIG_DIR
#                  profile keeps its own projects/ bucket, so one-dir scanning silently
#                  missed sessions recorded under ~/.claude-nous, ~/.claude-ds4, ...
#   AUTODREAM_DIR  scripts + prompts + state           default: this script's own dir
#                  when it carries an install marker, else $HOME/.claude/autodream
#   DREAMS_DIR     where final reports are written     default: $(dirname AUTODREAM_DIR)/dreams
#   FANOUT         L1 parallelism                      default: 8
#   AUTODREAM_CHANGELOG  set 0 to skip the upstream-changelog check  default: 1
#   CLAUDE_CODE_REPO     persistent cache for the claude-code clone  default: $AUTODREAM_DIR/cache/claude-code
#   CHANGELOG_REMOTE     git remote for the Claude Code source. Setting it selects that
#                        source ALONE and suppresses the other two (back-compat, and how
#                        the test suite stays offline).
#   AUTODREAM_CHANGELOG_SOURCES  override the watched set. Semicolon-separated records of
#                        name|remote|path-in-repo|cache-dir. Default watches three
#                        harnesses, because the user works across all three:
#                          Claude Code|https://github.com/anthropics/claude-code.git|CHANGELOG.md|<cache>/claude-code
#                          Codex|https://github.com/openai/codex.git|CHANGELOG.md|<cache>/codex
#                          OMP|https://github.com/STRML/oh-my-pi.git|packages/coding-agent/CHANGELOG.md|<cache>/oh-my-pi
#                        OMP is a monorepo with no root CHANGELOG, hence the per-source path.
#   AUTODREAM_L1_ROUNDS  max L1 retry rounds for missing sessions    default: 5
#                        Two consecutive rounds that recover no session trip a circuit
#                        breaker: the run jumps straight to the stub round rather than
#                        spending the rest of the budget on an identical failure.
#   AUTODREAM_L1_WARMUP  set 0 to skip the pre-fanout auth warmup     default: 1
#                        One serial model call before the parallel dispatch, so a cold
#                        OAuth token is refreshed once instead of by FANOUT workers at
#                        once. Never fatal; result lands in run-stats as l1_warmup.
#   AUTODREAM_L1_WARMUP_TIMEOUT seconds before the warmup is killed    default: 120
#                        Must be a positive integer (0 would disable the deadline).
#   AUTODREAM_L2_ATTEMPTS max L2 attempts to produce a report        default: 3
#   AUTODREAM_RETRY_WAIT seconds to pause between retry rounds       default: 60
#   AUTODREAM_NETCHECK   set 0 to skip the pre-dispatch network check default: 1
#   AUTODREAM_NETCHECK_CAP seconds to wait for a route before deferring default: 1800
#   AUTODREAM_FORCE      set 1 to rebuild even if a report exists    default: 0
#   AUTODREAM_SLIM_BYTES sessions larger than this are slimmed for L1  default: 262144
#   AUTODREAM_L1_MODEL   override the L1 triage model                 default: deepseek/deepseek-flash
#                        Nothing sets AUTODREAM_L1_MODEL, so the `:-` default in the two
#                        invocations below (worker + warmup) IS the model in force. This
#                        line said runinfra/deepseek-v4-flash until 2026-09-11 while the
#                        code ran anthropic/claude-haiku, and three nights of failure were
#                        diagnosed against a provider the run never called — that id is
#                        not in models.yml at all. Change the invocations and this line
#                        together or not at all.
#                        Measured 2026-09-11 on the same 1.5 KB transcript, launchd-minimal
#                        env: deepseek/deepseek-flash 12s, zai/glm-5.3-flash 46s, both
#                        writing valid findings. The model was not why the 09-13 workers
#                        died: zai failed the same way on 2026-09-14. The cause was
#                        first-turn mnemopi recall, which l1-no-advisor.yml turns off.
#   AUTODREAM_L1_TIMEOUT seconds before an L1 worker is killed with     default: 1200
#                        its process group; needs timeout or gtimeout on PATH.
#                        Must be a positive integer (0 would disable the timeout).
#                        SIGKILL follows 30s after the SIGTERM, so the worst-case
#                        bound is AUTODREAM_L1_TIMEOUT + 30.
#   AUTODREAM_L2_MODEL   override the L2 aggregator model             default: anthropic/claude-opus-5
#   RUNINFRA_API_KEY     Only read if a runinfra model is selected, which the default is
#                        not. Sourced from $AUTODREAM_DIR/x-credentials (chmod 600) when
#                        that file defines it. There is NO keychain fallback: this block
#                        claimed one until 2026-09-11 and no code ever implemented it, so
#                        a keychain-only key reaches the workers unset. The installed
#                        x-credentials holds the X/Twitter cookie pair and no provider key.
#                        Both layers authenticate via agent.db OAuth by default.
#   AUTODREAM_MIN_USER_TURNS  noise-gate floor on user_message_count  default: 2
#   AUTODREAM_MIN_MINUTES     noise-gate floor on duration_minutes    default: 1
#   AUTODREAM_STATS_BIN       override the resolved session-stats.sh path, authoritative
#                             (no existability fallback — lets tests force missing or
#                             malformed stats sidecars)                default: unset
#   AUTODREAM_OVERLAP_BIN     override the resolved overlap-stats.sh path, authoritative
#                             (no existability fallback — lets tests force the "not
#                             measured" paths)                        default: unset
#   AUTODREAM_CONFIG     path to the sourced config file             default: $AUTODREAM_DIR/config
#   AUTODREAM_VAULT_DIR  autodream folder inside an Obsidian/synced vault; enables the
#                        inbox note surface + report publishing       default: unset (off)
#   AUTODREAM_VAULT_BIN  override the resolved vault-notes.sh path, authoritative
#   AUTODREAM_XBOOKMARKS_BIN override the resolved x-bookmarks.sh path, authoritative

set -u

# PROJECTS_DIR's default is applied here AND its explicit-ness is recorded, because the
# resolution order is SESSION_ROOTS > PROJECTS_DIR(explicit) > autodetect. `:-` can't
# tell "unset" from "set to the default", and treating the always-present default as
# explicit would make autodetect unreachable.
PROJECTS_DIR_EXPLICIT=0
if [ -n "${PROJECTS_DIR+x}" ]; then
  PROJECTS_DIR_EXPLICIT=1
  PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.omp/agent/sessions}"
else
  PROJECTS_DIR="$HOME/.omp/agent/sessions"
fi
# The install symlinks the scripts INTO $AUTODREAM_DIR (install.sh), so a bare
# shell invocation with no env resolves the install dir from this script's own
# location instead of the legacy ~/.claude/autodream default (the OMP port
# installs under ~/.omp/agent/autodream). Env still wins; the derived dir is
# only trusted when it carries an install marker file (install.sh writes both).
AUTODREAM_DIR="${AUTODREAM_DIR:-}"
if [ -z "$AUTODREAM_DIR" ]; then
  AUTODREAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -z "$AUTODREAM_DIR" ] || { [ ! -f "$AUTODREAM_DIR/config" ] && [ ! -f "$AUTODREAM_DIR/l1-no-advisor.yml" ]; }; then
    AUTODREAM_DIR="$HOME/.claude/autodream"
  fi
fi
# Advisor-off overlay, passed as --config to every headless worker (L1 + L2) so no
# worker boots the opus advisor (verified: it fires in print mode otherwise). install.sh
# writes this file; it must exist before the first worker dispatch.
NO_ADVISOR_CFG="$AUTODREAM_DIR/l1-no-advisor.yml"

# ---- Config file ----
# run.sh historically ignored ~/.claude/autodream/config; only review.sh sourced it. That
# was fine while every key it held was review-only, and stopped being fine the moment a
# key had to reach the nightly run (AUTODREAM_VAULT_DIR). Sourced here, after AUTODREAM_DIR
# is resolved — so AUTODREAM_DIR itself must come from the environment, not the config.
#
# The env-wins dance matters: the config uses plain `KEY=value`, so a bare `.` would let
# the file clobber a variable the caller deliberately exported (tests set env, and a run
# invoked as `AUTODREAM_VAULT_DIR= run.sh` to disable the vault must actually disable it).
# Snapshot the exported environment, source, then replay the snapshot: names the caller
# set win, names only the config sets survive.
#
# `set -a` around the source is the other half: the helper scripts below are separate
# processes, so a config key that stays an unexported shell variable reaches nothing.
#
# This whole script runs under `set -u` (top of file), and sourcing a user-edited file
# under nounset means ANY unbound reference in it (e.g. a typo'd
# X_CREDS_FILE=$AUTODREAM_HOME/x-credentials, meaning AUTODREAM_DIR) aborts the shell
# outright — before LOG_DIR or the log() function exist, so nothing reaches the run log
# and no report is produced. The `|| echo WARNING ...` below can't catch that: nounset
# kills the shell rather than making `.` return non-zero. run.sh never sourced this file
# before the vault-notes feature, so a typo that used to be harmless now silently costs
# a night. Two passes fix it without losing the config-key-name diagnostic:
#   1. A throwaway subshell probe sources the config under the SAME `set -u` this
#      script runs under, purely so bash's own error message (which names the exact
#      unbound variable) can be surfaced as a WARNING. A subshell dying from `set -u`
#      does not kill this shell, and nothing it does touches real state.
#   2. The real source runs with nounset OFF, so a bad reference can't abort us — it
#      degrades to an empty expansion for that one reference, and every other key
#      (before or after the bad line) still gets set and exported normally.
AUTODREAM_CONFIG="${AUTODREAM_CONFIG:-$AUTODREAM_DIR/config}"
if [ -f "$AUTODREAM_CONFIG" ]; then
  _env_snapshot=$(export -p)

  # shellcheck disable=SC1090
  _config_probe_err=$(set -a; set -u; . "$AUTODREAM_CONFIG" 2>&1 1>/dev/null)
  if [ -n "$_config_probe_err" ]; then
    echo "WARNING: $AUTODREAM_CONFIG has an unbound variable reference (continuing without it): $_config_probe_err" >&2
  fi

  set +u
  set -a
  # shellcheck disable=SC1090
  . "$AUTODREAM_CONFIG" || echo "WARNING: failed to source $AUTODREAM_CONFIG (continuing)" >&2
  set +a
  set -u
  eval "$_env_snapshot"
  unset _env_snapshot _config_probe_err
fi
# Source $AUTODREAM_DIR/x-credentials (chmod 600, key=value lines) when it exists, so a
# provider key written there reaches the workers. Nounset is off around it so a
# user-edited file can never abort the run.
#
# This block used to claim the login keychain as a fallback "when the file is absent or
# lacks the key". No code implements that, here or anywhere else in the repo — the file
# is sourced and that is all. A key that lives only in the keychain reaches the workers
# unset, and the run says nothing about it. Left unimplemented deliberately rather than
# written: nothing in the default path needs a provider key (both layers use agent.db
# OAuth), and a `security find-generic-password` call at 03:15 prompts against a locked
# keychain, which is the failure this was supposed to avoid. If a runinfra model is ever
# made the default, implement the fallback and delete this paragraph.
if [ -f "$AUTODREAM_DIR/x-credentials" ]; then
  set +u
  . "$AUTODREAM_DIR/x-credentials" 2>/dev/null || true
  set -u
fi
DREAMS_DIR="${DREAMS_DIR:-$(dirname "$AUTODREAM_DIR")/dreams}"
LOG_DIR="$AUTODREAM_DIR/logs"
FANOUT="${FANOUT:-8}"

# Bound every L1 worker. An omp worker that never exits holds its xargs -P slot
# forever, so FANOUT hung workers stop the whole run with no error and no report:
# 2026-08-19 and 2026-08-22 each sat wedged for days with all 8 slots taken by
# workers blocked on their own node_repl and mnemopi_embed children.
#
# GNU timeout, invoked without --foreground, runs the command in a new process
# group and signals the group, so it reaps those grandchildren. A bare kill on
# the omp process would leave them reparented (to launchd on macOS) and running.
# macOS ships no timeout in its base install, so this degrades to unbounded rather
# than becoming a hard coreutils dependency; run-stats records which way it went.
# TIMEOUT_BIN itself is resolved further down, after the PATH augmentation.
AUTODREAM_L1_TIMEOUT="${AUTODREAM_L1_TIMEOUT:-1200}"
# GNU timeout treats a duration of 0 as "no timeout", so an unvalidated 0 restores
# the exact hang this bounds while the startup log still reports a timeout is set.
# A non-numeric value is worse: timeout rejects it and every worker fails. Refuse
# both at startup rather than discovering it at 03:15.
case "$AUTODREAM_L1_TIMEOUT" in
  ''|*[!0-9]*) echo "FATAL: AUTODREAM_L1_TIMEOUT must be a positive integer (got '$AUTODREAM_L1_TIMEOUT')" >&2; exit 1 ;;
  *) [ "$AUTODREAM_L1_TIMEOUT" -gt 0 ] || { echo "FATAL: AUTODREAM_L1_TIMEOUT must be greater than 0 (0 disables the timeout entirely)" >&2; exit 1; } ;;
esac
# The warmup runs before every recovery path (see "auth warmup" below), so an unbounded
# warmup wedges the run. Same two failure modes as the L1 timeout: 0 means no deadline
# under GNU timeout, and a non-numeric value fails the call. Refuse both here.
AUTODREAM_L1_WARMUP_TIMEOUT="${AUTODREAM_L1_WARMUP_TIMEOUT:-120}"
case "$AUTODREAM_L1_WARMUP_TIMEOUT" in
  ''|*[!0-9]*) echo "FATAL: AUTODREAM_L1_WARMUP_TIMEOUT must be a positive integer (got '$AUTODREAM_L1_WARMUP_TIMEOUT')" >&2; exit 1 ;;
  *) [ "$AUTODREAM_L1_WARMUP_TIMEOUT" -gt 0 ] || { echo "FATAL: AUTODREAM_L1_WARMUP_TIMEOUT must be greater than 0 (0 disables the warmup deadline entirely)" >&2; exit 1; } ;;
esac
# SIGKILL grace after the SIGTERM. The worst-case bound is therefore
# AUTODREAM_L1_TIMEOUT + L1_KILL_GRACE, not AUTODREAM_L1_TIMEOUT.
L1_KILL_GRACE=30

# Isolated cwd for every `claude --print` worker (see "AI-title stubs" below). The
# workers all read/write by ABSOLUTE path, so their cwd is functionally irrelevant —
# we point it at a dedicated dir purely to redirect Claude Code's session bucket.
# Claude maps the launch cwd to ~/.claude/projects/<cwd with / and . replaced by ->,
# so running from here lands any stray stub in an isolated bucket we own and wipe,
# instead of polluting the user's real -Users-<you> session history.
WORK_DIR="$AUTODREAM_DIR/work"
WORK_BUCKET="$PROJECTS_DIR/$(printf '%s' "$WORK_DIR" | sed 's#[/.]#-#g')"

TARGET_DATE="${1:-$(date -v-1d +%Y-%m-%d)}"
NEXT_DATE=$(date -j -f %Y-%m-%d -v+1d "$TARGET_DATE" +%Y-%m-%d)

FINDINGS_DIR="$AUTODREAM_DIR/findings/$TARGET_DATE"
REPORT_PATH="$DREAMS_DIR/$TARGET_DATE.md"
RUN_LOG="$LOG_DIR/run-$TARGET_DATE.log"
SESSIONS_LIST="$FINDINGS_DIR/sessions.txt"

# Self-session prune helper — single source of truth for "is this autodream's own
# transcript?". Resolve it next to this script first (works for the repo copy and the
# ~/.claude/autodream symlink), then fall back to the install dir.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRUNE="$SCRIPT_DIR/prune-self-sessions.sh"
[ -x "$PRUNE" ] || PRUNE="$AUTODREAM_DIR/prune-self-sessions.sh"
# Root prober — decides which $HOME/.claude*/projects dirs to scan (see root-probe.sh).
# AUTODREAM_ROOTPROBE_BIN overrides the resolved path (no existability fallback), so
# tests can point it at a stub and exercise the scan fallbacks deterministically.
if [ -n "${AUTODREAM_ROOTPROBE_BIN:-}" ]; then
  ROOT_PROBE="$AUTODREAM_ROOTPROBE_BIN"
else
  ROOT_PROBE="$SCRIPT_DIR/root-probe.sh"
  [ -x "$ROOT_PROBE" ] || ROOT_PROBE="$AUTODREAM_DIR/root-probe.sh"
fi
# Oversized-transcript slimmer (resolved the same way; exported to the L1 workers).
SLIM="$SCRIPT_DIR/slim-transcript.sh"
[ -x "$SLIM" ] || SLIM="$AUTODREAM_DIR/slim-transcript.sh"
# Deterministic session-stat pre-pass (resolved like the other helper scripts).
# AUTODREAM_STATS_BIN overrides the resolved path outright, with no existability
# fallback, for the same reason AUTODREAM_OVERLAP_BIN does below (#26): tests need to
# force a missing or deliberately broken sidecar generator, and the `[ -x ... ] ||`
# chain would rescue a nonexistent override back to the working repo copy (#27).
if [ -n "${AUTODREAM_STATS_BIN:-}" ]; then
  STATS="$AUTODREAM_STATS_BIN"
else
  STATS="$SCRIPT_DIR/session-stats.sh"
  [ -x "$STATS" ] || STATS="$AUTODREAM_DIR/session-stats.sh"
fi
# Global cross-session overlap pass (#14; resolved like the other helper scripts).
# AUTODREAM_OVERLAP_BIN overrides the resolved path outright (no fallback) so tests can
# point it at a nonexistent or stubbed binary and exercise compute_overlap_stats' "not
# measured" paths deterministically — the normal `[ -x ... ] ||` fallback chain would
# otherwise rescue a nonexistent override back to the working repo copy and defeat the
# whole point of the override (#26).
if [ -n "${AUTODREAM_OVERLAP_BIN:-}" ]; then
  OVERLAP="$AUTODREAM_OVERLAP_BIN"
else
  OVERLAP="$SCRIPT_DIR/overlap-stats.sh"
  [ -x "$OVERLAP" ] || OVERLAP="$AUTODREAM_DIR/overlap-stats.sh"
fi
# Operator-note collector and X-bookmark fetcher. Both are context-gatherers for L2 and
# both are opt-in: vault-notes.sh degrades to the plain notes.md when no vault is set,
# x-bookmarks.sh to a "not configured" stub when no credentials exist. Overrides are
# authoritative (no existability fallback) for the same reason as STATS/OVERLAP above —
# tests need to force the missing-helper path.
if [ -n "${AUTODREAM_VAULT_BIN:-}" ]; then
  VAULT_NOTES="$AUTODREAM_VAULT_BIN"
else
  VAULT_NOTES="$SCRIPT_DIR/vault-notes.sh"
  [ -x "$VAULT_NOTES" ] || VAULT_NOTES="$AUTODREAM_DIR/vault-notes.sh"
fi
if [ -n "${AUTODREAM_XBOOKMARKS_BIN:-}" ]; then
  XBOOKMARKS="$AUTODREAM_XBOOKMARKS_BIN"
else
  XBOOKMARKS="$SCRIPT_DIR/x-bookmarks.sh"
  [ -x "$XBOOKMARKS" ] || XBOOKMARKS="$AUTODREAM_DIR/x-bookmarks.sh"
fi

# Provenance of the code actually executing (#29), stamped into run-stats.txt below.
# Resolved by walking this script's own symlink chain rather than by reusing SCRIPT_DIR,
# which is a working directory and not a checkout. install.sh symlinks each script
# individually into ~/.claude/autodream, so that directory is real and has no .git, and
# `cd "$(dirname "$0")"` resolves symlinked *directories* but not a symlinked *file* —
# it lands in the install dir every time. Six of the eight runs through 2026-08-03 wrote
# `runner_commit: unknown` for that reason alone, which is the exact blind spot #29
# existed to close. The two that did stamp a sha were launched from the repo by hand.
# SCRIPT_DIR stays as it is: helper lookup genuinely wants the install dir.
# Everything degrades to "unknown"/"no": a tarball install with no git, or no git binary
# at all, is a supported way to run this and must not fail the run.
# --untracked-files=no on the dirty check: "dirty" is meant to warn that the run used code
# that exists in nobody's history, which only tracked modifications can cause. Counting
# untracked files made the first production run report runner_dirty: yes over a stray
# scratch directory, which is exactly the kind of false alarm that gets a signal ignored.
RUNNER_SRC="${BASH_SOURCE[0]}"
runner_hops=0
# A symlink can point at another symlink, and a target can be relative to the link's own
# directory rather than to $PWD. The hop cap keeps a cycle from hanging the run.
# 8 rather than a bigger round number so the cap is reachable in a test: macOS refuses to
# execute anything behind 16+ links (ELOOP), so a cap at or above that could never fire on
# a script that got far enough to run this code, and an untestable guard is a guess. Linux
# allows 40, where it can genuinely fire. A real install is one hop.
while [ -L "$RUNNER_SRC" ] && [ "$runner_hops" -lt 8 ]; do
  runner_link_dir=$(cd "$(dirname "$RUNNER_SRC")" && pwd) || break
  RUNNER_SRC=$(readlink "$RUNNER_SRC") || break
  case $RUNNER_SRC in /*) ;; *) RUNNER_SRC="$runner_link_dir/$RUNNER_SRC" ;; esac
  runner_hops=$((runner_hops + 1))
done
# Still a symlink means the walk gave up (a cycle, or a chain past the cap) rather than
# arriving anywhere. Resolving the truncated path would stamp whatever checkout it happens
# to sit in, and a confidently wrong sha is worse than no sha at all — the whole point of
# #29 is that this field can be trusted when someone is chasing a bad night.
if [ -L "$RUNNER_SRC" ]; then
  RUNNER_REPO_DIR=""
else
  RUNNER_REPO_DIR=$(cd "$(dirname "$RUNNER_SRC")" && pwd) || RUNNER_REPO_DIR=""
fi
# The empty case has to short-circuit before git rather than lean on git to reject it:
# `git -C "" rev-parse HEAD` does NOT fail, it silently stays in $PWD and answers for
# whatever repo the caller happened to launch from. launchd starts this job from an
# unrelated cwd, so leaving that to git would stamp a stranger's sha and call it
# provenance.
if [ -z "$RUNNER_REPO_DIR" ]; then
  RUNNER_COMMIT=""
else
  RUNNER_COMMIT=$(git -C "$RUNNER_REPO_DIR" rev-parse --short HEAD 2>/dev/null) || RUNNER_COMMIT=""
fi
: "${RUNNER_COMMIT:=unknown}"
if [ "$RUNNER_COMMIT" = "unknown" ]; then
  RUNNER_DIRTY=no
elif [ -n "$(git -C "$RUNNER_REPO_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  RUNNER_DIRTY=yes
else
  RUNNER_DIRTY=no
fi

mkdir -p "$FINDINGS_DIR" "$DREAMS_DIR" "$LOG_DIR" "$WORK_DIR"

# The caller's PATH comes FIRST, with the known install prefixes appended as a
# floor. This line used to REPLACE PATH outright, which is what made "resolve omp
# the way the shell does" impossible no matter how the resolution below was
# written: whatever the caller had on PATH was discarded one line before
# `command -v` ran, so an interactive run and the nightly could disagree about
# which omp exists and neither could see the other's. Appending keeps the reason
# the replacement existed at all -- launchd hands the job a minimal PATH that has
# neither omp nor git -- while letting an explicit caller win, which is what the
# shell would do.
export PATH="${PATH:+$PATH:}$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Resolve omp the way the shell does: PATH first, then the known install prefixes.
# Hardcoding /opt/homebrew/bin here meant the nightly could run a DIFFERENT binary
# from the one `which omp` reports, with no sign anywhere that the two had drifted.
# On 2026-08-25 that was a real 17.3.7-vs-18.0.4 split that cost half of every L1
# round to provider 400s, and nothing in the log or run-stats said which omp ran.
# An explicit OMP_BIN still wins, for pinning a specific build.
OMP_CANDIDATES=(
  "$HOME/.local/bin/omp"
  "$HOME/.bun/bin/omp"
  /opt/homebrew/bin/omp
  /usr/local/bin/omp
)
if [ -z "${OMP_BIN:-}" ]; then
  OMP_BIN="$(command -v omp 2>/dev/null || true)"
fi
if [ -z "${OMP_BIN:-}" ]; then
  for _cand in "${OMP_CANDIDATES[@]}"; do
    [ -x "$_cand" ] && { OMP_BIN="$_cand"; break; }
  done
fi
OMP_BIN="${OMP_BIN:-omp}"
OMP_VERSION="$("$OMP_BIN" --version 2>/dev/null | head -1 | tr -d '\r')"
OMP_VERSION="${OMP_VERSION:-unknown}"

# Resolved AFTER the PATH augmentation above, like git and python3 are. Resolving
# it earlier meant a run started from a minimal PATH found no gtimeout and quietly
# degraded to unbounded, which is the one outcome this whole change exists to
# prevent. The degrade is still announced, but it should not happen by accident.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
cd "$HOME" || exit 1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Wipe the isolated worker bucket. Claude Code's async AI-title generation writes a
# one-line `{"type":"ai-title",...}` stub into the launch cwd's session bucket even
# under --no-session-persistence (that flag only suppresses the full transcript). By
# running workers from $WORK_DIR those stubs land in $WORK_BUCKET, which we empty
# before and after every run so they never accumulate in the user's session history.
clean_work_bucket() { rm -rf "$WORK_BUCKET" 2>/dev/null || true; }

# ---- Session-root selection ----
# autodream scans one or more $HOME/.claude*/projects dirs. Resolution order:
#   1. SESSION_ROOTS (colon-separated, set by env/config) — authoritative.
#   2. PROJECTS_DIR — but ONLY when the caller explicitly set it (its default is applied
#      anyway at startup, so an explicit-set flag is what distinguishes a deliberate
#      single-root choice from an unset variable). Kept for backward compatibility.
#   3. Neither: autodetect every $HOME/.claude*/projects that exists, primary
#      ($HOME/.claude/projects) first, via root-probe.sh. If the probe is missing or
#      fails, fall back to the primary dir alone rather than scanning nothing.
# WORK_BUCKET stays keyed off the PRIMARY dir: the lean workers run under the default
# config, so their AI-title stubs land in the default bucket, which the isolation +
# clean_work_bucket above is built around. Scanning extra roots does not change that.
probe_roots() {
  SESSION_ROOTS="${SESSION_ROOTS:-}"
  if [ -z "$SESSION_ROOTS" ] && [ "$PROJECTS_DIR_EXPLICIT" = "1" ]; then
    SESSION_ROOTS="$PROJECTS_DIR"
  fi
  if [ -n "$SESSION_ROOTS" ]; then
    log "session roots: ${SESSION_ROOTS//:/, }"
    return 0
  fi
  if [ -x "$ROOT_PROBE" ]; then
    # Scan the decided roots only: primary + the ones root-choices.conf says index.
    # An unasked root is held out of the report until the user decides on it — that is
    # the point of the flag file (write_unindexed_flag) the report reads: "found a
    # folder we're not indexing." Scanning an undecided folder would make that flag a
    # lie. Folders the user explicitly ignored are likewise skipped.
    SESSION_ROOTS=$("$ROOT_PROBE" --consolidated 2>/dev/null) || SESSION_ROOTS=""
  fi
  [ -n "$SESSION_ROOTS" ] || SESSION_ROOTS="$HOME/.omp/agent/sessions"
  log "session roots: ${SESSION_ROOTS//:/, }"
}

# Which roots exist but are NOT indexed — written to a flag file so the morning report
# can tell the human a Claude folder appeared that setup never asked about. Never a
# prompt in the unattended run; the report is the surface.
write_unindexed_flag() {
  local flag="$FINDINGS_DIR/unindexed-roots.txt"
  : > "$flag"
  [ -x "$ROOT_PROBE" ] || { printf 'root-probe.sh not found; cannot detect unindexed claude folders\n' > "$flag"; return 0; }
  "$ROOT_PROBE" --unindexed 2>/dev/null >> "$flag" || true
  [ -s "$flag" ] || printf '(none — every $HOME/.claude*/projects dir is indexed)\n' > "$flag"
}

# Find sessions modified during the target day across every session root.
scan_roots() {
  : > "$SESSIONS_LIST.raw"
  local -a roots
  IFS=: read -ra roots <<< "$SESSION_ROOTS"
  local r
  for r in "${roots[@]}"; do
    [ -n "$r" ] || continue
    # SESSION_ROOTS is colon-separated, so a root path containing ':' is unrepresentable:
    # the split above already fragmented it. Catch the symptom — a fragment that is not
    # a directory (or that was split out of one) — and say why it's being skipped rather
    # than silently scanning nothing.
    if [ ! -d "$r" ]; then
      log "WARNING: session root is not a directory (possible ':' in path — SESSION_ROOTS is colon-separated): $r"
      continue
    fi
    find "$r" -type f -name '*.jsonl' \
         -newermt "$TARGET_DATE 00:00:00" \
         ! -newermt "$NEXT_DATE 00:00:00" \
         2>/dev/null >> "$SESSIONS_LIST.raw"
  done
  # A transcript reachable from two roots (e.g. one dir is a symlink of another) must
  # be triaged exactly once.
  sort -u "$SESSIONS_LIST.raw" -o "$SESSIONS_LIST.raw"
  RAW=$(wc -l < "$SESSIONS_LIST.raw" | tr -d ' ')
}

# ---- Empty-session filter: drop 0-turn shells before fanout ----
# Most of a quiet night's corpus is auto-opened/aborted sessions that hold no user
# input (observed: ~150 of 163 files on 2026-05-30 were single-line `ai-title` shells).
# They cost an L1 worker each for zero signal. A session is SUBSTANTIVE iff it has at
# least one `user` turn that isn't `isMeta:true`; everything else is skippable. The
# predicate is deliberately conservative — any user turn keeps the session, and a jq
# parse failure keeps it too (bias to triage, never silently drop a real session).
# Reads a session-list file on stdin, prints the substantive subset.
# Disable with AUTODREAM_SKIP_EMPTY=0.
filter_empty_sessions() {
  while IFS= read -r sp; do
    [ -n "$sp" ] || continue
    if session_is_substantive "$sp"; then
      printf '%s\n' "$sp"
    fi
  done
}

# exit 0 = keep (substantive or unparseable), 1 = skip (provably a 0-turn shell).
session_is_substantive() {
  local sp="$1" verdict
  [ -r "$sp" ] || return 0
  # OMP transcript shape (PORT_CONTRACT.md): a substantive session has at least one
  # `message` record with role user holding a text content item. UI-only
  # custom_message records never count. Unparseable files are kept (bias to triage).
  verdict=$(jq -s 'if any(.[]; (.type=="message") and (.message.role=="user") and ([.message.content[]? | select(.type=="text")] | length > 0)) then 1 else 0 end' "$sp" 2>/dev/null) || return 0
  [ "$verdict" = "0" ] && return 1
  return 0
}

# ---- Upstream changelog: detect Claude Code releases committed on the target day ----
# Clones (once) and pulls anthropics/claude-code into a persistent cache, then diffs
# CHANGELOG.md over [TARGET_DATE, NEXT_DATE) by real commit date and writes the inserted
# entries into the findings dir for Layer 2 to read. There is no remote `git blame`/`log`,
# so we keep a persistent local cache (not a tmpdir): nightly cost is one delta `git pull`.
# git is the only dependency. Any failure is recorded in the output file, never aborts the
# pipeline. Window matches the session scan exactly, so each release is reported once.
# Disable with AUTODREAM_CHANGELOG=0; point CHANGELOG_REMOTE at a local repo for offline tests.
#
# Three harnesses are watched, not one: the user works across Claude Code, Codex and OMP,
# and a release note only earns its place in the report when it lands in a tool actually
# in use. OMP keeps no root CHANGELOG — it is a monorepo and the CLI's log lives at
# packages/coding-agent/CHANGELOG.md — so the path is per-source rather than assumed.
#
# One source's failure never silences the others: each gets its own cache, its own
# clone/pull and its own section, and a dead remote writes an explicit failure line into
# that section rather than an empty file that reads like a quiet night upstream.
changelog_sources() {
  # An explicit CHANGELOG_REMOTE selects a SINGLE source and suppresses the defaults.
  # Back-compat for the old one-repo knob, and load-bearing for the test suite: the
  # changelog test points this at a local fixture, and a default list that still ran
  # would have the suite cloning three real remotes — the promise that it never touches
  # the network, broken silently.
  if [ -n "${CHANGELOG_REMOTE:-}" ]; then
    printf '%s|%s|%s|%s\n' "Claude Code" "$CHANGELOG_REMOTE" "CHANGELOG.md" \
      "${CLAUDE_CODE_REPO:-$AUTODREAM_DIR/cache/claude-code}"
    return 0
  fi
  if [ -n "${AUTODREAM_CHANGELOG_SOURCES:-}" ]; then
    printf '%s\n' "$AUTODREAM_CHANGELOG_SOURCES" | tr ';' '\n' | sed '/^[[:space:]]*$/d'
    return 0
  fi
  printf '%s|%s|%s|%s\n' \
    "Claude Code" "https://github.com/anthropics/claude-code.git" "CHANGELOG.md" "${CLAUDE_CODE_REPO:-$AUTODREAM_DIR/cache/claude-code}"
  printf '%s|%s|%s|%s\n' \
    "Codex" "https://github.com/openai/codex.git" "CHANGELOG.md" "$AUTODREAM_DIR/cache/codex"
  printf '%s|%s|%s|%s\n' \
    "OMP" "https://github.com/STRML/oh-my-pi.git" "packages/coding-agent/CHANGELOG.md" "$AUTODREAM_DIR/cache/oh-my-pi"
}

# True only when $1's parent directory resolves, symlinks and all, inside $AUTODREAM_DIR/cache.
# A `..` anywhere is refused before resolving, so the basename cannot climb out either.
cache_owns() {
  local cache parent
  case "$1" in *..*) return 1 ;; esac
  cache=$(cd "$AUTODREAM_DIR/cache" 2>/dev/null && pwd -P) || return 1
  parent=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  case "$parent/" in "$cache"/*) return 0 ;; esac
  return 1
}

# Append one source's section to $5. Never returns non-zero — a source that cannot be
# reached says so in its own section and the run carries on.
#
# The section goes to a named file rather than stdout, and that is not a style choice:
# log() writes to stdout, so a stdout-emitting version run inside a `{ … } > "$out"`
# block silently interleaves every "cloning …" progress line into the changelog L2 then
# reads as release notes. Caught in a live run against all three remotes.
changelog_one() { # $1=name $2=remote $3=path $4=repo $5=out
  local name="$1" remote="$2" path="$3" repo="$4" out="$5"
  local head_sha n added

  if [ -d "$repo/.git" ]; then
    if ! ( cd "$repo" && git pull --ff-only --quiet ) 2>>"$RUN_LOG"; then
      log "changelog[$name]: pull failed"
      printf '## %s\n\nGit pull failed; %s changes not checked this run.\n\n' "$name" "$name" >> "$out"
      return 0
    fi
  else
    # Only a cache this install owns may be cleared. AUTODREAM_CHANGELOG_SOURCES names the
    # path, so a typo pointing at a real non-git directory must not be deleted to make room
    # for a clone (debate review of e95e2f2).
    # The path as written proves nothing: `$AUTODREAM_DIR/cache/../x` matches the prefix,
    # and so does `$AUTODREAM_DIR/cache/link/x` where link points elsewhere, and rm -rf
    # follows both (Codex review of 0129fc0). Resolve the parent physically and compare
    # that. Outside the cache nothing is deleted at all; git clone accepts a missing or
    # empty target directory.
    if cache_owns "$repo"; then rm -rf "$repo"; fi
    if [ -e "$repo" ] && [ -n "$(ls -A "$repo" 2>/dev/null)" ]; then
      log "changelog[$name]: $repo exists, is not a git repo and is outside $AUTODREAM_DIR/cache; refusing to delete it"
      printf '## %s\n\nCache path %s is a non-empty directory that is not a git clone; %s changes not checked this run.\n\n' "$name" "$repo" "$name" >> "$out"
      return 0
    fi
    log "changelog[$name]: cloning $remote -> $repo..."
    # blob:none + sparse keeps a monorepo clone cheap — oh-my-pi carries Cargo, bazel and
    # a node_modules tree, and we want one markdown file out of it. Blobs for the path we
    # actually log are fetched on demand. Real remotes only: git ignores --filter on a
    # local clone, and the suite's offline fixture must behave the same either way.
    local cloneargs=()
    case "$remote" in
      *://*|*@*:*) cloneargs=(--filter=blob:none --sparse) ;;
    esac
    if ! git clone --quiet "${cloneargs[@]+"${cloneargs[@]}"}" "$remote" "$repo" 2>>"$RUN_LOG"; then
      log "changelog[$name]: clone failed"
      printf '## %s\n\nGit clone failed; %s changes not checked this run.\n\n' "$name" "$name" >> "$out"
      return 0
    fi
    if [ "${#cloneargs[@]}" -gt 0 ]; then
      ( cd "$repo" && git sparse-checkout set "$path" ) >/dev/null 2>>"$RUN_LOG" || true
    fi
  fi

  head_sha=$( cd "$repo" && git rev-parse --short HEAD 2>/dev/null ) || head_sha="?"
  n=$( cd "$repo" && git log --format=%H \
         --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
         -- "$path" 2>/dev/null | wc -l | tr -d ' ' )
  # Inserted changelog lines (new version headers + bullets), oldest-first; strip the
  # diff's leading '+' but drop the '+++ b/<path>' file header.
  # Dedupe non-blank lines, keep every blank. A changelog edited across many commits in one
  # window re-inserts the same lines repeatedly: OMP's log moved 119 commits for 2026-09-08
  # through 09-10 and emitted `## [18.1.16]` three times with its bullets under each. Blank
  # lines are exempt or the markdown collapses into one paragraph.
  added=$( cd "$repo" && git log -p --reverse \
             --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
             -- "$path" 2>/dev/null \
           | grep '^+' | grep -v '^+++' | sed 's/^+//' \
           | awk '!NF || !seen[$0]++' )
  # Cap per source. One chatty monorepo must not crowd the other harnesses out of L2's
  # context; the cap is per section, so a quiet source is never truncated for a loud one.
  local cap="${AUTODREAM_CHANGELOG_MAX_LINES:-400}" total
  # A non-numeric cap made the -gt test below error out as false under set -u without -e,
  # so the section went out uncapped (debate review of e95e2f2). Fall back to the default.
  # Compare numerically, not by pattern: "00" is all digits and still zero, and head -n 00
  # then fails and drops the section's content.
  local cap_ok=no
  case "$cap" in
    ''|*[!0-9]*) ;;
    *) [ "$cap" -gt 0 ] 2>/dev/null && cap_ok=yes ;;
  esac
  if [ "$cap_ok" = no ]; then
    log "changelog[$name]: AUTODREAM_CHANGELOG_MAX_LINES='$cap' is not a positive integer; using 400"
    cap=400
  fi
  total=$(printf '%s\n' "$added" | wc -l | tr -d ' ')
  if [ "${total:-0}" -gt "$cap" ]; then
    added=$(printf '%s\n' "$added" | head -n "$cap")
    added="$added
[...truncated: $total lines in window, showing first $cap. Raise AUTODREAM_CHANGELOG_MAX_LINES to see the rest.]"
    log "changelog[$name]: $total lines truncated to $cap"
  fi

  if [ "${n:-0}" -gt 0 ] && [ -n "$added" ]; then
    printf '## %s\n# Source: %s @ %s (%s)\n# Commits touching the changelog in window: %s\n\n%s\n\n' \
      "$name" "$remote" "$head_sha" "$path" "$n" "$added" >> "$out"
    log "changelog[$name]: $n commit(s) in window"
  else
    printf '## %s\n# Source: %s @ %s (%s)\n\nNo changelog commits in this window.\n\n' \
      "$name" "$remote" "$head_sha" "$path" >> "$out"
    log "changelog[$name]: no commits in window"
  fi
}

changelog_window() {
  local out="$FINDINGS_DIR/changelog-window.md"
  [ "${AUTODREAM_CHANGELOG:-1}" != "0" ] || { log "changelog check disabled (AUTODREAM_CHANGELOG=0)"; return 0; }
  command -v git >/dev/null 2>&1 || { log "changelog: git not found; skipping"; return 0; }

  local srcs; srcs=$(changelog_sources)
  # Truncate once here, then every section appends. Nothing in this function may wrap the
  # loop in a `> "$out"` block: log() writes to stdout, so that would file the runner's
  # own progress lines as upstream release notes.
  printf '# Harness changelogs — commits in [%s, %s)\n\n' "$TARGET_DATE" "$NEXT_DATE" > "$out"
  local name remote path repo
  # Here-string rather than a pipe: a piped while-read runs in a subshell, which is a trap
  # the moment this loop needs to set a variable the caller reads.
  while IFS='|' read -r name remote path repo; do
    [ -n "$name" ] || continue
    changelog_one "$name" "$remote" "$path" "$repo" "$out"
  done <<< "$srcs"
  log "changelog: window written -> $out"
}

# ---- Sleep/network resilience helpers ----
# A laptop that sleeps mid-run loses the network and whole batches of workers fail
# (this is the common overnight failure: started on a brief wake, slept through the
# run, ~half the workers errored, L2 produced no report). The L1 worker is already
# idempotent — a session with a findings JSON is skipped — so we can just re-dispatch
# the still-missing sessions across wake/sleep cycles until they all land, and retry
# L2 until a report exists. Tunable; network-wait/sleep are disabled in tests.

# A report is COMPLETE when it carries the end-of-document marker PROMPT.md mandates, not
# merely when its path is non-empty. `-s` cannot tell a finished report from one the
# aggregator was killed halfway through writing, and a truncated report satisfies `-s`
# exactly as well as a good one. That mattered three separate ways: the L2 retry loop
# would break after attempt 1 on a partial file, the superseded good copy would be
# deleted, and the consume gate would archive the user's notes and stamp bookmarks read
# against a half-written report. Mid-write death is precisely the sleep-kill scenario all
# of this exists for, so "non-empty" was never the right test. The marker is the last
# thing PROMPT.md emits, which is what makes its presence mean the write reached the end.
#
# Deliberately not `L2_RC -eq 0`: the CLI can exit non-zero after a perfectly good write.
report_complete() {
  [ -s "$REPORT_PATH" ] && grep -q 'autodream:open-questions=' "$REPORT_PATH" 2>/dev/null
}

net_up() { # exit 0 if the API host is reachable (any HTTP code beats "000" = no route)
  local code rc
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null); rc=$?
  # 127 is "not found" and 126 is "found but not executable". Both mean the shell could
  # not run curl at all — absent, not executable.
  # That is "the check cannot answer", not "the host is down", and reading it as down
  # made a machine without curl wait out the full cap and defer a healthy run, every
  # run, for a reason nothing reported. Bias to up: a wrong "up" costs one round of
  # workers, a wrong "down" costs the whole date. Checking the exit status rather than
  # `command -v` also covers a curl that is present but unrunnable.
  { [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; } && return 0
  [ -n "$code" ] && [ "$code" != "000" ]
}

# Seconds this run spent blocked on wait_for_network, summed across rounds. Reported in
# run-stats.txt so the self-audit can tell an outage from a transcript problem — on
# 2026-09-04 it could not, and blamed 90 minutes of dead network on oversized transcripts.
NET_DOWN_SECONDS=0

wait_for_network() { # 0 = network is up, 1 = gave up after the cap; no-op when AUTODREAM_NETCHECK=0
  [ "${AUTODREAM_NETCHECK:-1}" != "0" ] || return 0
  local waited=0 step cap="${AUTODREAM_NETCHECK_CAP:-1800}"
  # A non-numeric cap makes every [ "$waited" -ge "$cap" ] test error out, and an erroring
  # test reads as false — so the give-up branch became unreachable and the bound that was
  # supposed to limit the wait removed it instead.
  case "$cap" in ''|*[!0-9]*) log "AUTODREAM_NETCHECK_CAP='$cap' is not a number; using 1800"; cap=1800 ;; esac
  while ! net_up; do
    if [ "$waited" -ge "$cap" ]; then
      NET_DOWN_SECONDS=$((NET_DOWN_SECONDS + waited))
      log "network still down after ~${waited}s of checks (cap ${cap}s)"
      # Was `return 0` — "proceeding anyway". Proceeding meant dispatching a full round
      # of workers at a host with no route, which fails every one of them in ~9s and
      # burns a retry round to learn nothing. The caller now defers the date instead.
      return 1
    fi
    log "waiting for network to return... (${waited}s)"
    # Never sleep past the cap. A fixed 15s step meant any cap below 15 still waited a
    # full 15 seconds, so the wait overran the bound it was handed and reported a
    # network_down_seconds larger than the configured maximum.
    step=$(( cap - waited )); [ "$step" -gt 15 ] && step=15
    sleep "$step"; waited=$(( waited + step ))
  done
  NET_DOWN_SECONDS=$((NET_DOWN_SECONDS + waited))
  return 0
}

l1_missing_count() { # count sessions in $SESSIONS_LIST that still have no findings JSON
  local m=0 s h
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    h=$(printf "%s" "$s" | shasum -a 1 | cut -c1-12)
    # Same check the dispatcher applies on the way out. `jq -e .findings` is truthy for
    # a STRING or an OBJECT, so {"findings":"oops"} counted as a finished session here and
    # reached L2 as a result instead of being retried. `arrays` emits nothing for a
    # non-array, so jq -e exits non-zero. Written this way rather than as
    # `(.findings | type) == "array"` because the dispatcher copy lives inside a
    # single-quoted `bash -c` body where a single quote silently breaks the quoting, and
    # two checks that must agree should be readable as the same check.
    jq -e ".findings | arrays" "$FINDINGS_DIR/$h.json" >/dev/null 2>&1 || m=$((m + 1))
  done < "$SESSIONS_LIST"
  printf '%s' "$m"
}

findings_json_count() {
  find "$FINDINGS_DIR" -type f -name '*.json' ! -name '*.stats.json' 2>/dev/null \
    | wc -l | tr -d ' '
}

compute_session_stats() {
  local session hash stats
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    hash=$(printf "%s" "$session" | shasum -a 1 | cut -c1-12)
    stats="$FINDINGS_DIR/$hash.stats.json"
    rm -f "$stats"
    if [ -x "$STATS" ] && "$STATS" "$session" "$stats" >/dev/null 2>&1 \
      && [ -s "$stats" ] && jq -e 'type == "object"' "$stats" >/dev/null 2>&1; then
      echo "stats: $session ($hash)" >&2
    else
      rm -f "$stats"
      echo "stats failed: $session ($hash); continuing without precomputed stats" >&2
    fi
  done < "$SESSIONS_LIST"
}

# ---- Global overlap pass (#14): cross-session "multi-clauding" stat ----
# Runs once compute_session_stats has written every session's *.stats.json sidecar
# (each carries the mechanical user_turn_timestamps array). Overlap is a GLOBAL,
# cross-session computation — it can't be done per-session inside compute_session_stats
# or dispatch_l1's xargs subshells, which only ever see one session at a time. Sets
# OVERLAP_EVENTS / SESSIONS_WITH_OVERLAP (default "0"/"0" on any failure/absence so the
# run-stats.txt writer always has a value, never aborts the pipeline) AND OVERLAP_MEASURED,
# a tri-state marker (#26) so a genuine zero-overlap night can't be confused with a
# non-measurement:
#   1 = a real measurement happened (overlap-stats.sh ran and produced parseable output,
#       even if the answer is 0 pairs / 0 sessions — that is a legitimate result)
#   0 = no measurement happened: the script was missing/not executable, produced no
#       output, or produced output jq couldn't extract both fields from. Each of these
#       gets its own explicit "not measured" log line so a non-measurement is never
#       silently reported as the same "overlap: 0 pair(s)" line as a real zero.
compute_overlap_stats() {
  OVERLAP_EVENTS=0
  SESSIONS_WITH_OVERLAP=0
  OVERLAP_MEASURED=0
  if [ ! -x "$OVERLAP" ]; then
    log "overlap not measured: overlap-stats.sh not found/executable (counts left at 0/0)"
    return 0
  fi
  local json events involved
  json=$("$OVERLAP" "$FINDINGS_DIR" 2>>"$RUN_LOG")
  if [ -z "$json" ]; then
    log "overlap not measured: overlap-stats.sh produced no output (counts left at 0/0)"
    return 0
  fi
  events=$(printf '%s' "$json" | jq -r '.overlap_events // empty' 2>/dev/null)
  involved=$(printf '%s' "$json" | jq -r '.sessions_with_overlap // empty' 2>/dev/null)
  if [ -z "$events" ] || [ -z "$involved" ]; then
    log "overlap not measured: overlap-stats.sh output was unparseable (counts left at 0/0)"
    return 0
  fi
  OVERLAP_EVENTS="$events"
  SESSIONS_WITH_OVERLAP="$involved"
  OVERLAP_MEASURED=1
  log "overlap: $OVERLAP_EVENTS pair(s), $SESSIONS_WITH_OVERLAP session(s) involved"
}

dispatch_l1() { # one parallel pass; idempotent worker → only the still-missing sessions run
  < "$SESSIONS_LIST" xargs -P "$FANOUT" -I {} bash -c '
    session="$1"
    hash=$(printf "%s" "$session" | shasum -a 1 | cut -c1-12)
    t0=$(date +%s)
    output="$FINDINGS_DIR/$hash.json"
    errlog="$output.err"
    # The worker printed its whole diagnosis to stdout and this used to be /dev/null, so
    # every failure looked the same: an .err holding the single line "Working..." and a
    # hand-written sentence from the runner. On 2026-09-04 that hid a dead network behind
    # three transcripts that were fine, and the report blamed their size. Kept only when
    # the worker fails; deleted with the errlog on success.
    outlog="$output.out"

    # Idempotent, but validate: a non-empty file that is malformed, lacks a top-level
    # findings key, or carries one of the wrong TYPE is NOT a completed triage. Treat it
    # as missing so this pass re-dispatches it, rather than letting it count as done and
    # feed broken records to L2.
    #
    # The three sites that answer "is this a finished triage" must agree, or a file can
    # be done to one and missing to another and never get rewritten by anyone:
    # here (dispatcher, inbound), l1_missing_count (parent), and the outbound check after
    # the worker exits. A partial fix left this site on `jq -e .findings`, which is truthy
    # for a string or an object, so a stale {"findings":"oops"} was skipped on every
    # retry while the parent counted it missing, and L2 aggregated it anyway.
    jq -e ".findings | arrays" "$output" >/dev/null 2>&1 && exit 0

    # Validate the session is readable BEFORE spawning a worker. A path that find
    # enumerated but that is gone/unreadable by dispatch time otherwise sends the
    # worker into a cat/wc/Read retry loop. Emit a structured error record instead;
    # this is deterministic, so leaving it in $output (idempotent-skipped on re-run)
    # is correct — retrying would not help.
    if [ ! -r "$session" ]; then
      printf "{\"session_path\":\"%s\",\"error\":\"session file not readable at dispatch\",\"findings\":[]}\n" "$session" > "$output"
      rm -f "$errlog"
      echo "skip (unreadable): $session ($hash)" >&2
      exit 0
    fi

    # ---- Noise gate: skip the L1 model call for low-signal sessions ----
    # Uses the mechanical stats sidecar (session-stats.sh, computed once during
    # enumeration) so gating never needs a model call of its own. Subagent
    # transcripts (isSidechain) and high tool-count sessions are never gated;
    # they are legitimate work, just often short on user turns (see CLAUDE.md).
    # An uncomputable duration (0, meaning zero or one timestamped line) never
    # gates on the duration rule alone; bias to triage when it cannot be
    # measured. A missing or unparseable stats sidecar also never gates; bias
    # to triage. Defaults: 2 user turns, 1 minute; either condition alone gates.
    statsfile="$FINDINGS_DIR/$hash.stats.json"
    if [ -s "$statsfile" ]; then
      gate=$(jq -r --argjson min_turns "${AUTODREAM_MIN_USER_TURNS:-2}" --argjson min_minutes "${AUTODREAM_MIN_MINUTES:-1}" "if (.isSidechain == true) or ((.tool_call_count // 0) >= 5) then 0 elif (.user_message_count // 0) < \$min_turns then 1 elif ((.duration_minutes // 0) > 0) and ((.duration_minutes // 0) < \$min_minutes) then 1 else 0 end" "$statsfile" 2>/dev/null)
      if [ "$gate" = "1" ]; then
        printf "{\"session_path\":\"%s\",\"skipped\":\"below_noise_gate\",\"findings\":[]}\n" "$session" > "$output"
        rm -f "$errlog"
        echo "gated (below noise threshold): $session ($hash)" >&2
        exit 0
      fi
    fi

    # Oversized transcripts (multi-MB, base64 images, giant tool outputs) blow the
    # worker token budget so it errors out instead of triaging. Slim those first and
    # point the worker at the reduced copy; small sessions are read verbatim. The
    # findings session_path is rewritten back to the original after a successful run.
    readpath="$session"
    slimfile=""
    sz=$(wc -c < "$session" | tr -d " ")
    if [ "${sz:-0}" -gt "${AUTODREAM_SLIM_BYTES:-262144}" ] && [ -x "$SLIM" ]; then
      slimfile="$FINDINGS_DIR/$hash.slim.jsonl"
      if "$SLIM" "$session" "$slimfile" 2>/dev/null && [ -s "$slimfile" ]; then
        readpath="$slimfile"
        echo "slimmed: $session ($sz bytes) ($hash)" >&2
      else
        rm -f "$slimfile"; slimfile=""
      fi
    fi

    # Pass the paths as LITERAL data (not KEY=value) so the worker hands them
    # straight to the Read/Write tools and never tries to $-expand them in a shell
    # (there is no such env var, so it would expand to nothing and fail — exactly
    # the failure mode that broke earlier runs). Assemble via a brace group piped
    # straight to the worker: a `prompt=$(...)` capture strips the trailing newlines,
    # which would glue the SESSION_TRIAGE.md body onto the end of the output-path
    # line and corrupt it. The printf keeps its blank-line separator this way.
    # Launch from the isolated worker cwd so any AI-title stub lands in $WORK_BUCKET,
    # not the real session bucket. All paths below are absolute, so cd is safe here.
    cd "$WORK_DIR" 2>/dev/null || true
    # An array rather than ${TIMEOUT_BIN:+...}: both behave correctly, including for
    # a path with spaces, but the array says plainly that this is an optional argv
    # prefix. Set OUTSIDE the brace group below — a brace group in a pipeline runs
    # in a subshell, so an assignment made in there is invisible to the right-hand
    # side and the wrapper would silently disappear.
    l1wrap=()
    [ -n "$TIMEOUT_BIN" ] && l1wrap=("$TIMEOUT_BIN" -k "$L1_KILL_GRACE" "$AUTODREAM_L1_TIMEOUT")
    # Stamped here, NOT reused from t0. t0 is taken before validation, the noise
    # gate and slimming, so a large transcript can burn real time before timeout
    # is even launched; counting that as worker runtime lets an intrinsic 124 or
    # 137 clear the elapsed check with no deadline having fired. Only the interval
    # timeout itself was running can answer that question.
    l1start=$(date +%s)
    {
      printf "Session transcript to analyze (literal absolute path): %s\n" "$readpath"
      printf "Write your findings JSON to this literal absolute path: %s\n\n" "$output"
      cat "$AUTODREAM_DIR/SESSION_TRIAGE.md"
      if [ -s "$FINDINGS_DIR/$hash.stats.json" ]; then
        printf "\n## Precomputed session stats (authoritative — copy these into your output)\n\n\`\`\`json\n"
        cat "$FINDINGS_DIR/$hash.stats.json"
        printf "\n\`\`\`\n"
      fi
    } | "${l1wrap[@]}" "$OMP_BIN" \
      --allow-home \
      -p \
      --approval-mode yolo \
      --no-session \
      --config "$NO_ADVISOR_CFG" \
      --model "${AUTODREAM_L1_MODEL:-deepseek/deepseek-flash}" \
      --tools=Read,Write \
      --append-system-prompt "Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never \$-expand them. Print only the literal word done and exit." \
      > "$outlog" 2> "$errlog"
    # Index 1 is the omp/timeout side of the pipe; index 0 is the brace group.
    # 124 is timeout reporting that it fired; 137 is 128+SIGKILL, which is what the
    # -k grace period escalates to. Only trust 137 as a timeout when the wrapper is
    # actually in the pipeline: with no timeout binary, an OOM-killed omp returns
    # 137 too, and calling that a timeout would be a lie the stats then repeat.
    l1rc="${PIPESTATUS[1]}"
    # Elapsed is the positive evidence that the deadline actually fired. The exit
    # code alone cannot say so: GNU timeout propagates the exit status of the child,
    # so a worker that exits 124 by itself, or that the OOM killer SIGKILLs at second
    # zero, arrives here looking identical to a real timeout. Verified against
    # coreutils 9.11 on this host — a self-killed child returned 137 after 0s
    # under a 100s bound. Without this, an OOM would be deleted, retried, and
    # counted as a timeout, which is the same class of lie this commit removes.
    # Second resolution leaves a one-second boundary window in which a child that
    # exits 124 or 137 by itself at exactly the deadline is read as a timeout.
    # /bin/bash here is 3.2, which has no EPOCHREALTIME, and the residual window
    # is one second wide against a bound of twenty minutes.
    l1elapsed=$(($(date +%s) - l1start))
    if [ -n "$TIMEOUT_BIN" ] && { [ "$l1rc" = "124" ] || [ "$l1rc" = "137" ]; } \
       && [ "$l1elapsed" -ge "$AUTODREAM_L1_TIMEOUT" ]; then
      printf "worker exceeded AUTODREAM_L1_TIMEOUT=%ss and was killed with its process group (rc=%s)\n" \
        "$AUTODREAM_L1_TIMEOUT" "$l1rc" >> "$errlog"
      # The errlog cannot carry this fact: it is truncated by the next retry and
      # deleted outright whenever the worker leaves any output, so a timeout that
      # later succeeds, or that wrote something before dying, would vanish from the
      # stats. The ledger is per-run and append-only, so neither can erase it.
      printf "%s\n" "$hash" >> "$FINDINGS_DIR/l1-timeouts.txt"
      # A worker killed mid-write leaves a truncated findings JSON. That is not a
      # result: kept, it reads as success, deletes the errlog, and feeds partial
      # input to L2. Drop it so this session retries like any other failure.
      rm -f "$output"
    fi

    # Non-empty is not the same as valid. A worker that writes malformed JSON, or JSON
    # with no .findings key, used to take the success branch below: both diagnostics were
    # deleted and the file was left for L2. The dispatcher validates .findings on its way
    # IN, so the next round would re-run the session — but by then the exit code, the
    # stdout capture and the omp log tail that explained the failure were already gone,
    # and on the final round the malformed file simply reached the aggregator. Validate
    # the same way on the way out, so a bad write is a failure with its evidence intact.
    if [ -s "$output" ] && ! jq -e ".findings | arrays" "$output" >/dev/null 2>&1; then
      printf "worker wrote output with no usable .findings key; treating as a failure\n" >> "$errlog"
      head -c 2000 "$output" >> "$errlog" 2>/dev/null
      rm -f "$output"
    fi

    if [ -s "$output" ]; then
      # Reported path should be the real session, not the temp slim copy. Then drop
      # the slim file (regenerable; keeps the findings dir clean).
      if [ -n "$slimfile" ]; then
        sed -i "" "s#$slimfile#$session#g" "$output" 2>/dev/null || true
        rm -f "$slimfile"
      fi
      rm -f "$errlog" "$outlog"
      echo "ok: $session ($hash) [$(($(date +%s) - t0))s]"
    else
      [ -n "$slimfile" ] && rm -f "$slimfile"
      # Worker exited without writing findings JSON. Record a diagnostic so the
      # failure is visible.
      printf "worker produced no findings JSON for %s (incomplete run: omp exited without writing output)\n" "$session" >> "$errlog"
      # The three facts that were missing every time this fired. Without the exit code
      # a provider refusal and a killed process read identically, and without the stdout
      # capture the entire diagnosis went to /dev/null while the .err kept the one line
      # the worker happened to put on stderr.
      printf "worker exit code: %s after %ss\n" "$l1rc" "$l1elapsed" >> "$errlog"
      if [ -s "$outlog" ]; then
        printf -- "--- worker stdout, last 40 lines ---\n" >> "$errlog"
        tail -n 40 "$outlog" >> "$errlog"
      else
        printf "worker stdout was empty\n" >> "$errlog"
      fi
      rm -f "$outlog"
      # omp keeps its own log, and for one whole class of death that log is the ONLY
      # trace. A worker killed during startup localhost provider discovery exits 0 with
      # empty stdout and nothing but "Working..." on stderr, so the exit code and stdout
      # captured just above say nothing at all. Its last line is "model discovery failed
      # for provider" where a healthy worker reaches "provider proxy resolved". Seen
      # 2026-09-06: 18 workers across three rounds, all of them.
      # Attribution is by mtime, not pid. The worker runs in a foreground pipeline so
      # there is no job id to read, and with FANOUT workers in parallel the newest log
      # may belong to a sibling. In this failure mode every worker dies the same way, so
      # a sibling log is still the right hint — the line says so rather than implying it
      # is certainly this one.
      # -newer against a reference file, not -newermt with an @epoch: the @ form is a GNU
      # findutils extension that BSD find rejects with "Can not parse date/time", and the
      # 2>/dev/null here would have swallowed that forever. Verified on this host: the
      # rewritten find in an interactive shell is bfs, which accepts @epoch, so an
      # interactive check agrees while the nightly quietly never fires.
      # find returns traversal order, not mtime order, so this is AN omp log touched
      # during this round, not the newest one. With FANOUT workers in parallel it may
      # belong to a sibling. Say that rather than sorting: in this failure mode every
      # worker dies the same way, so any of their logs answers the question, and a sort
      # would buy precision the label cannot honestly promise anyway.
      omplog=$(find "$HOME/.omp/logs" -maxdepth 1 -name "omp.*.log" -newer "$FINDINGS_DIR/l1-round.ref" 2>/dev/null | head -n 1)
      if [ -n "$omplog" ]; then
        printf -- "--- an omp log touched during this round, may belong to a sibling worker: %s ---\n" "$omplog" >> "$errlog"
        tail -n 20 "$omplog" >> "$errlog" 2>/dev/null
      fi
      # Was the host reachable at the moment this worker failed? Nothing recorded that,
      # so a failure caused by a sleeping Mac was indistinguishable from a transcript the
      # worker could not digest, and the oversized gate below counted it as evidence for
      # issue #12 that it is not. One curl, only on the failure path.
      # Three states, not two. An absent curl reports nothing and exits 127, which the
      # first version read as "no route" — so a host without curl would have had EVERY
      # worker failure excluded from the oversized gate, permanently and invisibly.
      # unknown is not netdown: it never ledgers and never suppresses the stub.
      netdown=unknown
      netcode=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://api.anthropic.com/ 2>/dev/null)
      netrc=$?
      if [ "$netrc" -eq 127 ] || [ "$netrc" -eq 126 ]; then
        printf "curl could not be run here (exit %s: not found, or not executable); this failure is unclassified, not an outage\n" "$netrc" >> "$errlog"
      elif [ -z "$netcode" ] || [ "$netcode" = "000" ]; then
        netdown=true
      else
        netdown=false
      fi
      if [ "$netdown" = "true" ]; then
        printf "no route to api.anthropic.com when this worker failed (curl http_code=%s)\n" "${netcode:-000}" >> "$errlog"
      fi
      # Ledger every classified failure, with its round, and never rewrite a line. A
      # bare hash was wrong: the ledger is truncated once per RUN, so a round-1 outage
      # entry survived into round 5 and excluded a round-5 failure that had a completely
      # different cause. Readers take the HIGHEST round recorded for a hash, so the last
      # attempt is the one that counts. Append-only keeps the parallel xargs subshells
      # from racing, same as l1-timeouts.txt.
      if [ "$netdown" != "unknown" ]; then
        printf "%s %s %s\n" "$hash" "${AUTODREAM_CURRENT_ROUND:-1}" "$netdown" >> "$FINDINGS_DIR/l1-netdown.txt"
      fi
      # On the FINAL retry round, fall back to a metadata-only findings stub so
      # the session is visible to L1_ERRORED and the L2 aggregator instead of
      # disappearing into a silent .err file (the old behavior, which the
      # 2026-06-11 self-audit flagged: 12 .err with l1_findings_with_error=0).
      # Earlier rounds leave $output absent so the next round can retry; only
      # the last round writes the stub. AUTODREAM_L1_ROUNDS comes through the
      # environment (exported below).
      #
      # EXCEPT when the network was down. A stub satisfies l1_missing_count (it carries
      # a .findings key, and jq -e counts an empty array as present), so writing one for
      # an outage marks the session DONE: MISSING drops to zero, the parent never defers,
      # L2 publishes a report on an outage-short corpus, and the next run skips the
      # session forever because its slot is filled. That is the exact 2026-09-04 failure
      # this change exists to stop, reintroduced one layer down. Leaving the slot empty
      # is what makes the retry work; the run defers instead of disappearing quietly, so
      # the 2026-06-11 silent-failure concern is answered by the deferral, not the stub.
      if [ "$netdown" = "true" ]; then
        echo "FAIL (network down; no stub, left for a later run): $session ($hash) [$(($(date +%s) - t0))s] — see $errlog" >&2
      elif [ "${AUTODREAM_CURRENT_ROUND:-1}" -ge "${AUTODREAM_L1_ROUNDS:-5}" ]; then
        sz=$(wc -c < "$session" 2>/dev/null | tr -d " ")
        lines=$(wc -l < "$session" 2>/dev/null | tr -d " ")
        # No network_down field here on purpose: this branch is unreachable when the
        # network was down, so the flag could only ever be written false. A field that
        # cannot vary is a field every reader has to check and no reader can learn from.
        printf "{\"session_path\":\"%s\",\"error\":\"worker exited without findings JSON after %s rounds\",\"meta\":{\"bytes\":%s,\"lines\":%s,\"slimmed\":%s},\"findings\":[]}\n" \
          "$session" "${AUTODREAM_L1_ROUNDS:-5}" "${sz:-0}" "${lines:-0}" "$([ -n "$slimfile" ] && echo true || echo false)" > "$output"
        echo "FAIL (metadata stub written): $session ($hash) [$(($(date +%s) - t0))s] — see $errlog" >&2
      else
        echo "FAIL: $session ($hash) [$(($(date +%s) - t0))s] — see $errlog" >&2
      fi
    fi
  ' _ {}
}

# Dates in the trailing window whose findings were produced but never assembled into a
# complete report (#36). Echoes a comma-separated list, empty when there are none.
#
# The completeness test is the open-questions marker, not `-s`, for the same reason every
# other consumer uses it: a report killed mid-write is not a report. TARGET_DATE is skipped
# because this run is about to assemble it, and a stub findings dir left by an earlier
# attempt at the same date would otherwise report itself as a failure.
unassembled_dates() {
  local window="${AUTODREAM_UNASSEMBLED_WINDOW:-7}" root="$AUTODREAM_DIR/findings"
  local d date_label report found out=""
  [ -d "$root" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    date_label=$(basename "$d")
    [ "$date_label" = "$TARGET_DATE" ] && continue
    # Findings JSONs only. A dir holding nothing but *.stats.json sidecars was never
    # triaged, so it has nothing to assemble and is not a failure.
    found=$(find "$d" -maxdepth 1 -type f -name '*.json' ! -name '*.stats.json' 2>/dev/null | head -1)
    [ -n "$found" ] || continue
    report="$DREAMS_DIR/$date_label.md"
    if [ -s "$report" ] && grep -q 'autodream:open-questions=' "$report" 2>/dev/null; then
      continue
    fi
    out="${out:+$out, }$date_label"
  done < <(find "$root" -maxdepth 1 -type d -name '2[0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]' 2>/dev/null \
    | sort | tail -n "$window")
  printf '%s' "$out"
}

run() {
  log "===== autodream start: $(date) ====="
  log "runner: $RUNNER_COMMIT$([ "$RUNNER_DIRTY" = "yes" ] && echo " (dirty)")"
  log "target date: $TARGET_DATE"
  log "findings:    $FINDINGS_DIR"
  log "report:      $REPORT_PATH"
  log "fanout:      $FANOUT"
  log "omp:         $OMP_BIN ($OMP_VERSION)"

  if [ ! -x "$OMP_BIN" ]; then
    log "FATAL: omp not found. Searched PATH and: ${OMP_CANDIDATES[*]}"
    log "       Set OMP_BIN to pin one explicitly."
    exit 1
  fi
  if [ -n "$TIMEOUT_BIN" ]; then
    log "l1 timeout:  $AUTODREAM_L1_TIMEOUT s via $TIMEOUT_BIN"
  else
    log "WARNING: no timeout binary found (brew install coreutils); L1 workers run unbounded and one hang stops the run"
  fi

  # ---- Session roots (which $HOME/.claude*/projects dirs we scan) ----
  probe_roots

  # Flag found-but-not-indexed Claude folders for the report (never a prompt here).
  # Written before the idempotency guard on purpose: a catch-up trigger that no-ops for
  # today should still report folders that appeared since setup.
  write_unindexed_flag

  # ---- Dates that were triaged but never assembled (#36) ----
  # A run killed during L2 leaves a full findings dir and no report, and nothing notices:
  # notify.sh never runs, so there is not even a quiet banner. 2026-07-26 sat that way for
  # two days and was found during an unrelated investigation; 2026-08-01 did it again.
  # The catch-up triggers cannot cover it — launchd will not start a second instance of a
  # label that is already running, so a run slow enough to span its own catch-up window
  # turns those triggers into nothing at all.
  #
  # Recovery is cheap whenever the findings survive (`autodream-now.sh <date>` skips
  # straight to L2), so the gap was never the data. It was that nobody was told. This says
  # so in the log and in run-stats.txt, which puts it in the next morning's report.
  UNASSEMBLED=$(unassembled_dates)
  if [ -n "$UNASSEMBLED" ]; then
    log "WARNING: these dates have findings but no complete report: $UNASSEMBLED"
    log "         rebuild one cheaply with: $AUTODREAM_DIR/autodream-now.sh <date>"
  fi

  # ---- Idempotency guard: a finished report means we're done ----
  # A report is only written after a successful L2, so its presence means the date is
  # complete. This makes launchd catch-up/relaunch (the sleep-resilience strategy:
  # multiple wake-time triggers) cheap no-ops once the night succeeded. A run that
  # failed overnight left NO report, so it correctly proceeds and finishes the work.
  if [ -s "$REPORT_PATH" ] && [ "${AUTODREAM_FORCE:-0}" != "1" ]; then
    log "report already exists for $TARGET_DATE ($REPORT_PATH); nothing to do (AUTODREAM_FORCE=1 to rebuild)"
    return 0
  fi

  # ---- Enumerate sessions modified during the target day ----
  log "scanning for sessions modified between $TARGET_DATE and $NEXT_DATE..."
  scan_roots

  # Exclude autodream's OWN headless worker/aggregator transcripts. New runs leave none
  # (--no-session), but runs predating that fix littered ~/.claude/projects/
  # and those files must not be re-triaged. The prune helper owns the predicate; if it's
  # missing, fall back to the raw list rather than silently dropping real sessions.
  if [ -x "$PRUNE" ]; then
    "$PRUNE" --filter < "$SESSIONS_LIST.raw" > "$SESSIONS_LIST" 2>/dev/null || cp "$SESSIONS_LIST.raw" "$SESSIONS_LIST"
  else
    cp "$SESSIONS_LIST.raw" "$SESSIONS_LIST"
  fi
  COUNT_AFTER_PRUNE=$(wc -l < "$SESSIONS_LIST" | tr -d ' ')
  EXCLUDED=$(( RAW - COUNT_AFTER_PRUNE ))

  # Drop 0-turn shells (auto-opened/aborted sessions with no user input) before fanout.
  # Independent of the self-prune above, so the two telemetry counts don't overlap.
  SKIPPED_EMPTY=0
  if [ "${AUTODREAM_SKIP_EMPTY:-1}" != "0" ]; then
    filter_empty_sessions < "$SESSIONS_LIST" > "$SESSIONS_LIST.nonempty" \
      && mv "$SESSIONS_LIST.nonempty" "$SESSIONS_LIST" \
      || rm -f "$SESSIONS_LIST.nonempty"
  fi
  COUNT=$(wc -l < "$SESSIONS_LIST" | tr -d ' ')
  SKIPPED_EMPTY=$(( COUNT_AFTER_PRUNE - COUNT ))
  log "found $RAW session files; excluded $EXCLUDED autodream-own, skipped $SKIPPED_EMPTY empty; $COUNT to triage"

  if [ "$COUNT" -eq 0 ]; then
    log "no sessions to triage; writing stub report and exiting"
    cat > "$REPORT_PATH" <<EOF
# Autodream — $TARGET_DATE

No Claude Code sessions were modified on this date.

(Generated $(date -u +%Y-%m-%dT%H:%M:%SZ))

<!-- autodream:open-questions=0 -->
EOF
    # A question-free report still counts as a report. Without this the streak
    # store would keep yesterday's questions alive across an empty night, and a
    # question that reappeared two reports later would be called consecutive when
    # it was not. The early return below is why this cannot live at the usual call
    # site next to notify.sh.
    if [ -x "$AUTODREAM_DIR/question-streaks.sh" ]; then
      "$AUTODREAM_DIR/question-streaks.sh" update "$REPORT_PATH" "$FINDINGS_DIR" \
        || log "question-streaks returned non-zero (continuing)"
    fi
    return 0
  fi

  # Compute once from the final enumeration. Retry rounds reuse these sidecars;
  # they are intentionally not regenerated during dispatch retries.
  compute_session_stats

  # Global pass: must run AFTER every session's sidecar exists (overlap is a
  # cross-session computation, not per-session). Deliberately BEFORE the noise gate
  # runs inside dispatch_l1 below — gated sessions' sidecars still exist and still
  # participate in overlap (see the comment in bin/overlap-stats.sh).
  compute_overlap_stats

  # ---- Layer 1: triage, parallel, retried across sleep/network gaps ----
  # Worker env for omp: keep provider auth (agent.db OAuth on the default models, plus any
  # key x-credentials defined) but strip per-call bloat — no CLAUDE.md auto-load, a scoped tool
  # surface (--tools=Read,Write: read the transcript, write the findings JSON), and the
  # advisor-off overlay (--config "$NO_ADVISOR_CFG") so no headless worker boots the
  # opus advisor. --no-session leaves no transcript.
  # Exported once so both the L1 xargs subshells and the L2 call inherit it.
  export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
  export OMP_BIN NO_ADVISOR_CFG RUNINFRA_API_KEY AUTODREAM_L1_MODEL AUTODREAM_DIR FINDINGS_DIR SLIM WORK_DIR
  # Read by the dispatcher subshell to bound each worker. TIMEOUT_BIN is empty
  # when no timeout binary exists, which the worker treats as run-unbounded.
  export TIMEOUT_BIN AUTODREAM_L1_TIMEOUT L1_KILL_GRACE
  # AUTODREAM_L1_ROUNDS is referenced by the dispatcher subshell to decide
  # whether this is the last retry round (gates the metadata-stub fallback).
  export AUTODREAM_L1_ROUNDS

  # Truncate the timeout ledger here rather than where FINDINGS_DIR is created:
  # this point is past the idempotency guard, so a catch-up trigger that no-ops on
  # an already-reported date cannot erase the ledger the real run wrote.
  : > "$FINDINGS_DIR/l1-timeouts.txt"
  # Same lifetime and the same reason: which workers failed while the host had no route,
  # one `<hash> <round> <true|false>` line per classified failure. This is what tells the
  # loop below that a corpus is outage-short rather than finished.
  : > "$FINDINGS_DIR/l1-netdown.txt"

  clean_work_bucket  # start clean: drop any stub left by a prior run's workers

  # Pre-L1 cache snapshot: how many sessions in the worklist already have a valid
  # findings JSON before any worker runs. Without this, a re-run after a partial
  # crash shows an "impossible" l1_elapsed_seconds (e.g. 2s for 36 sessions)
  # because the dispatcher's idempotent skip exits every worker instantly. The
  # aggregator's self-audit needs this to disambiguate "fast run" from "broken
  # timer".
  L1_PRECACHED=$(l1_missing_count)
  L1_PRECACHED=$(( COUNT - L1_PRECACHED ))

  L1_START=$(date +%s)
  L1_ROUNDS="${AUTODREAM_L1_ROUNDS:-5}"
  MISSING=$COUNT
  # Serialize the first model call of the run. This was added 2026-09-11 against a
  # cold-token race that was never proven, and the race was not the cause: on 2026-09-14
  # workers still exited 0 with empty stdout right after "L1 auth warmup ok", on a
  # static-key provider. The verified cause for 09-13 was first-turn mnemopi recall,
  # now off in l1-no-advisor.yml. The warmup stays because it is one cheap call and it
  # is never fatal: a warmup that fails for its own reasons must not cost the run its
  # corpus. It logs, stamps run-stats, and the rounds proceed either way.
  #
  # Two properties are not optional here, and both were review findings against the first
  # draft of this block (2026-09-11, Codex auditor + executor seats independently):
  #
  # BOUNDED. The warmup runs ahead of wait_for_network, the L1 timeout, the retry loop and
  # the circuit breaker — every recovery mechanism this script has. An unwrapped call that
  # hangs on exactly the cold-start condition it targets therefore wedges the run before
  # any of them, and launchd suppresses later triggers while the job is still alive. So it
  # gets its own deadline, short, and a host with no timeout binary skips the warmup
  # outright rather than running it unbounded — the fanout behind it is already designed to
  # survive a bad token, so an unbounded hang is strictly worse than no warmup.
  #
  # STREAMS SEPARATE. omp prints "Working..." on stderr on every run, including the runs
  # that die. Merging 2>&1 into the captured output made any such run non-empty, so the
  # exact failure this exists to expose — exit 0, empty stdout — was recorded as
  # `l1_warmup: ok`. stdout alone decides; stderr is kept only for the log line.
  L1_WARMUP=skipped
  if [ "${AUTODREAM_L1_WARMUP:-1}" = "0" ]; then
    :
  elif [ -z "$TIMEOUT_BIN" ]; then
    L1_WARMUP=skipped_no_timeout
    log "L1 auth warmup skipped: no timeout binary, and an unbounded warmup can wedge the run before every retry path"
  else
    warmup_errf="$FINDINGS_DIR/l1-warmup.err"
    warmup_out=$(printf 'ping\n' | "$TIMEOUT_BIN" -k 10 "$AUTODREAM_L1_WARMUP_TIMEOUT" "$OMP_BIN" \
      --allow-home \
      -p \
      --approval-mode yolo \
      --no-session \
      --config "$NO_ADVISOR_CFG" \
      --model "${AUTODREAM_L1_MODEL:-deepseek/deepseek-flash}" \
      --append-system-prompt 'Reply with the single word ok and exit.' 2>"$warmup_errf")
    warmup_rc=$?
    # The warmup asks for the single word ok. Anything else on stdout with exit 0 is a
    # diagnostic, not a reply, and must not read as a healthy provider (debate review of
    # e95e2f2). Case and surrounding whitespace or punctuation are tolerated.
    warmup_word=$(printf '%s' "$warmup_out" | tr -d '[:space:][:punct:]' | tr '[:upper:]' '[:lower:]')
    if [ "$warmup_rc" -eq 0 ] && [ "$warmup_word" = "ok" ]; then
      L1_WARMUP=ok
      log "L1 auth warmup ok"
    else
      L1_WARMUP=failed
      # The whole point of the warmup is that this line exists before 8 workers repeat the
      # failure in parallel and bury it. Name both streams: an empty stdout IS the finding,
      # and it is what every .err file for those six nights failed to say.
      log "L1 auth warmup FAILED (exit $warmup_rc): stdout=[${warmup_out:-<empty>}] stderr=[$(head -c 300 "$warmup_errf" 2>/dev/null | tr '\n' ' ')]"
    fi
    unset warmup_out warmup_rc warmup_errf warmup_word
  fi
  # Set when a round could not be dispatched because the host had no route. The run
  # then stops before L2 and writes no report, so the date stays unassembled and a
  # later catch-up trigger retries it against a live network. Writing a report from a
  # dead-network run is worse than writing none: it looks complete, it ships open
  # questions, and its own self-audit has no way to tell that the corpus is missing.
  NET_DEFERRED=no
  LAST_ROUND_RUN=0
  # Consecutive rounds that recovered nothing. A streak, not a comparison against the last
  # round's ending count: comparing end-to-end counts calls two rounds barren whenever the
  # SECOND one is, because round 1 having recovered sessions is invisible in its own ending
  # number. Round 1 taking 3 missing down to 1 and round 2 recovering none leaves both ends
  # equal at 1, which tripped the breaker after a single bad round and logged the lie that
  # rounds 1 and 2 both recovered nothing. Any recovery resets the streak to zero.
  L1_NOPROGRESS=0
  L1_BREAKER=no
  for round in $(seq 1 "$L1_ROUNDS"); do
    # Check BEFORE dispatching, including on round 1 — the overnight failure is a Mac
    # that slept through its trigger, so round 1 is the round most likely to run at a
    # host with no route, and it is the only round nothing used to check.
    if ! wait_for_network; then
      NET_DEFERRED=yes
      log "L1 round $round not dispatched: no route to the API. Deferring $TARGET_DATE for a later run."
      break
    fi
    log "L1 triage round $round/$L1_ROUNDS (fanout=$FANOUT)..."
    # The dispatcher's subshell reads this to decide whether the last-round
    # metadata-stub fallback should fire for sessions that produced no output.
    export AUTODREAM_CURRENT_ROUND="$round"
    # Reference file for the omp-log capture in the failure path: "modified since this
    # round started". Touched per round so a later round does not match a stale log.
    : > "$FINDINGS_DIR/l1-round.ref"
    # Sampled before the dispatch, so "did THIS round recover anything" is answerable
    # without inferring it from the previous round's ending count.
    round_start_missing=$(l1_missing_count)
    dispatch_l1
    LAST_ROUND_RUN="$round"
    MISSING=$(l1_missing_count)
    L1_DONE=$(findings_json_count)
    log "L1 round $round: $L1_DONE done, $MISSING still missing"
    [ "$MISSING" -eq 0 ] && break
    if [ "$MISSING" -lt "$round_start_missing" ]; then
      L1_NOPROGRESS=0
    else
      L1_NOPROGRESS=$((L1_NOPROGRESS + 1))
    fi
    # Circuit breaker. The retry budget is built for a Mac sleeping through a round, and
    # against that it works. Against a worker that dies the same way every time it buys
    # nothing and hides the shape: 2026-09-08 spent all five rounds and 405s to write 16
    # empty stubs, and the run-stats it left (l1_rounds_used 5 of 5, l1_timed_out 0) read
    # as a healthy retry loop rather than as five identical failures. Two consecutive
    # rounds that recover no session means deterministic, not transient.
    #
    # It still has to dispatch once more. The metadata-stub fallback fires only when the
    # dispatcher sees AUTODREAM_CURRENT_ROUND at the budget (see the stub branch above),
    # so breaking out here without that round would leave the slots empty, and an empty
    # slot is not a stub: l1_missing_after_retries would go non-zero and the deferral
    # logic below would read a dead worker as a dead network. So jump to the last round
    # rather than skipping to the end — three dispatches instead of five, with the same
    # artifacts on disk.
    # The -lt guard matters at AUTODREAM_L1_ROUNDS=2 (the test suite runs low budgets):
    # there the final round IS the stub round and has already run, so firing here would
    # dispatch a redundant extra one and log a negative skip count.
    if [ "$L1_NOPROGRESS" -ge 2 ] && [ "$round" -lt "$L1_ROUNDS" ]; then
      L1_BREAKER=yes
      log "L1 circuit breaker: $L1_NOPROGRESS consecutive rounds recovered nothing ($MISSING still missing) as of round $round. Failure is deterministic; skipping $((L1_ROUNDS - round - 1)) retry round(s) and dispatching the stub round."
      export AUTODREAM_CURRENT_ROUND="$L1_ROUNDS"
      : > "$FINDINGS_DIR/l1-round.ref"
      dispatch_l1
      LAST_ROUND_RUN="$L1_ROUNDS"
      MISSING=$(l1_missing_count)
      L1_DONE=$(findings_json_count)
      log "L1 stub round: $L1_DONE done, $MISSING still missing"
      break
    fi
    if [ "$round" -lt "$L1_ROUNDS" ]; then
      log "L1 retrying $MISSING missing session(s) after a network/sleep check..."
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
  # Decide the outage question AFTER the retry budget, not during it. Breaking out of the
  # loop on the first network-flavoured worker failure threw away the whole point of the
  # retry loop: one transient DNS timeout mid-round would defer the date for three hours
  # instead of riding out the flap on the next round, which is exactly what
  # wait_for_network was built to do. Two conditions, both required — sessions are still
  # missing, AND the last round that actually dispatched saw a no-route failure. A run
  # that recovered and finished its corpus is not deferred no matter how bad round 1 was.
  if [ "$MISSING" -gt 0 ] && [ "$LAST_ROUND_RUN" -gt 0 ] \
     && [ -s "$FINDINGS_DIR/l1-netdown.txt" ] \
     && awk -v r="$LAST_ROUND_RUN" '$2 == r && $3 == "true" { found = 1 } END { exit !found }' \
          "$FINDINGS_DIR/l1-netdown.txt"; then
    NET_DEFERRED=yes
    log "L1 finished with $MISSING session(s) missing and round $LAST_ROUND_RUN failing with no route — deferring $TARGET_DATE for a later run"
  fi
  L1_ELAPSED=$(( $(date +%s) - L1_START ))
  L1_OK=$(findings_json_count)
  L1_FAIL=$(ls -1 "$FINDINGS_DIR"/*.json.err 2>/dev/null | wc -l | tr -d " ")
  # In-band failures: a worker that ran to completion but couldn't fit the transcript
  # writes a findings JSON carrying a top-level "error" key (empty findings). These are
  # NOT .json.err files, so l1_err_files=0 masked them — count them explicitly so the
  # self-audit can alarm on a high extraction-failure rate (slimming should drive →0).
  L1_ERRORED=$(find "$FINDINGS_DIR" -type f -name '*.json' ! -name '*.stats.json' \
    -exec grep -l '"error":' {} + 2>/dev/null | wc -l | tr -d " ")
  # Noise-gated sessions: dispatch_l1 wrote a stub instead of calling the model
  # (see the "Noise gate" comment in dispatch_l1). Counted from the findings
  # dir rather than a shared counter, since each gate decision happens inside
  # an independent xargs subshell with no shared state to increment.
  GATED=$(find "$FINDINGS_DIR" -type f -name '*.json' ! -name '*.stats.json' \
    -exec grep -l '"skipped": *"below_noise_gate"' {} + 2>/dev/null | wc -l | tr -d " ")
  log "L1 done in ${L1_ELAPSED}s: $L1_OK done ($L1_ERRORED with errors, $GATED gated), $MISSING missing (.err files: $L1_FAIL)"

  # ---- Oversized-transcript measurement gate (#12) ----
  # Issue #12 proposes chunk-summarizing oversized transcripts instead of slimming them;
  # that implementation is BLOCKED pending evidence it's actually needed. These two
  # counters are the measurement: how many triaged sessions exceeded AUTODREAM_SLIM_BYTES
  # (the same threshold dispatch_l1 checks before calling slim-transcript.sh), and of
  # those, how many still ended in an in-band failure (the same top-level "error" key
  # L1_ERRORED checks above) despite the existing fallback stack (slimming, chunked-Read
  # guidance, metadata-stub path). Gate: if oversized_errored/oversized_total sustains
  # >= 5% over a trailing week, that's the signal issue #12's gate has opened; below that
  # the fallback stack is doing its job. This script only records the counters — the L2
  # self-audit and the human do the trailing-week judgment.
  # Computed post-hoc from the *.stats.json sidecars' transcript_bytes field, same
  # post-hoc pattern as GATED/L1_ERRORED above: the per-worker sz variable at dispatch
  # time (line ~309) lives in an xargs subshell with no shared state to increment
  # directly, so this re-derives it from the sidecar written before dispatch instead.
  #
  # Iterate the SESSION LIST, not the *.stats.json glob (#27). A sidecar that was never
  # written — compute_session_stats deletes the file whenever session-stats.sh fails —
  # is absent from the glob entirely, so the session it belonged to used to drop out of
  # oversized_total without appearing anywhere. Walking the worklist means every triaged
  # session is accounted for exactly once, whatever state its sidecar is in, and stale
  # sidecars left by an earlier enumeration no longer sneak into the count.
  #
  # STATS_SIDECARS_UNPARSEABLE is the shared health signal for every sidecar consumer
  # (#27). One broken sidecar corrupts several counters at once — the noise gate reads
  # the same file inside dispatch_l1 — so the failures are counted once here rather than
  # each stat carrying its own measured/not-measured flag. A sidecar counts as
  # unparseable when it is missing, empty, not valid JSON, or carries no numeric
  # transcript_bytes. The noise gate's own read is deliberately left alone: it already
  # biases to triage on an unreadable sidecar (worst case, a wasted model call), and the
  # only thing missing there was the signal, which this counter now supplies.
  #
  # A worker that failed with no route to the API says nothing about transcript size, and
  # counting it here is how 2026-09-04 read 3/4 as an oversize failure rate and opened
  # issue #12 on an outage. That is handled upstream now: an outage leaves the session
  # unstubbed and defers the run, so it never reaches these counters at all.
  OVERSIZED_TOTAL=0
  OVERSIZED_ERRORED=0
  STATS_SIDECARS_UNPARSEABLE=0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    hash=$(printf "%s" "$session" | shasum -a 1 | cut -c1-12)
    statsfile="$FINDINGS_DIR/$hash.stats.json"
    sz=""
    [ -s "$statsfile" ] && sz=$(jq -r '.transcript_bytes | numbers | floor' "$statsfile" 2>/dev/null)
    case "$sz" in ''|*[!0-9]*) sz="" ;; esac
    if [ -z "$sz" ]; then
      STATS_SIDECARS_UNPARSEABLE=$((STATS_SIDECARS_UNPARSEABLE + 1))
      # Measure the transcript directly rather than letting the session fall out of the
      # count. transcript_bytes is only ever `wc -c` of this same file (session-stats.sh),
      # and dispatch_l1 sizes it exactly this way before slimming, so this is the same
      # quantity from its original source — not an estimate. A clamped 0 here would bias
      # the #12 gate toward staying closed, which is the whole point of the issue.
      sz=$(wc -c < "$session" 2>/dev/null | tr -d ' ')
      case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    fi
    if [ "$sz" -gt "${AUTODREAM_SLIM_BYTES:-262144}" ]; then
      OVERSIZED_TOTAL=$((OVERSIZED_TOTAL + 1))
      findingsfile="$FINDINGS_DIR/$hash.json"
      # No network-down subtraction here. An outage now leaves the slot EMPTY rather than
      # stubbed, so a network failure can never reach this branch — there is no findings
      # file to carry an "error" key. The exclusion this loop briefly grew was dead the
      # moment the stub was suppressed, and a counter that can only ever read 0 tells the
      # self-audit nothing while implying it was measured.
      if [ -f "$findingsfile" ] && grep -q '"error":' "$findingsfile" 2>/dev/null; then
        OVERSIZED_ERRORED=$((OVERSIZED_ERRORED + 1))
      fi
    fi
  done < "$SESSIONS_LIST"
  log "oversized: $OVERSIZED_TOTAL session(s) over ${AUTODREAM_SLIM_BYTES:-262144} bytes ($OVERSIZED_ERRORED errored)"
  if [ "$STATS_SIDECARS_UNPARSEABLE" -gt 0 ]; then
    log "stats sidecars unparseable: $STATS_SIDECARS_UNPARSEABLE of $COUNT (sizes fell back to a live read; gated/oversized counts are degraded)"
  fi

  # ---- Normalize the project field deterministically from the session path ----
  # SESSION_TRIAGE.md asks the L1 worker to emit "project" by hand, and haiku does it
  # nondeterministically: one run surfaced the SAME -Users-sean dir as "-Users-sean",
  # "Users-sean" (dash stripped), and even the bare session UUID (filename, not dir).
  # That splinters L2's per-project grouping. The encoded project dir is just the parent
  # directory of the session JSONL, so derive it from each findings JSON's own
  # session_path (already rewritten back to the real session after any slimming) and
  # overwrite whatever the model guessed. Deterministic, idempotent on re-runs.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$FINDINGS_DIR" <<'PY'
import glob, json, os, sys
findings_dir = sys.argv[1]
fixed = 0
for path in glob.glob(os.path.join(findings_dir, "*.json")):
    try:
        with open(path) as f:
            data = json.load(f)
    except (ValueError, OSError):
        continue  # malformed JSON: leave for the triage-failures report section
    sp = data.get("session_path")
    if not sp:
        continue
    proj = os.path.basename(os.path.dirname(sp))
    if proj and data.get("project") != proj:
        data["project"] = proj
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
        fixed += 1
print(fixed)
PY
    log "normalized project field from session path"
  else
    log "python3 not found; skipping project-field normalization (L2 grouping may show dupes)"
  fi

  # ---- Enforce the mechanical skill fields from the sidecars ----
  # Deliberately NOT inside the python3 block above. The prompt asks the worker to copy
  # these from the precomputed stats, but asking is not enforcing, and gating enforcement
  # on an optional interpreter meant that on a host without python3 the pipeline quietly
  # returned to believing whatever the model wrote — the exact failure this replaced.
  # jq is already a hard dependency of this script, so this cannot silently degrade.
  # compute_session_stats regenerates every sidecar each run, so a sidecar that is missing,
  # unreadable, or has no skills_invoked key means session-stats.sh did not measure this
  # session's skills, and whatever skill fields the findings JSON carries are the worker's
  # own guess. Those are removed and counted, never kept, or L2 ranks them as mechanical
  # counts (Codex review of 0129fc0 and cd309b6). A present-but-keyless sidecar is the
  # quieter case: it passes generation's type check and only breaks here.
  SKILLS_ENFORCED=0
  SKILLS_DROPPED=0
  for fjson in "$FINDINGS_DIR"/*.json; do
    case "$fjson" in *.stats.json) continue ;; esac
    [ -s "$fjson" ] || continue
    jq -e ".findings | arrays" "$fjson" >/dev/null 2>&1 || continue
    sidecar="${fjson%.json}.stats.json"
    skilltmp="$fjson.skills.tmp"
    if ! jq -e 'type == "object" and has("skills_invoked")' "$sidecar" >/dev/null 2>&1; then
      if jq 'del(.skills_invoked, .skills_invoked_count, .skills_invoked_counts, .skills_authored)' \
          "$fjson" > "$skilltmp" 2>/dev/null && [ -s "$skilltmp" ]; then
        mv "$skilltmp" "$fjson"
        SKILLS_DROPPED=$((SKILLS_DROPPED + 1))
      else
        rm -f "$skilltmp"
      fi
      continue
    fi
    if jq --slurpfile sc "$sidecar" '
          . as $f
          | (($sc[0]) // {}) as $st
          | reduce ("skills_invoked", "skills_invoked_count", "skills_authored", "skills_invoked_counts") as $k
              ($f; if ($st | has($k)) then .[$k] = $st[$k] else . end)
        ' "$fjson" > "$skilltmp" 2>/dev/null && [ -s "$skilltmp" ]; then
      mv "$skilltmp" "$fjson"
      SKILLS_ENFORCED=$((SKILLS_ENFORCED + 1))
    else
      rm -f "$skilltmp"
    fi
  done
  log "enforced mechanical skill fields from sidecars on $SKILLS_ENFORCED findings file(s); removed unmeasured skill fields from $SKILLS_DROPPED with no sidecar"

  # ---- Self-audit stats: runtime telemetry only the runner can see ----
  # The aggregator can't observe its own machinery — which sessions were autodream's
  # own (already excluded), how many workers failed, how many retry rounds it took.
  # Surface it so PROMPT.md's "Autodream self-audit" section can flag regressions
  # (e.g. the self-pollution exclusion count climbing again) and propose source fixes.
  # Sessions enumerated by find but unaccounted for at run end — not pruned as
  # self/empty, not in findings. This is the gap the 2026-06-11 self-audit
  # caught: 12 .err files existed but stats showed l1_missing_after_retries=0
  # because both denominators counted from the POST-prune sessions.txt. By
  # computing against RAW and subtracting the legitimate prunes, any session
  # lost to a filter mis-classification or silent worker death surfaces here.
  # Bounded at 0 in case of a counting bug in the prunes.
  DROPPED_AFTER_FAILURES=$(( RAW - L1_OK - EXCLUDED - SKIPPED_EMPTY ))
  [ "$DROPPED_AFTER_FAILURES" -lt 0 ] && DROPPED_AFTER_FAILURES=0
  L1_FRESHLY_PROCESSED=$(( L1_OK - L1_PRECACHED ))
  [ "$L1_FRESHLY_PROCESSED" -lt 0 ] && L1_FRESHLY_PROCESSED=0
  # How many directories we scanned for sessions (colon-count + 1). Kept as its own
  # stat so a regression to single-root scanning is visible from the artifact.
  SESSION_ROOT_COUNT=$(( $(printf '%s' "$SESSION_ROOTS" | tr -cd ':' | wc -c) + 1 ))
  {
    printf '# Autodream run self-audit — %s\n' "$TARGET_DATE"
    # Which code produced this file (#29). install.sh symlinks ~/.claude/autodream/*.sh
    # straight at the repo working tree, so the nightly executes whatever is checked out
    # at 03:15 — a tree sitting behind origin runs old code even though the fix is merged.
    # That has now cost real data twice: the 2026-07-24 overlap-stats.sh dangle, and a
    # tree stuck on a local commit from 2026-07-20 to 2026-07-24 that wrote four nights
    # of run-stats.txt with no oversized_*/gated/overlap_* keys at all. Absent keys are a
    # terrible signal — they read as "this stat did not apply" rather than "this runner
    # predates the stat", and telling those apart took a reflog dig both times. Stamping
    # the commit makes the runner's age legible from the artifact itself.
    printf 'runner_commit: %s\n' "$RUNNER_COMMIT"
    printf 'runner_dirty: %s\n' "$RUNNER_DIRTY"
    # A run with l1_timeout_bin: none is one hung worker away from the silent
    # multi-day wedge of 2026-08-19 and 2026-08-22, so the absence of the bound
    # is stated rather than left to be inferred from a missing key.
    # Which omp actually ran. Absent this, a binary that drifts from the one on the
    # developer's PATH is invisible: on 2026-08-25 the nightly ran 17.3.7 while the
    # shell resolved 18.0.4, half of every L1 round died to provider 400s, and
    # nothing on disk recorded which build produced them.
    printf 'omp_bin: %s\n' "$OMP_BIN"
    printf 'omp_version: %s\n' "$OMP_VERSION"
    printf 'l1_timeout_secs: %s\n' "$AUTODREAM_L1_TIMEOUT"
    printf 'l1_timeout_bin: %s\n' "${TIMEOUT_BIN:-none}"
    # Counted from the per-run ledger, not from surviving *.err files: an .err is
    # truncated by the next retry and deleted whenever the worker leaves output, so
    # counting them undercounts a timeout that later succeeded — and a stale .err
    # from an earlier run of the same date overcounts a clean one.
    printf 'l1_timed_out: %s\n' "$(sort -u "$FINDINGS_DIR/l1-timeouts.txt" 2>/dev/null | grep -c . || true)"
    printf 'session_roots: %s\n' "$SESSION_ROOT_COUNT"
    printf 'session_roots_list: %s\n' "$SESSION_ROOTS"
    printf 'sessions_found_raw: %s\n' "$RAW"
    printf 'self_sessions_excluded: %s\n' "$EXCLUDED"
    printf 'sessions_skipped_empty: %s\n' "$SKIPPED_EMPTY"
    printf 'sessions_triaged: %s\n' "$COUNT"
    # Sessions within sessions_triaged that were skipped before any model call
    # (noise gate). Structurally cannot appear in l1_findings_with_error since
    # they never reached a model; the self-audit denominator for the
    # extraction-failure rate must subtract this out.
    printf 'gated: %s\n' "$GATED"
    # vs.-raw denominator: a session lost to ANY path (prune mis-classification,
    # silent worker death, slim leftovers) shows up here. Always >= 0; if
    # nonzero, the aggregator should investigate even when l1_missing=0.
    printf 'sessions_dropped_after_failures: %s\n' "$DROPPED_AFTER_FAILURES"
    # LAST_ROUND_RUN, not $round: the loop variable is assigned before the pre-dispatch
    # network check, so a round-1 outage that never dispatched anything reported one
    # round used. A stat that counts a round nobody ran is worse than no stat.
    printf 'l1_rounds_used: %s\n' "$LAST_ROUND_RUN"
    printf 'l1_rounds_max: %s\n' "$L1_ROUNDS"
    # Both keys exist so the self-audit can tell a healthy retry loop from five identical
    # failures, which l1_rounds_used alone never could. A `failed` warmup beside a dead
    # corpus names the cause on the artifact instead of leaving it to a repro that will
    # not reproduce; `yes` on the breaker says the budget was cut deliberately, so a
    # short l1_rounds_used is not read as a run that finished early and cleanly.
    # Defaulted because run.sh runs under `set -u` and both are assigned inside the L1
    # phase: any path that writes stats without reaching it would abort the run here,
    # which is the stats writer killing the thing it exists to describe.
    printf 'l1_warmup: %s\n' "${L1_WARMUP:-not_reached}"
    printf 'l1_breaker_fired: %s\n' "${L1_BREAKER:-not_reached}"
    printf 'l1_findings_written: %s\n' "$L1_OK"
    printf 'l1_findings_with_error: %s\n' "$L1_ERRORED"
    # Oversized-transcript measurement gate (#12) — see the computation above L1_ERRORED
    # for the gate meaning (M/N >= 5% over a trailing week opens issue #12).
    printf 'oversized_total: %s\n' "$OVERSIZED_TOTAL"
    printf 'oversized_errored: %s\n' "$OVERSIZED_ERRORED"
    # Network health for this run. network_down_seconds is time spent blocked in
    # wait_for_network across all rounds; network_deferred says the run stopped before L2
    # because a round could not be dispatched at all, which means this date has findings
    # that are incomplete on purpose and a later run should rebuild it.
    # These two cover L1 only: run-stats.txt is closed before the L2 aggregator runs, and
    # L2 has its own retry loop that can wait on the network for just as long. The L2 side
    # is appended after that loop as network_down_seconds_l2 / network_deferred_l2 rather
    # than restated here, so neither key is ever written twice with different values.
    printf 'network_down_seconds: %s\n' "$NET_DOWN_SECONDS"
    printf 'network_deferred: %s\n' "$NET_DEFERRED"
    # Reconciles the two network measurements, which sit at different moments and are
    # read as if they disagreed. network_down_seconds is time the runner spent blocked
    # BETWEEN rounds; the per-worker network_down flag is one curl at the instant a
    # worker failed. A flapping network makes the first large and the second false for
    # every worker, and that is not a contradiction — both probes are the same curl to
    # the same host, so they can only differ by when they ran. The 2026-09-05 report
    # spent a section arguing one of the two detectors had to be wrong; naming the
    # flap here is cheaper than having that argument again.
    if [ "$NET_DOWN_SECONDS" -gt 0 ] \
       && ! awk '$3 == "true" { found = 1 } END { exit !found }' \
              "$FINDINGS_DIR/l1-netdown.txt" 2>/dev/null; then
      printf 'network_flapped: yes\n'
    else
      printf 'network_flapped: no\n'
    fi
    # Sidecar health (#27): how many of sessions_triaged had a stats sidecar that was
    # missing, empty, or carried no numeric transcript_bytes. Every consumer of the
    # sidecars degrades when this is non-zero — `gated` under-counts (an unreadable
    # sidecar never gates, by design) and the oversized sizes came from a live read
    # rather than the sidecar — so it caveats those two keys rather than duplicating
    # a flag onto each of them.
    printf 'stats_sidecars_unparseable: %s\n' "$STATS_SIDECARS_UNPARSEABLE"
    # Findings JSONs whose skill fields were removed because their sidecar was missing,
    # unreadable, or carried no skills_invoked key. The aggregator cannot tell that from
    # absence alone (Codex reviews of 1ee66e4 and cd309b6).
    printf 'skills_unmeasured: %s\n' "${SKILLS_DROPPED:-0}"
    printf 'l1_missing_after_retries: %s\n' "$MISSING"
    printf 'l1_err_files: %s\n' "$L1_FAIL"
    # Cached vs. fresh: lets the aggregator distinguish a sub-second "elapsed"
    # caused by everything already being done from a broken timer.
    printf 'l1_sessions_already_done_at_start: %s\n' "$L1_PRECACHED"
    printf 'l1_sessions_freshly_processed: %s\n' "$L1_FRESHLY_PROCESSED"
    printf 'l1_elapsed_seconds: %s\n' "$L1_ELAPSED"
    # Global cross-session overlap stat (#14) — see compute_overlap_stats above.
    # overlap_measured (#26) disambiguates a genuine zero-overlap night from the
    # script not running/producing usable output; the two count keys are always
    # emitted (0 when unmeasured) so existing consumers never hit a missing key.
    printf 'overlap_measured: %s\n' "$([ "$OVERLAP_MEASURED" = "1" ] && echo yes || echo no)"
    printf 'overlap_events: %s\n' "$OVERLAP_EVENTS"
    printf 'sessions_with_overlap: %s\n' "$SESSIONS_WITH_OVERLAP"
    # Other dates that were triaged and never assembled (#36). Empty means none in the
    # window, which is the reading that matters — this is the key that gets a killed run
    # noticed the next morning instead of during an unrelated investigation two days on.
    printf 'unassembled_dates: %s\n' "${UNASSEMBLED:-}"
  } > "$FINDINGS_DIR/run-stats.txt"

  # Baseline for the L2-scoped network keys appended after the aggregator loop.
  NET_DOWN_SECONDS_PRE_L2="$NET_DOWN_SECONDS"

  # ---- Defer the date when the network never came back ----
  # Stop above L2 rather than aggregating a corpus we know is short. The findings written
  # so far stay on disk and the worker is idempotent, so a later catch-up trigger picks up
  # exactly the sessions that are still missing. Writing no report is what makes that
  # happen: the idempotency guard at the top of run() keys on the report existing, and
  # unassembled_dates() reports this date until one does. Placed after run-stats.txt so
  # the deferral itself is on the record.
  # Nothing below this line is skipped for any other reason, so keep the test narrow —
  # only a round that could not be dispatched at all defers, never a slow or partial one.
  if [ "$NET_DEFERRED" = "yes" ]; then
    log "deferring $TARGET_DATE: the network did not return, so L2 would summarize $((COUNT - MISSING)) of $COUNT sessions"
    log "a later run will retry the $MISSING session(s) still missing; findings so far are kept"
    # PROMPT.md tells the aggregator to read all four network keys, so all four must
    # exist on every path that writes run-stats.txt. This return jumps over the post-L2
    # append, and an absent key is the one thing the self-audit cannot interpret — it
    # cannot tell "L2 never ran" from "an older runner wrote this file". L2 did not run,
    # so its waits are zero and its deferral is no; say so explicitly.
    printf 'network_down_seconds_l2: 0\n' >> "$FINDINGS_DIR/run-stats.txt"
    printf 'network_deferred_l2: no\n' >> "$FINDINGS_DIR/run-stats.txt"
    clean_work_bucket
    return 1
  fi

  # ---- Upstream changelog window (writes changelog-window.md for L2 to read) ----
  changelog_window

  # ---- Operator notes (writes operator-notes.md for L2 to read) ----
  # Merges every capture surface — the terminal-written notes.md and the vault inbox —
  # into one file so PROMPT.md reads a single path. Adding a surface is a change to
  # vault-notes.sh, never to the prompt. Best-effort: a broken vault must not cost the
  # report, so failure here logs and continues.
  if [ -x "$VAULT_NOTES" ]; then
    "$VAULT_NOTES" collect "$FINDINGS_DIR" || log "operator-note collection failed (continuing)"
  else
    log "vault-notes.sh not found at $VAULT_NOTES; skipping operator-note collection"
  fi

  # ---- X bookmarks (writes x-bookmarks.md for L2 to read) ----
  # Unread bookmarks become idea fuel: L2 cross-references what the user saved against
  # what they actually worked on. The script always exits 0 and always writes the file,
  # including a "not configured" stub, so this seam has exactly one shape for L2.
  if [ -x "$XBOOKMARKS" ]; then
    "$XBOOKMARKS" collect "$FINDINGS_DIR" || log "x-bookmark collection failed (continuing)"
  else
    log "x-bookmarks.sh not found at $XBOOKMARKS; skipping bookmark collection"
  fi

  # ---- Was the queryId scraping walk actually exercised tonight? (#38) ----
  # The walk against X's JS bundle is the one part of the fetcher with no test, and the
  # part most likely to break, since it turns on X's bundle layout rather than on anything
  # here. A cached id produces a working fetch without proving the walk still works, so
  # `cache` and `fresh` have to be told apart or a walk that stopped working stays hidden
  # until the cache expires. Appended rather than written above because the collector that
  # knows the answer runs after run-stats.txt is closed; the key is always emitted so a
  # consumer never has to handle it being absent.
  XQID_SOURCE=not_attempted
  if [ -s "$FINDINGS_DIR/x-bookmarks-queryid.txt" ]; then
    XQID_SOURCE=$(tr -d '[:space:]' < "$FINDINGS_DIR/x-bookmarks-queryid.txt")
    [ -n "$XQID_SOURCE" ] || XQID_SOURCE=not_attempted
  fi
  printf 'x_queryid_source: %s\n' "$XQID_SOURCE" >> "$FINDINGS_DIR/run-stats.txt"

  # ---- Skills inventory (writes skills-inventory.txt for L2 to read) ----
  # The L2 prompt treats this file as the authoritative active-skill list. Best-effort:
  # an unusable inventory must never abort the pipeline (L2 falls back to its session surface).
  skills_inv="$SCRIPT_DIR/skills-inventory.sh"
  [ -x "$skills_inv" ] || skills_inv="$AUTODREAM_DIR/skills-inventory.sh"
  "$skills_inv" "$FINDINGS_DIR/skills-inventory.txt" 2>/dev/null \
    || printf '# skills-inventory.txt unavailable\n' > "$FINDINGS_DIR/skills-inventory.txt"

  # ---- Layer 2: opus aggregate, retried until a validated report lands ----
  # The aggregator call can also die to a mid-run sleep (this is what left exit 1 +
  # "no report" overnight). Retry until a capture that is BOTH sentinel-validated
  # (AUTODREAM_REPORT_END present) and open-questions-complete lands at $REPORT_PATH,
  # waiting for the network between attempts. A non-empty report is not a delivery: a
  # marker-bearing capture with no sentinel is the P1 shape and must retry. Idempotent:
  # a re-run overwrites the report harmlessly.
  # L2 auth is agent.db OAuth (file-based, safe at 3am) — no API key needed.
  AUTODREAM_L2_MODEL="${AUTODREAM_L2_MODEL:-anthropic/claude-opus-5}"
  log "L2 model: $AUTODREAM_L2_MODEL"

  # ---- Move a stale report aside before attempting L2 ----
  # The only way to reach this line with $REPORT_PATH already non-empty is
  # AUTODREAM_FORCE=1 (the idempotency guard above returns early otherwise): a previous
  # run of this same TARGET_DATE left a report on disk and we're rebuilding. Nothing
  # below distinguishes "this run wrote it" from "it was already there" — the retry
  # loop's `[ -s "$REPORT_PATH" ] && break` and the consume gate further down both just
  # stat the path. Left in place, an old report satisfies BOTH: the retry loop stops
  # after attempt 1 even though this run's L2 never wrote anything, and the consume
  # gate then archives the vault note / marks bookmarks read as if something had
  # actually read them. That's the exact overnight failure mode this script is built
  # around (Mac sleeps mid-run, every L2 attempt fails) turning into silent,
  # unrecoverable data loss for the user's notes and bookmarks. Move the old file aside
  # first so `-s "$REPORT_PATH"` again means "this run produced it" for both checks.
  # Moved aside, not deleted: if every L2 attempt below still fails, the user's last
  # good report for this date must stay recoverable, not vanish.
  # CONSUME_SAFE is the whole point of this block, not a side effect of it. If the move
  # fails we are back in precisely the state the move exists to prevent: an old report
  # sitting at $REPORT_PATH that a failed L2 will let the retry loop and the consume gate
  # both mistake for this run's output. Continuing anyway would archive unread notes and
  # stamp bookmarks read against a report nothing produced — the silent, unrecoverable
  # loss this is all guarding. So a failed move disarms consuming for the run rather than
  # logging a warning and carrying on.
  CONSUME_SAFE=1
  if [ -s "$REPORT_PATH" ]; then
    STALE_REPORT="$REPORT_PATH.stale-$(date +%s)"
    if mv "$REPORT_PATH" "$STALE_REPORT"; then
      log "existing report for $TARGET_DATE moved aside to $STALE_REPORT before rebuilding (AUTODREAM_FORCE=1)"
    else
      log "WARNING: could not move the existing report aside; this run will NOT archive notes or mark bookmarks read, because a stale report can no longer be told apart from a fresh one"
      STALE_REPORT=""
      CONSUME_SAFE=0
    fi
  fi

  L2_ATTEMPTS="${AUTODREAM_L2_ATTEMPTS:-3}"
  # Delivery gate across attempts. L2_ATTEMPTED separates a fresh run that actually
  # spawned the aggregator from the legacy short-circuits above (the idempotency guard
  # and the COUNT=0 stub both return before L2); L2_DELIVERED flips to 1 only when an
  # attempt's capture carried the AUTODREAM_REPORT_END sentinel. Both default to 0 so
  # the move-aside and consume gate below can distinguish "this run confirmed delivery"
  # from "this run never reached L2" — a pre-existing marker-bearing report from an
  # earlier night must not be treated as this run's output on either path.
  L2_ATTEMPTED=0
  L2_DELIVERED=0
  L2_START=$(date +%s)
  L2_STDOUT="$FINDINGS_DIR/report.stdout"   # L2's report arrives on stdout, not via Write
  L2_RC=1
  for attempt in $(seq 1 "$L2_ATTEMPTS"); do
    L2_ATTEMPTED=1
    log "L2 aggregation attempt $attempt/$L2_ATTEMPTS..."
    # Same literal-path framing and brace-group assembly as L1 (see the L1 worker
    # comment): keep the paths as literal data the aggregator reads with Glob/Read,
    # and preserve the blank-line separator before PROMPT.md instead of letting a
    # `prompt=$(...)` capture strip it and glue the doc onto the report-path line.
    # Subshell so the cwd change (isolating the AI-title stub into $WORK_BUCKET, same
    # as L1) is scoped to this call and doesn't leak into the notify step below.
    # $? after the subshell is the pipeline's exit (claude's), exactly as before.
    (
      cd "$WORK_DIR" 2>/dev/null || true
      {
        printf "Findings directory to aggregate (literal absolute path): %s\n" "$FINDINGS_DIR"
        printf "Report destination (literal absolute path): %s\n\n" "$REPORT_PATH"
        cat "$AUTODREAM_DIR/PROMPT.md"
      } | "$OMP_BIN" \
        --allow-home \
        -p \
        --approval-mode yolo \
        --no-session \
        --config "$NO_ADVISOR_CFG" \
        --model "${AUTODREAM_L2_MODEL:-anthropic/claude-opus-5}" \
        --tools=Glob,Read \
        --append-system-prompt "Headless aggregator. Read the per-session findings JSONs from the findings directory given on line 1 of the prompt, then produce the COMPLETE report only on standard output, ending with a line containing exactly AUTODREAM_REPORT_END. Do not use Write or Edit anywhere. Those paths are literal strings, not shell variables — never \$-expand them. After the sentinel line print one line: report: <literal path from line 2 of the prompt> then a 3-line summary (sessions reviewed, findings), then exit."
    ) > "$L2_STDOUT"

    L2_RC=$?
    # ---- Runner writes the report from L2's stdout (L2 holds no Write/Edit tool) ----
    # The report file exists because THIS script writes it, not the worker. The
    # AUTODREAM_REPORT_END sentinel is the real completion gate: everything before the
    # LAST occurrence of it is the report body, and a capture without one is a degraded
    # report whether or not it happens to carry the open-questions marker — the marker
    # alone cannot prove the write reached the end (that is the P1 bug shape). Both
    # writes are staged to a .tmp and renamed so a half-staged file never lands at
    # $REPORT_PATH, and the post-sentinel lines (the report path + the aggregator's
    # 3-line summary) are appended to the run log so a stripped capture never loses them.
    L2_COMPLETE=0
    if grep -q '^AUTODREAM_REPORT_END$' "$L2_STDOUT" 2>/dev/null; then
      if awk '/^AUTODREAM_REPORT_END$/ { last=NR } { line[NR]=$0 } END { for (i=1; i<last; i++) print line[i] }' "$L2_STDOUT" > "$REPORT_PATH.tmp" && mv "$REPORT_PATH.tmp" "$REPORT_PATH"; then
        L2_COMPLETE=1
      else
        log "WARNING: could not stage the sentinel-stripped report at $REPORT_PATH"
      fi
    elif [ -s "$L2_STDOUT" ]; then
      log "WARNING: L2 stdout carried no AUTODREAM_REPORT_END sentinel; keeping the whole capture as a degraded report (incomplete - will retry)"
      cat "$L2_STDOUT" > "$REPORT_PATH.tmp" && mv "$REPORT_PATH.tmp" "$REPORT_PATH" 2>/dev/null || true
    fi
    awk '/^AUTODREAM_REPORT_END$/ { f=1; next } f { print }' "$L2_STDOUT" >> "$RUN_LOG" 2>/dev/null || true
    L2_DELIVERED=$L2_COMPLETE
    # Break only on a sentinel-validated capture that also carries the open-questions
    # marker; a degraded capture (sentinel absent) NEVER satisfies the loop.
    if [ "$L2_DELIVERED" = "1" ] && report_complete; then
      break
    fi
    if [ -s "$REPORT_PATH" ]; then
      if report_complete; then
        log "L2 attempt $attempt wrote a complete-looking report but no AUTODREAM_REPORT_END sentinel — not a validated delivery, retrying (exit $L2_RC)"
      else
        log "L2 attempt $attempt left a report with no open-questions marker — treating it as truncated and retrying (exit $L2_RC)"
      fi
    else
      log "L2 attempt $attempt wrote no report (exit $L2_RC)"
    fi
    if [ "$attempt" -lt "$L2_ATTEMPTS" ]; then
      # wait_for_network now reports failure rather than proceeding anyway, and this
      # caller used to discard that. Spending the remaining L2 attempts against a host
      # with no route produces nothing but a later exit, and leaves network_deferred
      # reading `no` because only the L1 loop ever set it.
      if ! wait_for_network; then
        NET_DEFERRED=yes
        log "L2 retry not attempted: no route to the API — deferring $TARGET_DATE for a later run"
        break
      fi
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
  clean_work_bucket  # all workers have exited; remove their AI-title stubs

  # L2-scoped network health. Appended rather than folded into the block above, which was
  # already closed before the aggregator ran: an 1800s wait inside the L2 retry loop was
  # invisible in a file claiming to report this run's network_down_seconds.
  # Classify the LAST attempt too. The probe above only runs between attempts, so an
  # outage that arrives before the final attempt was never seen: attempts 1 and 2 fail
  # with the route up, the route drops, attempt 3 fails, and the run recorded
  # network_deferred_l2: no — contradicting what PROMPT.md tells the aggregator an
  # L2-only outage looks like. Only probe when L2 actually failed; a delivered report
  # needs no explanation and should not pay for a network call.
  if [ "$L2_DELIVERED" != "1" ] && ! net_up; then
    NET_DEFERRED=yes
    log "L2 produced no report and the API is unreachable — recording this as a network deferral"
  fi
  printf 'network_down_seconds_l2: %s\n' "$(( NET_DOWN_SECONDS - NET_DOWN_SECONDS_PRE_L2 ))" >> "$FINDINGS_DIR/run-stats.txt"
  printf 'network_deferred_l2: %s\n' "$NET_DEFERRED" >> "$FINDINGS_DIR/run-stats.txt"

  L2_ELAPSED=$(( $(date +%s) - L2_START ))
  log "L2 done in ${L2_ELAPSED}s (exit $L2_RC, $attempt attempt(s))"

  # ---- A truncated report must not become the permanent one ----
  # Every attempt can leave a marker-less file behind (killed mid-write, each time), and
  # nothing below removes it. The idempotency guard at the top of run() tests `-s` alone,
  # so the very next launchd catch-up trigger would see a non-empty report, log "nothing
  # to do", and return — the multi-trigger retry design silently disarmed by the file it
  # exists to replace, with a half-written report standing as the day's output forever.
  # That is the same "non-empty is not complete" error as the other three consumers, at a
  # fourth site, and it is the one that makes the mistake permanent rather than one-night.
  #
  # Move it aside rather than delete it: it may hold most of a report, and a partial
  # report is worth reading even though it must not block a retry. The stub written when
  # COUNT=0 returns long before this line, so it is never affected. Also gated on this
  # run having actually ATTEMPTED L2 and not delivered a sentinel-validated report:
  # legacy dates that short-circuited at the idempotency guard never reached L2, and
  # their pre-existing (marker-bearing) report must sit untouched at $REPORT_PATH for
  # the next catch-up trigger to keep working as before.
  if [ -f "$REPORT_PATH" ] && [ "$L2_ATTEMPTED" = "1" ] && { [ "$L2_DELIVERED" != "1" ] || ! report_complete; }; then
    PARTIAL_REPORT="$REPORT_PATH.partial-$(date +%s)"
    if mv "$REPORT_PATH" "$PARTIAL_REPORT"; then
      log "WARNING: every L2 attempt left an incomplete report; moved it to $PARTIAL_REPORT so a later trigger retries this date"
    else
      log "WARNING: an incomplete report is at $REPORT_PATH and could not be moved aside; later triggers will treat this date as done"
    fi
  fi

  # ---- Retire the copies this date no longer needs, and name the ones it keeps ----
  # This has to sit outside the `-f "$REPORT_PATH"` test below. A successful partial move
  # leaves that path gone, so the stale copy went unmentioned in the one outcome where the
  # user most needs to be told where their last good report went.
  #
  # The moved-aside copy was insurance against this rebuild producing nothing. A complete
  # report means the insurance has expired, and dropping it is what stops every --force
  # rebuild from leaving another .stale-<epoch> file in the dreams dir forever. Only a
  # COMPLETE report supersedes the old one; a truncated file is not a rebuild.
  if [ -n "${STALE_REPORT:-}" ] && [ -s "$STALE_REPORT" ]; then
    if report_complete; then
      rm -f "$STALE_REPORT" && log "rebuild succeeded; discarded the superseded report copy"
    else
      log "this run produced no complete report; the previous one for $TARGET_DATE is still at $STALE_REPORT"
    fi
  fi

  # Partials are prefixes of a report that now exists in full, so a complete report
  # supersedes every one of them for this date — including partials from earlier nights,
  # which is the case the .stale-* rule above can never reach because it only knows about
  # the copy this run made. Without this they pile up in the dreams dir with nothing to
  # ever remove them.
  if report_complete; then
    for partial in "$REPORT_PATH".partial-*; do
      [ -e "$partial" ] || continue
      if rm -f "$partial"; then log "discarded superseded partial report $partial"; fi
    done
  elif [ -n "${PARTIAL_REPORT:-}" ] && [ -s "$PARTIAL_REPORT" ]; then
    log "the incomplete report for $TARGET_DATE is readable at $PARTIAL_REPORT"
  fi

  if [ -f "$REPORT_PATH" ]; then
    log "report bytes: $(wc -c < "$REPORT_PATH" | tr -d ' ')"

    # ---- Drop open-questions file into Sublime (no-op if zero questions) ----
    if [ -x "$AUTODREAM_DIR/notify.sh" ]; then
      log "writing open-questions inbox file..."
      "$AUTODREAM_DIR/notify.sh" "$REPORT_PATH" || log "notify step returned non-zero (continuing)"
    fi

    # ---- Escalate questions this report has now asked N nights running ----
    # After notify.sh, deliberately: the nightly banner goes out either way, and this adds
    # a second, differently-worded one only when a question has gone stale. The failure it
    # answers is not a missing signal but an unchanging one — the X bookmarks question was
    # asked six times across ten failing nights, each night's banner identical to the last,
    # and nothing moved until the user noticed by accident. Never fatal; it is bookkeeping.
    if [ -x "$AUTODREAM_DIR/question-streaks.sh" ]; then
      "$AUTODREAM_DIR/question-streaks.sh" update "$REPORT_PATH" "$FINDINGS_DIR" \
        || log "question-streaks returned non-zero (continuing)"
    fi

    # ---- Consume what L2 just read ----
    # Deliberately gated on a NON-EMPTY report, not merely an existing one. Archiving a
    # note or stamping a bookmark read after a run that produced nothing would throw away
    # the only copy of input the user cared about — the failure mode is silent and
    # unrecoverable, so the guard is stricter than the enclosing -f check.
    #
    # Also gated on TARGET_DATE being the date a normal nightly run would process
    # (yesterday, right now — same computation the default at the top of this script
    # uses). collect() above is date-agnostic: it reads whatever is CURRENTLY in the
    # vault inbox and CURRENTLY unread, regardless of which date's findings dir it's
    # writing into. That's exactly right when TARGET_DATE is tonight's date — but
    # CLAUDE.md documents reprocessing an old one (AUTODREAM_FORCE=1 run.sh
    # 2026-05-29), and archive/mark-read have no idea the date is old: a successful
    # rebuild of 2026-05-29 would archive a note the user wrote THIS morning into
    # processed/2026-05-29/ and stamp today's unread bookmarks read, and tonight's real
    # run would then find an empty inbox and nothing unread — the note never reaches
    # any report. Collection still runs unconditionally above, so L2 still SEES
    # today's notes/bookmarks as context; only the consuming side is skipped for an
    # old-date reprocess.
    # AUTODREAM_CONSUME_DATE overrides which date counts as "the normal nightly one",
    # authoritatively and with no fallback, for the same reason AUTODREAM_STATS_BIN and
    # AUTODREAM_OVERLAP_BIN do: the suite pins a fixed historical TARGET_DATE, so without
    # an override every consume path would take the skip branch and the tests that cover
    # archiving would pass while asserting nothing.
    NORMAL_TARGET_DATE="${AUTODREAM_CONSUME_DATE:-$(date -v-1d +%Y-%m-%d)}"
    # Three-way gate. The first branch is the fresh-run delivery guard: a run that
    # spawned L2 but never produced a sentinel-validated capture must not consume,
    # even when the capture looks complete to report_complete (marker-only, no
    # sentinel — the P1 shape). Legacy runs that never reached L2 (idempotency
    # short-circuit, no-sessions stub) fall through this first branch untouched and
    # keep their historical behavior.
    if [ "$L2_ATTEMPTED" = "1" ] && [ "$L2_DELIVERED" != "1" ]; then
      log "skipping vault-notes archive and x-bookmark mark-read: this run did not deliver a sentinel-validated report (still collected as L2 context)"
    elif ! report_complete; then
      log "report is present but carries no open-questions marker; skipping vault-notes archive and x-bookmark mark-read rather than consuming input against a truncated report"
    else
      # Publishing is NOT a consuming step — it copies the report into the vault so it
      # can be read on a phone, and a reprocessed date is exactly as worth reading as a
      # fresh one. It stays outside the date gate; only archive and mark-read, which
      # destroy the user's only copy of their input, are gated.
      if [ -x "$VAULT_NOTES" ]; then
        "$VAULT_NOTES" publish "$REPORT_PATH" || log "vault report publish failed (continuing)"
      fi
      if [ "${CONSUME_SAFE:-1}" != "1" ]; then
        log "skipping vault-notes archive and x-bookmark mark-read: a stale report could not be moved aside, so this report cannot be attributed to this run"
      elif [ "$TARGET_DATE" = "$NORMAL_TARGET_DATE" ]; then
        if [ -x "$VAULT_NOTES" ]; then
          "$VAULT_NOTES" archive "$FINDINGS_DIR" || log "vault note archive failed (notes stay in the inbox)"
        fi
        if [ -x "$XBOOKMARKS" ]; then
          "$XBOOKMARKS" mark-read "$FINDINGS_DIR" || log "x-bookmark mark-read failed (they stay unread)"
        fi
      else
        log "target date $TARGET_DATE is not $NORMAL_TARGET_DATE (today's normal nightly date); skipping vault-notes archive and x-bookmark mark-read so today's inbox/unread bookmarks aren't consumed by this reprocess (still collected as L2 context)"
      fi
    fi
  else
    # Where the recoverable copies are was already logged above, in the one block that
    # runs whether or not this path still holds a file.
    log "WARNING: no report at $REPORT_PATH"
  fi

  log "===== autodream end: $(date) ====="
  # A validated delivery is the only success, and it is the same predicate the
  # move-aside and consume gates use: a sentinel-validated capture (L2_DELIVERED) that
  # also carries the open-questions marker (report_complete). A sentinel-bearing but
  # marker-less capture is moved to .partial and never consumed, and a fully degraded
  # night can leave the aggregator's own exit code at 0, so either would return 0 here
  # and tell the launchd cron -- the only watcher this unattended job has -- that the
  # night produced a usable report when it produced none. Anything short of validated
  # keeps the aggregator's status when it was non-zero, else 1.
  if [ "$L2_DELIVERED" = "1" ] && report_complete; then
    return 0
  fi
  if [ "${L2_RC:-0}" -ne 0 ]; then
    return "$L2_RC"
  fi
  return 1
}

# ---- The logger must not be able to take the run down with it ----
# `run 2>&1 | tee -a "$RUN_LOG"` turns every log line into a write to a pipe, so whatever
# kills tee kills the run on its very next log call — by SIGPIPE, with no error line,
# before the L2 retry loop, the move-aside blocks, or the consume gate are ever reached.
# Three runs on 2026-08-02 died exactly there and left 2026-08-01 with no report at all:
# `Terminated: 15` on tee, `Broken pipe: 13` on run, and a log ending mid-sentence at
# "L2 aggregation attempt 1/3...". Every recovery path in this script assumes it gets to
# run, and a logger that can revoke that assumption defeats all of them at once.
#
# A file has no reader to lose, so that is where an unattended run writes. Ignoring
# SIGPIPE covers the interactive path too, where tee is still worth having and a closed
# terminal should cost the run its output rather than its life.
trap '' PIPE
if [ -t 1 ]; then
  run 2>&1 | tee -a "$RUN_LOG"
  exit "${PIPESTATUS[0]}"
fi
echo "autodream: logging to $RUN_LOG"
run >> "$RUN_LOG" 2>&1
exit $?
