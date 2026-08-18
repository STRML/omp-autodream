#!/bin/bash
# Open an interactive Claude session with the latest autodream report preloaded
# and instructions to walk through the open questions one at a time.
#
# Usage: review.sh                  # opens latest report
#        review.sh YYYY-MM-DD       # opens specific report
#        review.sh --force [DATE]   # open even if there is nothing to triage
#
# A report with nothing to triage does not get a session. Most nights the
# report has no open questions, and launching claude just to be told "nothing
# to do" costs a full session's tokens to print one line. Instead we detect
# that case here and print the line ourselves. The check is deliberately
# conservative: anything we cannot classify launches the session, because a
# false "nothing to do" silently swallows real questions, while a false launch
# only wastes tokens. --force bypasses it.
#
# Where the triage session lands is controlled by AUTODREAM_TRIAGE_SURFACE
# (set in $AUTODREAM_DIR/config, see config.example):
#   inline  (default)  run the claude session right here in the current terminal
#   cmux               launch it in its own cmux workspace
#
# Why this knob exists: launching review.sh as a shell script makes macOS route
# it to whatever app is the default handler for public.shell-script (iTerm2 on
# this host), so the triage kept opening in iTerm2. `cmux` gives it a dedicated
# workspace instead. Env vars override the config file; config overrides defaults.

set -u

# The install symlinks the scripts INTO $AUTODREAM_DIR (install.sh), so on a
# bare shell invocation with no env the script's own location IS the install
# dir. This is what lets `review.sh <date>` run from a terminal without the
# launchd plist's env: the OMP port installs to ~/.omp/agent/{autodream,dreams},
# so the legacy ~/.claude/{autodream,dreams} defaults made every manual
# invocation "could not locate" the report. Env still wins; the derived dir is
# only trusted when it carries an install marker file (install.sh writes both).
AUTODREAM_DIR="${AUTODREAM_DIR:-}"
if [ -z "$AUTODREAM_DIR" ]; then
  AUTODREAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -z "$AUTODREAM_DIR" ] || { [ ! -f "$AUTODREAM_DIR/config" ] && [ ! -f "$AUTODREAM_DIR/l1-no-advisor.yml" ]; }; then
    echo "review.sh: WARNING no install markers next to $0; falling back to legacy $HOME/.claude/autodream" >&2
    AUTODREAM_DIR="$HOME/.claude/autodream"
  fi
fi

# Load the config file first, then let any env-provided values win over it.
__env_dreams="${DREAMS_DIR:-}"; __env_claude="${CLAUDE_BIN:-}"
__env_surface="${AUTODREAM_TRIAGE_SURFACE:-}"; __env_cmux="${CMUX_BIN:-}"
__env_focus="${AUTODREAM_TRIAGE_FOCUS:-}"
CONFIG_FILE="${AUTODREAM_CONFIG:-$AUTODREAM_DIR/config}"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ -n "$__env_dreams" ] && DREAMS_DIR="$__env_dreams"
[ -n "$__env_claude" ] && CLAUDE_BIN="$__env_claude"
[ -n "$__env_surface" ] && AUTODREAM_TRIAGE_SURFACE="$__env_surface"
[ -n "$__env_cmux" ] && CMUX_BIN="$__env_cmux"
[ -n "$__env_focus" ] && AUTODREAM_TRIAGE_FOCUS="$__env_focus"

# Reports live in the sibling of the install dir (~/.omp/agent/dreams here).
DREAMS_DIR="${DREAMS_DIR:-$(dirname "$AUTODREAM_DIR")/dreams}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
AUTODREAM_TRIAGE_SURFACE="${AUTODREAM_TRIAGE_SURFACE:-inline}"
CMUX_BIN="${CMUX_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
# Whether the cmux triage workspace grabs focus on launch. Default false so a
# nightly/background run does not yank you out of what you are doing.
AUTODREAM_TRIAGE_FOCUS="${AUTODREAM_TRIAGE_FOCUS:-false}"
[ "$AUTODREAM_TRIAGE_FOCUS" = "true" ] || AUTODREAM_TRIAGE_FOCUS="false"

