#!/bin/bash
# Autodream runner — invoked by launchd at ~3am local time.
#
# Two-layer pipeline:
#   L1: For each of yesterday's session JSONLs, spawn a parallel `omp --model deepseek-v4-flash`
#       running SESSION_TRIAGE.md → writes one findings.json per session.
#   L2: One `omp --model claude-opus-5` running PROMPT.md → reads all findings JSONs,
#       writes $DREAMS_DIR/YYYY-MM-DD.md, updates project MEMORY.md files.
#
# Usage:
#   ./run.sh             # process yesterday
#   ./run.sh 2026-05-24  # process a specific date
#   FANOUT=4 ./run.sh    # tune L1 parallelism (default 8)
#
# Environment overrides (all optional):
#   OMP_BIN        path to omp CLI                       default: /opt/homebrew/bin/omp
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
#   AUTODREAM_DIR  scripts + prompts + state           default: $HOME/.claude/autodream
#   DREAMS_DIR     where final reports are written     default: $HOME/.claude/dreams
#   FANOUT         L1 parallelism                      default: 8
#   AUTODREAM_CHANGELOG  set 0 to skip the upstream-changelog check  default: 1
#   CLAUDE_CODE_REPO     persistent cache for the claude-code clone  default: $AUTODREAM_DIR/cache/claude-code
#   CHANGELOG_REMOTE     git remote to clone/pull       default: https://github.com/anthropics/claude-code.git
#   AUTODREAM_L1_ROUNDS  max L1 retry rounds for missing sessions    default: 5
#   AUTODREAM_L2_ATTEMPTS max L2 attempts to produce a report        default: 3
#   AUTODREAM_RETRY_WAIT seconds to pause between retry rounds       default: 60
#   AUTODREAM_NETCHECK   set 0 to skip waiting-for-network on retry  default: 1
#   AUTODREAM_FORCE      set 1 to rebuild even if a report exists    default: 0
#   AUTODREAM_SLIM_BYTES sessions larger than this are slimmed for L1  default: 262144
#   AUTODREAM_L1_MODEL   override the L1 triage model                 default: runinfra/deepseek-v4-flash
#   AUTODREAM_L2_MODEL   override the L2 aggregator model             default: anthropic/claude-opus-5
#   RUNINFRA_API_KEY     L1 provider key; sourced from $AUTODREAM_DIR/x-credentials (chmod 600)
#                        when present, else resolved from the login keychain. L2 needs no key
#                        (agent.db OAuth).
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

OMP_BIN="${OMP_BIN:-/opt/homebrew/bin/omp}"
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
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
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
# L1 auth band-aid: the L1 provider key (RUNINFRA_API_KEY) lives in the login keychain
# (!security escape), which can be locked at 3am. If $AUTODREAM_DIR/x-credentials
# (chmod 600, key=value lines) exists, source it so the L1 workers pick the key up
# directly; the keychain is the fallback when the file is absent (or lacks the key).
# L2 never needs a key: it authenticates via agent.db OAuth. Sourced with nounset off
# so a user-edited key=value file can never abort the run.
if [ -f "$AUTODREAM_DIR/x-credentials" ]; then
  set +u
  . "$AUTODREAM_DIR/x-credentials" 2>/dev/null || true
  set -u
