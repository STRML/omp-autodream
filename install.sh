#!/bin/bash
# cc-autodream installer.
#
# Symlinks the scripts + prompts from this repo into ~/.omp/agent/autodream/ and (on
# macOS) installs the nightly launchd schedule so overnight runs Just Work.
# Idempotent — safe to re-run.
#
# Usage:
#   ./install.sh                 # symlink into $HOME/.omp/agent/ + schedule nightly job
#   ./install.sh /path/to        # symlink into /path/to/autodream/ instead
#   ./install.sh --no-schedule   # symlink only; don't touch launchd
#   ./install.sh -h|--help

set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ----------------------------------------------------------------- arg parsing --
SCHEDULE=1
TARGET_PARENT="$HOME/.omp/agent"
for a in "$@"; do
  case "$a" in
    --no-schedule) SCHEDULE=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "install: unknown flag '$a'" >&2; exit 64 ;;
    *) TARGET_PARENT="$a" ;;
  esac
done
TARGET="$TARGET_PARENT/autodream"

mkdir -p "$TARGET" "$TARGET_PARENT/dreams" "$TARGET/findings" "$TARGET/inbox" "$TARGET/logs"

link() {
  local src="$1" dst="$2"
  # Never create a dangling symlink. A link pointing at a file the checked-out tree
  # does not have looks installed and silently does nothing at 03:15 — that is the
  # overlap-stats.sh failure from 2026-07-24, and it cost a night of data before
  # anyone noticed. Say so loudly and leave the old link alone instead.
  if [ ! -e "$src" ]; then
    echo "  WARNING: skipping $dst — source missing: $src" >&2
    return 0
  fi
  if [ -L "$dst" ] || [ -f "$dst" ]; then
    rm -f "$dst"
  fi
  ln -s "$src" "$dst"
  echo "  $dst -> $src"
}

echo "Installing cc-autodream into $TARGET"
link "$REPO_DIR/bin/run.sh"             "$TARGET/run.sh"
link "$REPO_DIR/bin/autodream-now.sh"   "$TARGET/autodream-now.sh"
link "$REPO_DIR/bin/autodream-note.sh"  "$TARGET/autodream-note.sh"
link "$REPO_DIR/bin/review.sh"          "$TARGET/review.sh"
link "$REPO_DIR/bin/notify.sh"          "$TARGET/notify.sh"
link "$REPO_DIR/bin/make-notifier.sh"   "$TARGET/make-notifier.sh"
link "$REPO_DIR/bin/prune-self-sessions.sh" "$TARGET/prune-self-sessions.sh"
link "$REPO_DIR/bin/slim-transcript.sh"     "$TARGET/slim-transcript.sh"
link "$REPO_DIR/bin/session-stats.sh"        "$TARGET/session-stats.sh"
link "$REPO_DIR/bin/overlap-stats.sh"        "$TARGET/overlap-stats.sh"
link "$REPO_DIR/bin/oversized-gate.sh"       "$TARGET/oversized-gate.sh"
link "$REPO_DIR/bin/cookie-cadence.sh"       "$TARGET/cookie-cadence.sh"
link "$REPO_DIR/bin/vault-notes.sh"          "$TARGET/vault-notes.sh"
link "$REPO_DIR/bin/x-bookmarks.sh"          "$TARGET/x-bookmarks.sh"
link "$REPO_DIR/bin/root-probe.sh"           "$TARGET/root-probe.sh"
link "$REPO_DIR/bin/skills-inventory.sh"     "$TARGET/skills-inventory.sh"
link "$REPO_DIR/prompts/PROMPT.md"      "$TARGET/PROMPT.md"
link "$REPO_DIR/prompts/SESSION_TRIAGE.md" "$TARGET/SESSION_TRIAGE.md"

chmod +x "$REPO_DIR/bin/"*.sh

# --------------------------------------------------- advisor-off overlay --
# OMP boots the opus advisor on every headless compile of a run unless told not to,
# burning subscription budget. run.sh passes the overlay below as --config to every
# worker (env NO_ADVISOR_CFG). Written here once so a fresh install is complete.
cat > "$TARGET/l1-no-advisor.yml" <<'YAML'
advisor:
  enabled: false
  subagents: false