FORCE=0
POSITIONAL=""
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    -h|--help)
      # Print the header comment block verbatim: everything from line 2 until the
      # first non-comment line. Derived rather than a line range, so growing the
      # header cannot silently truncate --help mid-sentence.
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    -*) echo "review.sh: unknown option: $arg" >&2; exit 2 ;;
    *)
      # One report per run. Silently triaging only the last of several dates
      # would be a confusing way to lose a request.
      if [ -n "$POSITIONAL" ]; then
        echo "review.sh: expected one date, got '$POSITIONAL' and '$arg'" >&2
        exit 2
      fi
      POSITIONAL="$arg" ;;
  esac
done

if [ -n "$POSITIONAL" ]; then
  REPORT="$DREAMS_DIR/$POSITIONAL.md"
else
  REPORT=$(ls -t "$DREAMS_DIR"/*.md 2>/dev/null | head -1)
fi

if [ -z "${REPORT:-}" ] || [ ! -f "$REPORT" ]; then
  echo "review.sh: no autodream report found"
  echo "  looked in: $DREAMS_DIR"
  echo "  try: $(dirname "$0")/run.sh"
  exit 1
fi

DATE=$(basename "$REPORT" .md)

# How many open questions the report says need a human call. Prints an integer,
# or "unknown" when it cannot tell (the caller must then launch the session).
#
# The marker is the contract: PROMPT.md makes L2 emit
# `<!-- autodream:open-questions=N -->` in the Open questions section. Reports
# written before that contract existed have no marker, so we fall back to
# reading the prose L2 has used consistently ("None that clear the triviality
# gate this run."). The fallback only ever recognises a shape it is sure about;
# everything else is "unknown" rather than a guess.
report_open_questions(){
  local report="$1" marker section first

  marker=$(sed -n 's/.*<!-- *autodream:open-questions=\([0-9][0-9]*\) *-->.*/\1/p' "$report" | head -1)
  if [ -n "$marker" ]; then printf '%s\n' "$marker"; return 0; fi

  # Empty-day stub: run.sh writes this when no sessions were modified at all.
  if grep -q '^No Claude Code sessions were modified' "$report"; then echo 0; return 0; fi

  section=$(awk '/^## Open questions/{f=1;next} /^## /{f=0} f' "$report")
  first=$(printf '%s\n' "$section" | grep -v '^[[:space:]]*$' | head -1)
  # No section at all, or an empty one: not a shape we recognise. Launch.
  [ -n "$first" ] || { echo unknown; return 0; }

  case "$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')" in
    none*) echo 0; return 0 ;;
  esac
  echo unknown
}

report_is_triaged(){ grep -q '^## Triage decisions' "$1"; }

# Decisions have been written as both bullets and numbered lists across the
# report history, so count either. Used only to flavour the notice text.
report_triage_count(){
  awk '/^## Triage decisions/{f=1;next} /^## /{f=0} f' "$1" | grep -cE '^([-*]|[0-9]+\.) '
}

skip_notice(){
  echo "autodream $DATE: $1"
  echo "  report:      $REPORT"
  echo "  open anyway: $(basename "$0") --force $DATE"
}

if [ "$FORCE" -eq 0 ]; then
  # Triage state first: a report can be both empty and already worked through
  # (an empty-day stub someone closed out), and "already triaged" is the more
  # informative reason of the two.
  if report_is_triaged "$REPORT"; then
    COUNT=$(report_triage_count "$REPORT" | tr -d ' ')
    if [ "$COUNT" -eq 1 ] 2>/dev/null; then
      skip_notice "already triaged (1 decision logged)."
    elif [ "$COUNT" -gt 1 ] 2>/dev/null; then
      skip_notice "already triaged ($COUNT decisions logged)."
    else
      skip_notice "already triaged."
    fi
    exit 0
  fi
  if [ "$(report_open_questions "$REPORT")" = "0" ]; then
    skip_notice "no open questions, nothing to triage."
    exit 0
  fi