fi
DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
LOG_DIR="$AUTODREAM_DIR/logs"
FANOUT="${FANOUT:-8}"

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

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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
changelog_window() {
  local out="$FINDINGS_DIR/changelog-window.md"
  [ "${AUTODREAM_CHANGELOG:-1}" != "0" ] || { log "changelog check disabled (AUTODREAM_CHANGELOG=0)"; return 0; }
  command -v git >/dev/null 2>&1 || { log "changelog: git not found; skipping"; return 0; }

  local remote="${CHANGELOG_REMOTE:-https://github.com/anthropics/claude-code.git}"
  local repo="${CLAUDE_CODE_REPO:-$AUTODREAM_DIR/cache/claude-code}"

  if [ -d "$repo/.git" ]; then
    log "changelog: updating cache ($repo)..."
    if ! ( cd "$repo" && git pull --ff-only --quiet ) 2>>"$RUN_LOG"; then
      log "changelog: pull failed"
      printf '# Claude Code changelog\n\nGit pull failed; upstream changes not checked this run.\n' > "$out"
      return 0
    fi
  else
    log "changelog: cloning $remote -> $repo..."
    rm -rf "$repo"
    if ! git clone --quiet "$remote" "$repo" 2>>"$RUN_LOG"; then
      log "changelog: clone failed"
      printf '# Claude Code changelog\n\nGit clone failed; upstream changes not checked this run.\n' > "$out"
      return 0
    fi
  fi

  local head_sha n added
  head_sha=$( cd "$repo" && git rev-parse --short HEAD 2>/dev/null ) || head_sha="?"
  n=$( cd "$repo" && git log --format=%H \
         --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
         -- CHANGELOG.md 2>/dev/null | wc -l | tr -d ' ' )
  # Inserted changelog lines (new version headers + bullets), oldest-first; strip the
  # diff's leading '+' but drop the '+++ b/CHANGELOG.md' file header.
  added=$( cd "$repo" && git log -p --reverse \
             --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
             -- CHANGELOG.md 2>/dev/null \
           | grep '^+' | grep -v '^+++' | sed 's/^+//' )

  if [ "${n:-0}" -gt 0 ] && [ -n "$added" ]; then
    {
      printf '# Claude Code changelog — commits in [%s, %s)\n' "$TARGET_DATE" "$NEXT_DATE"
      printf '# Source: %s @ %s\n' "$remote" "$head_sha"
      printf '# Commits touching CHANGELOG.md in window: %s\n\n' "$n"
      printf '%s\n' "$added"
    } > "$out"
    log "changelog: $n commit(s) in window -> $out"
  else
    printf '# Claude Code changelog — commits in [%s, %s)\n# Source: %s @ %s\n\nNo changelog commits in this window.\n' \
      "$TARGET_DATE" "$NEXT_DATE" "$remote" "$head_sha" > "$out"
    log "changelog: no commits in window"
  fi
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
  local code
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ]
}

wait_for_network() { # block until net_up (capped); no-op when AUTODREAM_NETCHECK=0
  [ "${AUTODREAM_NETCHECK:-1}" != "0" ] || return 0
  local waited=0 cap="${AUTODREAM_NETCHECK_CAP:-1800}"
  while ! net_up; do
    [ "$waited" -ge "$cap" ] && { log "network still down after ~${cap}s of checks; proceeding anyway"; return 0; }
    log "waiting for network to return... (${waited}s)"
    sleep 15; waited=$((waited + 15))
  done
}

