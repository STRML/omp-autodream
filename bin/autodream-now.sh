#!/usr/bin/env bash
# autodream-now.sh — run the autodream pipeline NOW via launchd, detached from any
# foreground/background timeout (Claude Code background Bash tasks cap at ~10 min,
# ssh sessions die on disconnect, etc). launchd owns the process, so the run
# survives the caller going away and has no time cap.
#
# It bootstraps a TRANSIENT one-shot LaunchAgent (label "<base>.ondemand") that runs
# run.sh once and exits. It never touches the scheduled nightly job.
#
# Usage:
#   autodream-now.sh [YYYY-MM-DD] [--force] [--watch] [--dry-run]
#     YYYY-MM-DD   date to process (default: yesterday, same as run.sh)
#     --force      set AUTODREAM_FORCE=1 (rebuild even if a report already exists)
#     --watch      tail the run log until the report appears (or it gives up), then exit
#     --dry-run    print the generated plist + launchctl commands; don't run anything
#
# Everything is auto-detected — nothing is hardcoded to a particular user or host.
set -euo pipefail

# ---------------------------------------------------------------- arg parsing --
DATE_ARG=""
FORCE=0
WATCH=0
DRYRUN=0
for a in "$@"; do
  case "$a" in
    --force)   FORCE=1 ;;
    --watch)   WATCH=1 ;;
    --dry-run) DRYRUN=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) DATE_ARG="$a" ;;
    *) echo "autodream-now: unknown argument '$a'" >&2; exit 64 ;;
  esac
done

# ----------------------------------------------------- resolve our own location --
# macOS has no `readlink -f`; walk the symlink chain by hand. The helper is
# symlinked into $AUTODREAM_DIR by install.sh, so resolving gets us the real bin/.
resolve() {
  local p="$1" t
  while [ -L "$p" ]; do
    t="$(readlink "$p")"
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(cd "$(dirname "$p")" && pwd)/$t" ;;
    esac
  done
  printf '%s\n' "$p"
}
SELF="$(resolve "${BASH_SOURCE[0]}")"
BIN_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RUN_SH="$BIN_DIR/run.sh"
[ -f "$RUN_SH" ] || { echo "autodream-now: run.sh not found next to $SELF" >&2; exit 70; }

# ------------------------------------------------------------- state locations --
# Defaults mirror run.sh's own defaults; honor the same env overrides so a
# customized install (different AUTODREAM_DIR / DREAMS_DIR) still works.
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.omp/agent/autodream}"
DREAMS_DIR="${DREAMS_DIR:-$HOME/.omp/agent/dreams}"
mkdir -p "$AUTODREAM_DIR/logs"

# Target date: explicit arg, else "yesterday" computed exactly like run.sh does —
# plain system-local BSD date, no TZ override, so we can never disagree with run.sh
# about which day "yesterday" is.
if [ -n "$DATE_ARG" ]; then
  TARGET="$DATE_ARG"
else
  TARGET="$(date -v-1d +%Y-%m-%d)"
fi

# --------------------------------------------------------------- launchd label --
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
# Reuse the base label from the installed scheduled job so the transient label sits
# in the same namespace. Pick the plist that actually runs run.sh — not siblings
# like *-review (review.sh). Otherwise synthesize one.
BASE_LABEL=""
for plist in "$HOME"/Library/LaunchAgents/*autodream*.plist; do
  [ -e "$plist" ] || continue
  case "$plist" in *.ondemand.plist) continue ;; esac
  /usr/bin/grep -q 'run\.sh' "$plist" 2>/dev/null || continue
  if l="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null)"; then
    BASE_LABEL="$l"; break
  fi
done
[ -n "$BASE_LABEL" ] || BASE_LABEL="com.$(id -un | tr -dc 'a-zA-Z0-9').autodream"
LABEL="${BASE_LABEL}.ondemand"
PLIST="$AUTODREAM_DIR/${LABEL}.plist"

# ----------------------------------------------------------------------- PATH --
# launchd agents start with a minimal PATH. Seed it with the dirs of the tools the
# pipeline shells out to (claude, git, bash) plus the usual suspects.
path_dirs=""
for tool in claude git bash; do
  if b="$(command -v "$tool" 2>/dev/null)"; then
    d="$(cd "$(dirname "$b")" && pwd)"
    case ":$path_dirs:" in *":$d:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$d" ;; esac
  fi
done
PATH_VAL="${path_dirs:+$path_dirs:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ------------------------------------------------------ build the plist content --
# EnvironmentVariables: PATH always, plus any path overrides the caller set, plus FORCE.
env_xml="        <key>PATH</key><string>${PATH_VAL}</string>
"
env_xml+="        <key>AUTODREAM_DIR</key><string>${AUTODREAM_DIR}</string>
"
env_xml+="        <key>DREAMS_DIR</key><string>${DREAMS_DIR}</string>
"
[ "$FORCE" = 1 ] && env_xml+="        <key>AUTODREAM_FORCE</key><string>1</string>
"

ONDEMAND_OUT="$AUTODREAM_DIR/logs/ondemand.out.log"
ONDEMAND_ERR="$AUTODREAM_DIR/logs/ondemand.err.log"

read -r -d '' PLIST_BODY <<PLIST || true
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${RUN_SH}</string>
        <string>${TARGET}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
${env_xml}    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>${ONDEMAND_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${ONDEMAND_ERR}</string>
</dict>
</plist>
PLIST

LOG="$AUTODREAM_DIR/logs/run-$TARGET.log"
REPORT="$DREAMS_DIR/$TARGET.md"

if [ "$DRYRUN" = 1 ]; then
  echo "# would write $PLIST :"
  printf '%s\n' "$PLIST_BODY"
  echo
  echo "# would run:"
  echo "launchctl bootout   $DOMAIN/$LABEL   # (ignore failure if not loaded)"
  echo "launchctl bootstrap $DOMAIN $PLIST   # RunAtLoad fires the one-shot run"
  echo "# log:    $LOG"
  echo "# report: $REPORT"
  exit 0
fi

# ------------------------------------------------------------------ go go go --
printf '%s\n' "$PLIST_BODY" > "$PLIST"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST" >/dev/null || { echo "autodream-now: generated plist failed plutil lint" >&2; exit 65; }
fi

# Clear any prior instance, then bootstrap. RunAtLoad is the ONLY trigger — fires the
# one-shot run exactly once. Do NOT also kickstart, or a fast run (e.g. the
# idempotency no-op) would execute twice.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "autodream: launched $LABEL for $TARGET (detached, no time cap)"
echo "  run log: $LOG"
echo "  report:  $REPORT"
echo "  this run's launchd stderr: $ONDEMAND_ERR"

if [ "$WATCH" = 0 ]; then
  echo "Tail it with:  tail -f \"$LOG\""
  exit 0
fi

# --------------------------------------------------------------------- --watch --
echo "Watching (Ctrl-C to stop watching; the run keeps going) ..."
# Wait for the log to materialize.
for _ in $(seq 1 120); do [ -f "$LOG" ] && break; sleep 1; done
[ -f "$LOG" ] || { echo "log never appeared at $LOG; check $ONDEMAND_ERR" >&2; exit 1; }

tail -n +1 -f "$LOG" &
TAIL_PID=$!
trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT

# Poll for the report. Generous ceiling (90 min) since real runs can be long.
deadline=$(( $(date +%s) + 90*60 ))
while :; do
  if [ -s "$REPORT" ]; then
    sleep 1
    echo
    echo "✓ report ready: $REPORT"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo
    echo "gave up watching after 90 min; run may still be going — check $LOG" >&2
    exit 1
  fi
  sleep 5
done