fi

# Hand the triage session off to its own cmux workspace when configured. We do
# this only after resolving + validating the report above, so a missing-report
# error surfaces in this terminal rather than in a detached workspace. The new
# workspace re-runs this script with the surface forced back to inline, so it
# falls through to the normal `exec claude` below.
if [ "$AUTODREAM_TRIAGE_SURFACE" = "cmux" ]; then
  CMUX="$CMUX_BIN"; [ -x "$CMUX" ] || CMUX=$(command -v cmux 2>/dev/null || true)
  # Runtime cmux discovery does NOT depend on PATH: CMUX_BIN's default is the
  # hardcoded /Applications bundle (config-load section above), so the launchd
  # job's minimal env resolves cmux whenever install.sh's preflight accepted it.
  # Config CMUX_BIN takes precedence (review.sh preserves it from the config);
  # install.sh provisions the review job iff the same three-way resolution
  # (config → PATH → default) finds an executable, so runtime can never diverge
  # from install time.
  if [ -n "$CMUX" ] && [ -x "$CMUX" ]; then
    # Same-day dedup for the review job's catch-up triggers (08:00/09:15/12:15,
    # provisioned by install.sh like the run job). Whichever trigger fires first
    # after the report lands opens the workspace and stamps a confirmed marker;
    # later triggers for the same date honor it instead of opening a second
    # workspace on top of the first. --force bypasses the marker, so a
    # deliberately relaunched triage still works.
    #
    # The marker binds to the REPORT's content digest (not just the date):
    # rebuilding a date with AUTODREAM_FORCE=1 produces a new report, whose new
    # digest invalidates the old marker and lets the popup re-trigger. The claim
    # is atomic (mkdir, which fails if the dir already exists) so two
    # overlapping triggers cannot both pass the check before either stamps.
    LOGS_DIR="$AUTODREAM_DIR/logs"
    # Fail loudly if the logs dir can't be made: a subsequent claim-mkdir
    # failure would otherwise be misreported as "another invocation" and
    # silently drop triage.
    if ! mkdir -p "$LOGS_DIR"; then
      echo "review.sh: cannot create logs dir $LOGS_DIR" >&2
      exit 1
    fi
    # Report identity key: a content digest, not mtime. mtime is
    # seconds-resolution, so a same-second rebuild shares a marker and its
    # triage is silently swallowed. The digest changes whenever the report
    # content changes, which is exactly the rebuild signal. Fall back to the
    # mtime if shasum is somehow unavailable (a 64-char dir name is the only
    # cost either way).
    REPORT_KEY=$(shasum -a 256 "$REPORT" 2>/dev/null | awk '{print $1}')
    # The assignment's exit status is awk's (0 even on empty input), so a
    # failing/missing shasum must be detected by emptiness, not rc — an empty
    # key would collapse every report that day to the same marker. Fall back
    # to the mtime (a failed shasum is the only path that lands here).
    [ -n "$REPORT_KEY" ] || REPORT_KEY="mtime-$(stat -f %m "$REPORT" 2>/dev/null || echo 0)"
    LAUNCH_MARKER="$LOGS_DIR/review-launched-$DATE-$REPORT_KEY"
    # Confirmation lives as a SIBLING file, not inside the claim dir: the
    # stale-reap below uses `find -delete` (rmdir semantics), which silently
    # fails on a non-empty dir. Kept separate, the claim dir stays empty and
    # both names still match the review-launched-* prune glob.
    LAUNCH_CONFIRMED="$LAUNCH_MARKER.confirmed"
    # Users upgrading from the round-1 code carry a touch-created FILE
    # review-launched-$DATE (date-bound, no content key). Honor it as a real
    # launch and migrate it to the confirmed token so the new key owns state
    # from here on — otherwise the same report opens a second workspace
    # post-upgrade on the very day it was already triaged.
    #
    # But only when the marker is not OLDER than the current report: a date
    # was triaged, then the report rebuilt for that date (new content, new
    # digest), the legacy date-only marker must NOT be migrated onto the new
    # report's key — that would mark unreviewed content as confirmed and
    # swallow its triage. Compare mtimes: a rebuilt report is newer than the
    # legacy launch, so we skip the migration and let the fresh digest open.
    LEGACY_MARKER="$LOGS_DIR/review-launched-$DATE"
    if [ -f "$LEGACY_MARKER" ]; then
      LEGACY_MTIME=$(stat -f %m "$LEGACY_MARKER" 2>/dev/null || echo 0)
      if [ "$LEGACY_MTIME" -lt "$(stat -f %m "$REPORT" 2>/dev/null || echo 0)" ]; then
        echo "review.sh: legacy marker $LEGACY_MARKER predates the current report; not migrated (report content changed since)"
      else
        echo "review.sh: migrating legacy marker $LEGACY_MARKER -> $LAUNCH_CONFIRMED"
        mv "$LEGACY_MARKER" "$LAUNCH_CONFIRMED" 2>/dev/null || true
      fi
    fi
    CLAIM_GRACE=900
    CLAIMED=0
    # Reap stale state so it cannot grow unbounded: claim dirs and confirmed
    # tokens older than 14 days. `-delete` handles both the empty dir and its
    # sibling file. Unconditional on --force: the force path is exactly the
    # retry-after-failure route and must not be the one path that skips the
    # forest cleanup (all three --force occasions leave the old claim in place).
    find "$LOGS_DIR" -maxdepth 1 -name 'review-launched-*' -mtime +14 -delete 2>/dev/null || true
    if [ "$FORCE" -eq 0 ]; then
      # Already confirmed -> definitely launched. Skip.
      if [ -e "$LAUNCH_CONFIRMED" ]; then
        echo "review.sh: $DATE triage already launched for this report (marker $LAUNCH_CONFIRMED)"
        echo "  open anyway: $(basename "$0") --force $DATE"
        exit 0
      fi
      # A claim dir with no confirmed token is either an in-flight launch or
      # an abandoned one (the process died while cmux was blocked). Age
      # bounds it: younger than CLAIM_GRACE is in-progress; older is a dead
      # claim to reclaim, so a killed popup can never suppress triggers
      # forever.
      if [ -d "$LAUNCH_MARKER" ]; then
        MARKER_AGE=$(( $(date +%s) - $(stat -f %m "$LAUNCH_MARKER" 2>/dev/null || echo "$(date +%s)") ))
        if [ "$MARKER_AGE" -ge "$CLAIM_GRACE" ]; then
          echo "review.sh: reclaiming abandoned claim $LAUNCH_MARKER"
          rmdir "$LAUNCH_MARKER" 2>/dev/null || true
        else
          echo "review.sh: $DATE triage launch already in progress by another invocation"
          exit 0
        fi
      fi
      # Atomic claim: mkdir fails if another invocation won the race. But a
      # failed mkdir is ALSO what a read-only/space-full logs dir produces —
      # reporting that as "in progress" and exiting 0 silently drops triage.
      # `mkdir -p $LOGS_DIR` above does not catch an already-existing-but-
      # unwritable dir, so distinguish the claim's mkdir outcomes: if the
      # claim dir now exists it was a genuine race (exit 0); otherwise it is
      # an I/O error (fail loudly).
      if ! mkdir "$LAUNCH_MARKER" 2>/dev/null; then
        if [ -e "$LAUNCH_MARKER" ]; then
          echo "review.sh: $DATE triage launch already in progress by another invocation"
          exit 0
        fi
        echo "review.sh: cannot create claim $LAUNCH_MARKER" >&2
        exit 1
      fi
      CLAIMED=1
    fi
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    # Workspace + tab are named after the triaged date (ISO, i.e. the report's
    # own YYYY-MM-DD — the date of the questions being addressed, not today).
    TAB_TITLE="$DATE Autodream Triage"
    # Carry --force through: the workspace re-runs this script, and without it
    # the inner run would re-check, decide there is nothing to triage, and exit
    # immediately — leaving a workspace that dies on open.
    FORCE_ARG=""; [ "$FORCE" -eq 1 ] && FORCE_ARG=" --force"
    echo "review.sh: opening $DATE triage in a new cmux workspace (focus=$AUTODREAM_TRIAGE_FOCUS)"
    # The workspace re-runs this script with the surface forced to inline so it
    # falls through to the exec claude below. CLAUDE_CODE_DISABLE_TERMINAL_TITLE
    # stops claude live-rewriting the tab title over our pinned date.
    #
    # The inner command is a shell string cmux will run, so every interpolated
    # value is %q-quoted: paths (DREAMS_DIR, CLAUDE_BIN, SELF) and DATE may
    # legitimately contain apostrophes (e.g. an install under /tmp/O'Brien),
    # and an unquoted one would break the inner shell parse. $FORCE_ARG is
    # generated here and can only be empty or " --force", so it stays literal.
    shq(){ printf '%q' "$1"; }
    INNER_CMD="env AUTODREAM_TRIAGE_SURFACE=inline CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 DREAMS_DIR=$(shq "$DREAMS_DIR") CLAUDE_BIN=$(shq "$CLAUDE_BIN") $(shq "$SELF") $(shq "$DATE")$FORCE_ARG"
    WS_OUT=$("$CMUX" workspace create \
      --name "$DATE Autodream Triage" \
      --cwd "$HOME" \
      --command "$INNER_CMD" \
      --focus "$AUTODREAM_TRIAGE_FOCUS" 2>&1)
    WS_RC=$?
    echo "$WS_OUT"
    # A failed create must not be treated as a launch: release the claim so the
    # next trigger retries, and exit non-zero so a scheduled job can't think the
    # triage happened. Without the exit check, a cmux that fails but prints
    # workspace-like output would also satisfy the ref parse below and latch a
    # false marker.
    if [ "$WS_RC" -ne 0 ]; then
      [ "$CLAIMED" -eq 1 ] && rmdir "$LAUNCH_MARKER" 2>/dev/null || true
      echo "review.sh: cmux workspace create failed (exit $WS_RC); triage not opened" >&2
      exit 1
    fi
    # cmux returned 0: per the tool's contract a workspace was created. Bind
    # the confirmed token NOW — before any further parsing — so the dedup fact
    # is durable regardless of what happens next (a kill between create and
    # confirm, or a stdout format change). Age-based reclaim must never treat a
    # created-but-unconfirmed launch as abandoned and spawn a second workspace.
    # This is unconditional on the claim (a --force run skipped the claim mkdir
    # but is still a real launch, and round-1 stamped on any successful create).
    #
    # Executor race: a concurrent --force rebuild (run.sh:1214) can replace
    # the report between our hash above and the workspace actually reading it.
    # Re-check: if the on-disk content changed, the workspace triaged the NEW
    # report, so bind the confirmed token to the NEW digest (the inner run will
    # recompute its own key anyway on its next trigger), not the stale one we
    # launched under. Only the string compare matters; recompute via the same
    # command as the marker computation.
    CURRENT_KEY=$(shasum -a 256 "$REPORT" 2>/dev/null | awk '{print $1}')
    if [ -n "$CURRENT_KEY" ] && [ "$CURRENT_KEY" != "$REPORT_KEY" ]; then
      echo "review.sh: report changed while launching (digest $REPORT_KEY -> $CURRENT_KEY); binding confirm to current digest" >&2
      LAUNCH_CONFIRMED="$LOGS_DIR/review-launched-$DATE-$CURRENT_KEY.confirmed"
    fi
    # touch failure is warned, not fatal: the workspace IS created at this
    # point; the unconfirmed claim (if any) is grace-bounded and the next
    # trigger's reclaim would open a duplicate, so report it loudly but do not
    # claim the launch failed.
    if ! touch "$LAUNCH_CONFIRMED"; then
      echo "review.sh: WARNING could not write confirmed token $LAUNCH_CONFIRMED" >&2
    fi
    # Pin the tab title to the date. The shell sets a startup title (the cwd) a
    # beat after creation, so rename a few times across that window; with claude's
    # own title updates disabled above, the rename then holds. Detached + best
    # effort so review.sh returns immediately and a failure never affects triage.
    # WS_REF is cosmetic here — confirmation is already bound above — so an
    # unparseable/absent ref (cmux stdout changed shape) only skips the title
    # rename, never the launch.
    WS_REF=$(printf '%s\n' "$WS_OUT" | sed -n 's/.*\(workspace:[0-9][0-9]*\).*/\1/p' | head -1)
    if [ -n "$WS_REF" ]; then
      ( for _ in 1 2 3; do
          sleep 3
          "$CMUX" tab-action --action rename --workspace "$WS_REF" --title "$TAB_TITLE" >/dev/null 2>&1
        done ) &
    fi
    exit 0
  fi
  if [ -t 0 ]; then
    # Interactive manual run (terminal): falling through to the inline claude
    # session below is right — the user is watching this terminal.
    echo "review.sh: cmux not found ($CMUX_BIN); falling back to inline triage" >&2
  else
    # Non-interactive (the launchd review job, ssh, a script): a headless
    # `exec claude` has no TTY to talk to — the session hangs or exits
    # uselessly and the marker was never confirmed, so every trigger retries
    # forever and no popup ever happens. Fail the trigger loudly instead.
    echo "review.sh: cmux not found ($CMUX_BIN) and stdin is not a TTY; aborting scheduled triage (no headless launch)" >&2
    exit 1
  fi