l1_missing_count() { # count sessions in $SESSIONS_LIST that still have no findings JSON
  local m=0 s h
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    h=$(printf "%s" "$s" | shasum -a 1 | cut -c1-12)
    jq -e .findings "$FINDINGS_DIR/$h.json" >/dev/null 2>&1 || m=$((m + 1))
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
    output="$FINDINGS_DIR/$hash.json"
    errlog="$output.err"

    # Idempotent, but validate: a non-empty file that is malformed or lacks a
    # top-level findings key is NOT a completed triage (a worker that emitted
    # garbage JSON). Treat it as missing so this pass re-dispatches it, rather
    # than letting it count as done and feed broken records to L2.
    jq -e .findings "$output" >/dev/null 2>&1 && exit 0

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
    {
      printf "Session transcript to analyze (literal absolute path): %s\n" "$readpath"
      printf "Write your findings JSON to this literal absolute path: %s\n\n" "$output"
      cat "$AUTODREAM_DIR/SESSION_TRIAGE.md"
      if [ -s "$FINDINGS_DIR/$hash.stats.json" ]; then
        printf "\n## Precomputed session stats (authoritative — copy these into your output)\n\n\`\`\`json\n"
        cat "$FINDINGS_DIR/$hash.stats.json"
        printf "\n\`\`\`\n"
      fi
    } | "$OMP_BIN" \
      --allow-home \
      -p \
      --approval-mode yolo \
      --no-session \
      --config "$NO_ADVISOR_CFG" \
      --model "${AUTODREAM_L1_MODEL:-runinfra/deepseek-v4-flash}" \
      --tools=Read,Write \
      --append-system-prompt "Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never \$-expand them. Print only the literal word done and exit." \
      > /dev/null 2> "$errlog"

    if [ -s "$output" ]; then
      # Reported path should be the real session, not the temp slim copy. Then drop
      # the slim file (regenerable; keeps the findings dir clean).
      if [ -n "$slimfile" ]; then
        sed -i "" "s#$slimfile#$session#g" "$output" 2>/dev/null || true
        rm -f "$slimfile"
      fi
      rm -f "$errlog"
      echo "ok: $session ($hash)"
    else
      [ -n "$slimfile" ] && rm -f "$slimfile"
      # Worker exited without writing findings JSON. Record a diagnostic so the
      # failure is visible.
      printf "worker produced no findings JSON for %s (incomplete run: omp exited without writing output)\n" "$session" >> "$errlog"
      # On the FINAL retry round, fall back to a metadata-only findings stub so
      # the session is visible to L1_ERRORED and the L2 aggregator instead of
      # disappearing into a silent .err file (the old behavior, which the
      # 2026-06-11 self-audit flagged: 12 .err with l1_findings_with_error=0).
      # Earlier rounds leave $output absent so the next round can retry; only
      # the last round writes the stub. AUTODREAM_L1_ROUNDS comes through the
      # environment (exported below).
      if [ "${AUTODREAM_CURRENT_ROUND:-1}" -ge "${AUTODREAM_L1_ROUNDS:-5}" ]; then
        sz=$(wc -c < "$session" 2>/dev/null | tr -d " ")
        lines=$(wc -l < "$session" 2>/dev/null | tr -d " ")
        printf "{\"session_path\":\"%s\",\"error\":\"worker exited without findings JSON after %s rounds\",\"meta\":{\"bytes\":%s,\"lines\":%s,\"slimmed\":%s},\"findings\":[]}\n" \
          "$session" "${AUTODREAM_L1_ROUNDS:-5}" "${sz:-0}" "${lines:-0}" "$([ -n "$slimfile" ] && echo true || echo false)" > "$output"
        echo "FAIL (metadata stub written): $session ($hash) — see $errlog" >&2
      else
        echo "FAIL: $session ($hash) — see $errlog" >&2
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
  log "omp:         $OMP_BIN"

  [ -x "$OMP_BIN" ] || { log "FATAL: omp not found at $OMP_BIN (set OMP_BIN)"; exit 1; }

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
  # Worker env for omp: keep provider auth (L1's runinfra key from x-credentials or the
  # login keychain) but strip per-call bloat — no CLAUDE.md auto-load, a scoped tool
  # surface (--tools=Read,Write: read the transcript, write the findings JSON), and the
  # advisor-off overlay (--config "$NO_ADVISOR_CFG") so no headless worker boots the
  # opus advisor. --no-session leaves no transcript.
  # Exported once so both the L1 xargs subshells and the L2 call inherit it.
  export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
  export OMP_BIN NO_ADVISOR_CFG RUNINFRA_API_KEY AUTODREAM_L1_MODEL AUTODREAM_DIR FINDINGS_DIR SLIM WORK_DIR
  # AUTODREAM_L1_ROUNDS is referenced by the dispatcher subshell to decide
  # whether this is the last retry round (gates the metadata-stub fallback).
  export AUTODREAM_L1_ROUNDS

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
  for round in $(seq 1 "$L1_ROUNDS"); do
    log "L1 triage round $round/$L1_ROUNDS (fanout=$FANOUT)..."
    # The dispatcher's subshell reads this to decide whether the last-round
    # metadata-stub fallback should fire for sessions that produced no output.
    export AUTODREAM_CURRENT_ROUND="$round"
    dispatch_l1
    MISSING=$(l1_missing_count)
    L1_DONE=$(findings_json_count)
    log "L1 round $round: $L1_DONE done, $MISSING still missing"
    [ "$MISSING" -eq 0 ] && break
    if [ "$round" -lt "$L1_ROUNDS" ]; then
      log "L1 retrying $MISSING missing session(s) after a network/sleep check..."
      wait_for_network
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
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
    printf 'l1_rounds_used: %s\n' "$round"
    printf 'l1_rounds_max: %s\n' "$L1_ROUNDS"
    printf 'l1_findings_written: %s\n' "$L1_OK"
    printf 'l1_findings_with_error: %s\n' "$L1_ERRORED"
    # Oversized-transcript measurement gate (#12) — see the computation above L1_ERRORED
    # for the gate meaning (M/N >= 5% over a trailing week opens issue #12).
    printf 'oversized_total: %s\n' "$OVERSIZED_TOTAL"
    printf 'oversized_errored: %s\n' "$OVERSIZED_ERRORED"
    # Sidecar health (#27): how many of sessions_triaged had a stats sidecar that was
    # missing, empty, or carried no numeric transcript_bytes. Every consumer of the
    # sidecars degrades when this is non-zero — `gated` under-counts (an unreadable
    # sidecar never gates, by design) and the oversized sizes came from a live read
    # rather than the sidecar — so it caveats those two keys rather than duplicating
    # a flag onto each of them.
    printf 'stats_sidecars_unparseable: %s\n' "$STATS_SIDECARS_UNPARSEABLE"
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

  # ---- Layer 2: opus aggregate, retried until a report lands ----
  # The aggregator call can also die to a mid-run sleep (this is what left exit 1 +
  # "no report" overnight). Retry until $REPORT_PATH is non-empty, waiting for the
  # network between attempts. Idempotent: a re-run overwrites the report harmlessly.
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
  L2_START=$(date +%s)
  L2_RC=1
  for attempt in $(seq 1 "$L2_ATTEMPTS"); do
    log "L2 aggregation attempt $attempt/$L2_ATTEMPTS..."
    # Same literal-path framing and brace-group assembly as L1 (see the L1 worker
    # comment): keep the paths as literal data the aggregator hands to Glob/Read/Write,
    # and preserve the blank-line separator before PROMPT.md instead of letting a
    # `prompt=$(...)` capture strip it and glue the doc onto the report-path line.
    # Subshell so the cwd change (isolating the AI-title stub into $WORK_BUCKET, same
    # as L1) is scoped to this call and doesn't leak into the notify/GC steps below.
    # $? after the subshell is the pipeline's exit (claude's), exactly as before.
    (
      cd "$WORK_DIR" 2>/dev/null || true
      {
        printf "Findings directory to aggregate (literal absolute path): %s\n" "$FINDINGS_DIR"
        printf "Write the report to this literal absolute path: %s\n\n" "$REPORT_PATH"
        cat "$AUTODREAM_DIR/PROMPT.md"
      } | "$OMP_BIN" \
        --allow-home \
        -p \
        --approval-mode yolo \
        --no-session \
        --config "$NO_ADVISOR_CFG" \
        --model "${AUTODREAM_L2_MODEL:-anthropic/claude-opus-5}" \
        --tools=Glob,Read,Write,Edit \
        --append-system-prompt "Headless aggregator. Read the per-session findings JSONs from the findings directory given on line 1 of the prompt, then write the report, via the Write tool, to the literal report path given on line 2. Those paths are literal strings, not shell variables — never \$-expand them. May edit project MEMORY.md files per the prompt rules. Print report path and 3-line summary, then exit."
    )

    L2_RC=$?
    report_complete && break
    if [ -s "$REPORT_PATH" ]; then
      log "L2 attempt $attempt left a report with no open-questions marker — treating it as truncated and retrying (exit $L2_RC)"
    else
      log "L2 attempt $attempt wrote no report (exit $L2_RC)"
    fi
    if [ "$attempt" -lt "$L2_ATTEMPTS" ]; then
      wait_for_network
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
  clean_work_bucket  # all workers have exited; remove their AI-title stubs

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
  # COUNT=0 returns long before this line, so it is never affected.
  if [ -f "$REPORT_PATH" ] && ! report_complete; then
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
    if ! report_complete; then
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

    # ---- Symbiotic GC: trigger cc-simple-memory to consolidate
    #      around the pins Layer 2 just added (no-op if not installed
    #      or AUTODREAM_GC=0). Iterates the touched-projects sidecar
    #      Layer 2 wrote — re-uses the cwd recorded in each project's
    #      session JSONLs to give claude-memory the right project root.
    if [ "${AUTODREAM_GC:-1}" != "0" ] && command -v claude-memory >/dev/null 2>&1; then
      TOUCHED="$FINDINGS_DIR/touched-projects.txt"
      if [ -s "$TOUCHED" ]; then
        log "claude-memory detected; running GC for $(wc -l < "$TOUCHED" | tr -d ' ') touched project(s)..."
        sort -u "$TOUCHED" | while IFS= read -r encoded; do
          [ -z "$encoded" ] && continue
          proj="$PROJECTS_DIR/$encoded"
          [ -d "$proj" ] || { log "  skip: $encoded (no project dir)"; continue; }

          cwd=$(grep -hom1 '"cwd":"[^"]*"' "$proj"/*.jsonl 2>/dev/null \
                 | head -1 | sed 's/^"cwd":"//;s/"$//')
          if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
            log "  skip: $encoded (cwd not resolvable)"
            continue
          fi
          log "  gc: $cwd"
          ( cd "$cwd" && claude-memory gc ) >> "$RUN_LOG" 2>&1 \
            || log "    gc failed for $cwd (continuing)"
        done
      else
        log "claude-memory installed but no project memory was touched; skipping per-project GC"
      fi
    fi
  else
    # Where the recoverable copies are was already logged above, in the one block that
    # runs whether or not this path still holds a file.
    log "WARNING: no report at $REPORT_PATH"
  fi

  log "===== autodream end: $(date) ====="
  return $L2_RC
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
