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

AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"

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

DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
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
  if [ -n "$CMUX" ] && [ -x "$CMUX" ]; then
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
    WS_OUT=$("$CMUX" workspace create \
      --name "$DATE Autodream Triage" \
      --cwd "$HOME" \
      --command "env AUTODREAM_TRIAGE_SURFACE=inline CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 DREAMS_DIR='$DREAMS_DIR' CLAUDE_BIN='$CLAUDE_BIN' '$SELF' '$DATE'$FORCE_ARG" \
      --focus "$AUTODREAM_TRIAGE_FOCUS" 2>&1)
    echo "$WS_OUT"
    # Pin the tab title to the date. The shell sets a startup title (the cwd) a
    # beat after creation, so rename a few times across that window; with claude's
    # own title updates disabled above, the rename then holds. Detached + best
    # effort so review.sh returns immediately and a failure never affects triage.
    WS_REF=$(printf '%s\n' "$WS_OUT" | sed -n 's/.*\(workspace:[0-9][0-9]*\).*/\1/p' | head -1)
    if [ -n "$WS_REF" ]; then
      ( for _ in 1 2 3; do
          sleep 3
          "$CMUX" tab-action --action rename --workspace "$WS_REF" --title "$TAB_TITLE" >/dev/null 2>&1
        done ) &
    fi
    exit 0
  fi
  echo "review.sh: cmux not found ($CMUX_BIN); falling back to inline triage" >&2
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