fi

REPORT_BYTES=$(wc -c < "$REPORT" | tr -d ' ')

# Build system prompt via tmpfile — heredocs inside $(...) get confused by
# apostrophes in the body (parser treats them as quote pairs and a literal
# `)` in the text prematurely closes the command substitution).
SYSTEM_TMP=$(mktemp -t autodream-review.XXXXXX)
trap 'rm -f "$SYSTEM_TMP"' EXIT
cat > "$SYSTEM_TMP" <<EOF
You are the morning autodream review partner. The user has opened this terminal session to triage open questions from last night's autodream run. The full report from $DATE follows — keep it in context but DO NOT dump it back to the user.

<autodream-report date="$DATE" path="$REPORT" bytes="$REPORT_BYTES">
$(cat "$REPORT")
</autodream-report>

Workflow when the user says "go" or otherwise signals ready:

1. Restate ONE open question (in order from the report's "Open questions for the user" section).
2. Cite the specific findings driving it (one-sentence summary, plus the section number in the report).
3. Recommend a concrete action. Be opinionated — the user trusts your judgment.
4. Wait for: approve / modify / skip / discuss.
5. If approved: execute (run shell commands, edit files — you have bypassPermissions). If modified: incorporate the change, confirm, then execute. If skipped or discussed: log the decision in a one-line follow-up comment at the bottom of $REPORT under a "## Triage decisions" section (create if absent).
6. Move to the next question. Don't batch multiple questions in one turn.

When all open questions are resolved, write a brief summary at the bottom of $REPORT under "## Triage decisions", thank the user, and exit.

Other rules:
- You may edit any file the autodream prompt allows you to edit (settings.json, .claude/* in the relevant project), plus you may now edit ~/.claude/CLAUDE.md, ~/.claude/rules/*, and ~/.claude/docs/guardrails/* if the user explicitly approves.
- Don't proceed on any CLAUDE.md / rules / guardrails edit without explicit per-edit approval — those are global.
- Be terse. One question, one decision, one action, then next.
EOF
SYSTEM=$(cat "$SYSTEM_TMP")
rm -f "$SYSTEM_TMP"
trap - EXIT

echo "─── autodream review: $DATE ($REPORT_BYTES bytes) ───"
echo "Starting triage. /quit to exit."
echo

cd "$HOME" || exit 1
exec "$CLAUDE_BIN" \
  --permission-mode bypassPermissions \
  --append-system-prompt "$SYSTEM" \
  "go"