YAML
chmod 644 "$TARGET/l1-no-advisor.yml"

# --------------------------------------------------- session roots --
# autodream scans the OMP session store — a single root, $HOME/.omp/agent/sessions.
# At install time we confirm it and cover any choice bookkeeping in root-choices.conf
# so the nightly run stays unattended. On a non-TTY install (CI, an automated shell),
# unasked roots default to indexed so the install silently covers everything; the log
# line says what was chosen. The SESSION_ROOTS line below is the managed section
# run.sh sources.
if [ -x "$TARGET/root-probe.sh" ]; then
  CONFIG="$TARGET/config"
  if [ -t 1 ]; then
    AUTODREAM_DIR="$TARGET" "$TARGET/root-probe.sh" --ask
  else
    echo "  non-interactive install: indexing any unasked session roots (edit root-choices.conf to change)"
    AUTODREAM_DIR="$TARGET" "$TARGET/root-probe.sh" --default-index
  fi
  # Insert/replace the managed section. A prior line (or lines) under the marker is
  # removed so re-installs converge instead of stacking SESSION_ROOTS definitions.
  if [ -f "$CONFIG" ]; then
    awk '
      /^# claude-folder-indexing/{skip=1; next}
      skip && /^SESSION_ROOTS=/{next}
      skip && /^[^#]/{skip=0}
      {print}
    ' "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  fi
  { echo; AUTODREAM_DIR="$TARGET" "$TARGET/root-probe.sh" --write-config; } >> "$CONFIG"
  echo "  session roots written to $CONFIG (see root-choices.conf to adjust)"
fi

# Build the rebranded "cc-autodream" notifier bundle so open-questions banners show up
# under that name instead of "terminal-notifier". No-op if terminal-notifier isn't
# installed (notify.sh falls back to plain terminal-notifier / an osascript banner) or
# if the bundle already exists. notify.sh also bootstraps this on first run.
AUTODREAM_DIR="$TARGET" "$REPO_DIR/bin/make-notifier.sh" || true

# --------------------------------------------------- nightly launchd schedule --
# Builds and bootstraps a LaunchAgent that runs run.sh on several morning triggers
# (catch-up for a Mac asleep at 03:15; the idempotency guard no-ops all but the
# first to complete). Everything is auto-detected — no REPLACE_WITH_USERNAME edit.
install_schedule() {
  local la_dir="$HOME/Library/LaunchAgents"
  mkdir -p "$la_dir"

  # Reuse an existing autodream label if one is already installed (keeps the
  # namespace stable across re-installs and shared with autodream-now's .ondemand
  # sibling); else synthesize com.<user>.autodream. Match the plist that runs
  # run.sh — not siblings like *-review.
  local label="" plist l
  for plist in "$la_dir"/*autodream*.plist; do
    [ -e "$plist" ] || continue
    case "$plist" in *.ondemand.plist) continue ;; esac
    /usr/bin/grep -q 'run\.sh' "$plist" 2>/dev/null || continue
    if l="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null)"; then
      label="$l"; break
    fi
  done
  [ -n "$label" ] || label="com.$(id -un | tr -dc 'a-zA-Z0-9').autodream"

  # launchd agents start with a minimal PATH; seed it with the dirs of the tools
  # the pipeline shells out to (claude, git, bash) plus the usual suspects.
  local path_dirs="" tool b d
  for tool in claude git bash; do
    if b="$(command -v "$tool" 2>/dev/null)"; then
      d="$(cd "$(dirname "$b")" && pwd)"
      case ":$path_dirs:" in *":$d:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$d" ;; esac
    fi
  done
  local path_val="${path_dirs:+$path_dirs:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  local target_plist="$la_dir/$label.plist"
  local domain
  domain="gui/$(id -u)"

  cat > "$target_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$TARGET/run.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>15</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$path_val</string>
        <key>HOME</key><string>$HOME</string>
        <key>AUTODREAM_DIR</key><string>$TARGET</string>
        <key>DREAMS_DIR</key><string>$TARGET_PARENT/dreams</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$TARGET/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$TARGET/logs/launchd.err.log</string>
</dict>
</plist>
PLIST

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$target_plist" >/dev/null || {
      echo "  ! generated plist failed plutil lint: $target_plist" >&2
      return 1
    }
  fi

  # Clear any prior instance, then bootstrap. RunAtLoad is false, so this arms the
  # schedule without firing a run now.
  launchctl bootout   "$domain/$label" 2>/dev/null || true
  launchctl bootstrap "$domain" "$target_plist"
  echo "  scheduled: $label  (daily 03:15/06:15/09:15/12:15)  -> $target_plist"

  # ---- Review triage LaunchAgent ----
  # Runs review.sh on several morning triggers (catch-up for the same reason as
  # run.sh: a slow run that lands its report after 08:00 still gets its triage
  # popup at the next trigger). review.sh's same-day launch marker (bound to the
  # report mtime) dedups the triggers, so at most one workspace opens per report.
  # Env must carry AUTODREAM_TRIAGE_SURFACE=cmux — the whole point is the popup
  # opening in its own cmux workspace rather than inline in a headless shell.
  #
  # The report to triage is yesterday's (the date run.sh targeted: $DREAMS_DIR/
  # $(date -v-1d).md). review.sh with no date picks the newest report in the dir
  # — which at 08:00 is NOT necessarily yesterday's, it's whatever is newest, so
  # a still-running overnight report sets up the job to triage an OLDER one.
  # Pass yesterday's date explicitly (evaluated at fire time, not install time:
  # the \$(...) is escaped so the plist bakes the expression, not a frozen
  # date). review.sh fails fast with "no autodream report found" if yesterday's
  # hasn't landed yet — a scheduled job must not silently triage the wrong day.
  # The review job MUST have cmux or the whole point (the popup) is moot, and a
  # headless inline fallback would silently run claude with no terminal. Skip
  # provisioning unless cmux is on PATH or sits at review.sh's configured
  # default — on macOS cmux typically installs under /Applications and is NOT
  # on PATH, so the PATH check alone would wrongly skip.
  CMUX_DEFAULT=/Applications/cmux.app/Contents/Resources/bin/cmux
  if ! command -v cmux >/dev/null 2>&1 && [ ! -x "$CMUX_DEFAULT" ]; then
    echo "  ! cmux not found (PATH or $CMUX_DEFAULT); skipping review LaunchAgent"
    return 0
  fi
  local review_label="${label}-review"
  local review_plist="$la_dir/$review_label.plist"
  cat > "$review_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$review_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>exec "$TARGET/review.sh" "\$(date -v-1d +%Y-%m-%d)"</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>15</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$path_val</string>
        <key>HOME</key><string>$HOME</string>
        <key>AUTODREAM_DIR</key><string>$TARGET</string>
        <key>DREAMS_DIR</key><string>$TARGET_PARENT/dreams</string>
        <key>AUTODREAM_TRIAGE_SURFACE</key><string>cmux</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$TARGET/logs/review-launch.out.log</string>
    <key>StandardErrorPath</key>
    <string>$TARGET/logs/review-launch.err.log</string>
</dict>
</plist>
PLIST

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$review_plist" >/dev/null || {
      echo "  ! generated review plist failed plutil lint: $review_plist" >&2
      return 1
    }
  fi
  launchctl bootout   "$domain/$review_label" 2>/dev/null || true
  launchctl bootstrap "$domain" "$review_plist"
  echo "  scheduled: $review_label  (daily 08:00/09:15/12:15)  -> $review_plist"
}

echo
if [ "$SCHEDULE" = 1 ] && command -v launchctl >/dev/null 2>&1; then
  echo "Installing nightly schedule (launchd):"
  install_schedule
  echo
  echo "  Guarantee the Mac is awake for the 03:15 trigger (launchd won't wake it):"
  echo "    sudo pmset repeat wake MTWRFSU 03:10:00"
elif [ "$SCHEDULE" = 1 ]; then
  echo "Skipping schedule: launchctl not found (not macOS?). See launchd/ for the template."
else
  echo "Skipping schedule (--no-schedule). See launchd/com.user.autodream.plist.example to add one."
fi

echo
echo "Installed. Try:"
echo "  $TARGET/run.sh \$(date -v-1d +%Y-%m-%d)   # process yesterday"
echo "  $TARGET/review.sh                        # triage the latest report"
