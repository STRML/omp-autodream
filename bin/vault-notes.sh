#!/usr/bin/env bash
# vault-notes.sh — collect operator notes from every capture surface into one file for L2.
#
# WHY THIS EXISTS
#
# `autodream-note.sh` appends to ~/.claude/autodream/notes.md, which only works from a
# terminal on this Mac. Notes worth leaving for the nightly run mostly occur away from
# the terminal — reading on a phone, mid-meeting, in bed. An Obsidian vault folder syncs
# to the phone and takes a note from anything that can write a file (Obsidian mobile,
# Shortcuts, Drafts, a share sheet), so it is the surface that actually gets used.
#
# Rather than teach PROMPT.md a second hardcoded path, this script merges every surface
# into ONE file — <findings-dir>/operator-notes.md — and the prompt reads only that. New
# capture surfaces are a change here, not a change to the prompt.
#
# THE ARCHIVE STEP IS WHY THERE IS A MANIFEST
#
# Inbox files are moved to processed/ after a successful report, so the inbox stays a
# to-do list rather than an ever-growing pile. `collect` records exactly which files it
# read into a manifest, and `archive` moves only those. Without the manifest, a note
# written during the ~10 minutes a run takes would be archived unread — silently losing
# the one note the user cared enough to write mid-run.
#
# ICLOUD DATALESS FILES
#
# The vault lives in iCloud Drive. macOS evicts file contents under storage pressure and
# leaves a `.<name>.icloud` placeholder; reading one returns nothing useful. launchd fires
# at 03:15 when nothing has touched the vault for hours, which is exactly when eviction
# has had time to happen. `materialize()` asks brctl to download the inbox and waits for
# the placeholders to clear, with a cap so a broken iCloud daemon costs seconds, not the
# run. If a note is still dataless after the wait it is reported in the output file rather
# than silently skipped — a note the user wrote and we could not read is worth saying.
#
# Every path here is best-effort: a missing vault, an unreadable file, a failed move are
# all logged into the output and never abort the caller. Nothing about leaving notes is
# worth losing a night's report over.
#
# Usage:
#   vault-notes.sh collect <findings-dir>   # write operator-notes.md + manifest
#   vault-notes.sh archive <findings-dir>   # move consumed inbox files to processed/
#   vault-notes.sh publish <report-path>    # copy the report into the vault for phone reading
#   vault-notes.sh status                   # print what is configured and what is pending
#
# Config (env overrides these; run.sh sources ~/.claude/autodream/config first):
#   AUTODREAM_DIR        default $HOME/.claude/autodream
#   AUTODREAM_VAULT_DIR  the autodream folder inside your vault. EMPTY = vault surface off,
#                        notes.md still works. Layout created on demand:
#                          <vault>/inbox/*.md          drop notes here
#                          <vault>/processed/<date>/   consumed notes land here
#                          <vault>/reports/<date>.md   the nightly report, for phone reading
#   AUTODREAM_NOTES_FILE default $AUTODREAM_DIR/notes.md
#   AUTODREAM_ICLOUD_WAIT seconds to wait for dataless files to materialize   default 30
set -euo pipefail

# Resolve the install dir from our own location, the same idiom as run.sh,
# notify.sh, review.sh and autodream-note.sh. Hardcoding a default here made the
# reader disagree with the writer whenever this ran outside run.sh's exported
# environment: `vault-notes.sh status`, the command whose whole job is to say
# whether the note surface is wired, reported a file the writer never touches.
# BASH_SOURCE is deliberately NOT symlink-resolved - install.sh symlinks this
# into $TARGET, so the link's own directory IS the install dir.
AUTODREAM_DIR="${AUTODREAM_DIR:-}"
if [ -z "$AUTODREAM_DIR" ]; then
  AUTODREAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -z "$AUTODREAM_DIR" ] || { [ ! -f "$AUTODREAM_DIR/config" ] && [ ! -f "$AUTODREAM_DIR/l1-no-advisor.yml" ]; }; then
    AUTODREAM_DIR="$HOME/.claude/autodream"
  fi
fi

# Source the config here too, not only in run.sh. `status` exists to be run by hand, and
# a status command that reports "vault: not configured" about a vault the user configured
# is worse than no status command. Double-sourcing is harmless: run.sh has already
# exported these by the time it calls us, and the snapshot replay makes the environment
# win either way.
# `set +u` around the source for the same reason run.sh does it: this script runs under
# nounset, and a single typo'd variable reference in the user-edited config would
# otherwise abort it outright — turning a harmless config typo into a night with no
# operator notes. run.sh already warns about the typo; staying quiet here avoids printing
# the same complaint twice per run.
AUTODREAM_CONFIG="${AUTODREAM_CONFIG:-$AUTODREAM_DIR/config}"
if [ -f "$AUTODREAM_CONFIG" ]; then
  _env_snapshot=$(export -p)
  set +u
  set -a
  # shellcheck disable=SC1090
  . "$AUTODREAM_CONFIG" 2>/dev/null || true
  set +a
  set -u
  eval "$_env_snapshot"
  unset _env_snapshot
fi

VAULT_DIR="${AUTODREAM_VAULT_DIR:-}"
NOTES_FILE="${AUTODREAM_NOTES_FILE:-$AUTODREAM_DIR/notes.md}"
ICLOUD_WAIT="${AUTODREAM_ICLOUD_WAIT:-30}"

TODAY="$(date +%F)"

# ---- helpers ----

# Each returns the empty string when no vault is configured. The explicit `return 0`
# is load-bearing: without it the function inherits the failed `[ -n ]` status, and
# `dir="$(inbox_dir)"` then aborts the whole script under `set -e` — which is exactly
# the no-vault case, the most common one.
inbox_dir()     { [ -n "$VAULT_DIR" ] && printf '%s/inbox' "$VAULT_DIR"; return 0; }
processed_dir() { [ -n "$VAULT_DIR" ] && printf '%s/processed' "$VAULT_DIR"; return 0; }
reports_dir()   { [ -n "$VAULT_DIR" ] && printf '%s/reports' "$VAULT_DIR"; return 0; }

# Create the vault layout. Doing this on every run means the user never has to make the
# folders by hand — pointing AUTODREAM_VAULT_DIR at a path is the whole setup.
ensure_vault() {
  [ -n "$VAULT_DIR" ] || return 0
  mkdir -p "$(inbox_dir)" "$(processed_dir)" "$(reports_dir)" 2>/dev/null || true
}

# Ask iCloud to materialize the inbox, then wait for the placeholders to clear.
# `brctl download` is advisory and returns immediately, so the wait loop is the part
# that matters. Absent brctl (non-macOS, or a stripped system) we just proceed — the
# read will either work or the file gets reported as unreadable.
materialize() {
  local dir="$1" waited=0
  [ -d "$dir" ] || return 0
  # Both are asked, because neither is reliable alone. `brctl download` predates the
  # FileProvider migration (Monterey) and on a current system it frequently succeeds
  # while doing nothing at all, which would leave the wait loop below as the only
  # mechanism — a passive timeout dressed up as a fetch. `fileproviderctl materialize`
  # is the FileProvider-era equivalent and is what actually pulls the file down on
  # modern macOS. Keep brctl for older systems; neither failing is an error.
  command -v brctl >/dev/null 2>&1 && brctl download "$dir" >/dev/null 2>&1 || true
  command -v fileproviderctl >/dev/null 2>&1 && fileproviderctl materialize "$dir" >/dev/null 2>&1 || true
  while [ "$waited" -lt "$ICLOUD_WAIT" ]; do
    # Placeholders are dot-prefixed siblings ending in .icloud; no placeholder means
    # every file in the directory has its contents locally.
    if ! find "$dir" -maxdepth 1 -name '.*.icloud' -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  return 0
}

# A note file may carry YAML frontmatter with `expires: YYYY-MM-DD`. Expired notes are
# dropped at collect time rather than passed through, so PROMPT.md keeps exactly one
# expiry format to reason about (the `- [date] (expires DATE)` lines in notes.md).
note_expiry() {
  awk '
    NR==1 && $0 != "---" { exit }
    NR>1 && $0 == "---"  { exit }
    /^[Ee]xpires:[[:space:]]*/ { sub(/^[Ee]xpires:[[:space:]]*/, ""); gsub(/[[:space:]]|"|'"'"'/, ""); print; exit }
  ' "$1" 2>/dev/null
}

# Strip the frontmatter block so the model reads the note, not our bookkeeping.
note_body() {
  awk 'NR==1 && $0=="---" { fm=1; next } fm && $0=="---" { fm=0; next } !fm { print }' "$1" 2>/dev/null
}

# ---- collect ----

collect() {
  local findings="$1"
  [ -n "$findings" ] || { echo "usage: vault-notes.sh collect <findings-dir>" >&2; exit 2; }
  mkdir -p "$findings"
  local out="$findings/operator-notes.md"
  local manifest="$findings/vault-notes-manifest.txt"
  : > "$manifest"

  ensure_vault

  # Expiry is judged against the date being REPORTED ON, not against now. Rebuilding an
  # old date (or a launchd catch-up re-running a missed night days later) would otherwise
  # drop and archive every note whose expiry fell between that date and today, even
  # though those notes were active for the window in question. The findings dir is named
  # for the date; anything else (tests, an ad-hoc dir) falls back to today.
  local report_date; report_date="$(basename "$findings")"
  case "$report_date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) report_date="$TODAY" ;;
  esac

  local active=0 expired=0 unreadable=0
  local body; body="$(mktemp)"
  trap 'rm -f "$body"' RETURN

  # Surface 1: the terminal-written notes file. Passed through verbatim — its
  # `- [added] (expires DATE) text` lines are the format PROMPT.md already parses,
  # and expiry filtering for those stays in the prompt where it has always lived.
  if [ -s "$NOTES_FILE" ]; then
    local lines
    # NOT `$(grep -c ... || echo 0)`. With zero matches grep -c prints 0 AND exits 1, so
    # the `||` fires too and the substitution captures the two-line string "0\n0"; the
    # arithmetic below then dies and `set -e` takes the whole collect down, writing no
    # operator-notes.md at all. That input is not hypothetical — it is exactly what
    # notes.md looks like once the user deletes the notes a report told them were
    # addressed, leaving only the header autodream-note.sh writes.
    lines=$(grep -c '^- \[' "$NOTES_FILE" 2>/dev/null) || true
    [ -n "$lines" ] || lines=0
    {
      printf '## From %s\n\n' "$NOTES_FILE"
      cat "$NOTES_FILE"
      printf '\n'
    } >> "$body"
    active=$(( active + lines ))
  fi

  # Surface 2: the vault inbox. One file per note, newest last so the model reads them
  # in the order they were written.
  local inbox; inbox="$(inbox_dir)"
  if [ -n "$inbox" ] && [ -d "$inbox" ]; then
    materialize "$inbox"
    local f
    # -s skips zero-byte files, which is what a still-dataless note looks like after a
    # failed materialize; those are counted separately below.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ! -r "$f" ] || [ ! -s "$f" ]; then
        unreadable=$(( unreadable + 1 ))
        printf '## note: %s — UNREADABLE\n\nThis note file exists in the vault inbox but had no readable content at run time (likely an iCloud file whose contents were not downloaded within %ss). It has been LEFT IN THE INBOX for the next run. Mention it in the Operator notes section so the user knows a note was missed.\n\n' \
          "$(basename "$f")" "$ICLOUD_WAIT" >> "$body"
        continue
      fi

      local exp; exp="$(note_expiry "$f")"
      if [ -n "$exp" ] && [ "$exp" \< "$report_date" ]; then
        expired=$(( expired + 1 ))
        # Still archived: an expired note has done its job and should leave the inbox.
        printf '%s\n' "$f" >> "$manifest"
        continue
      fi

      local added; added=$(date -r "$f" +%F 2>/dev/null || echo "$TODAY")
      {
        printf '## note: %s\n' "$(basename "$f" .md)"
        printf -- '- [%s]%s\n\n' "$added" "$([ -n "$exp" ] && printf ' (expires %s)' "$exp")"
        note_body "$f"
        printf '\n'
      } >> "$body"
      printf '%s\n' "$f" >> "$manifest"
      active=$(( active + 1 ))
    done < <(find "$inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

    # An iCloud-evicted note is NOT a zero-byte `foo.md`. macOS replaces the file
    # outright with a dot-prefixed `.foo.md.icloud` placeholder, so the `*.md` walk above
    # matches nothing at all and the UNREADABLE branch inside it — written for exactly
    # this case — can never fire. Left unhandled, a note the user wrote from their phone
    # is reported as `unreadable: 0`, which reads as "nothing was missed". That is the
    # failure the repo's degraded-measurements-must-say-so rule exists to prevent, so the
    # placeholders get their own pass. They are deliberately NOT manifested: the note has
    # not been read, so it must stay in the inbox for the next run to retry.
    local ph name
    while IFS= read -r ph; do
      [ -n "$ph" ] || continue
      name="$(basename "$ph")"; name="${name#.}"; name="${name%.icloud}"
      # Skip a placeholder whose real file also materialised — the loop above already
      # handled it, and counting both would overstate the miss.
      [ -e "$inbox/$name" ] && continue
      unreadable=$(( unreadable + 1 ))
      printf '## note: %s — UNREADABLE\n\nThis note exists in the vault inbox but iCloud had not downloaded its contents within %ss, so it could not be read this run. It has been LEFT IN THE INBOX and will be retried. Mention it by name in the Operator notes section so the user knows a note they wrote was missed, and do not guess at its contents.\n\n' \
        "$name" "$ICLOUD_WAIT" >> "$body"
    done < <(find "$inbox" -maxdepth 1 -name '.*.icloud' 2>/dev/null | sort)
  fi

  {
    printf '# Operator notes for %s\n' "$(basename "$findings")"
    printf '# collected %s from: %s%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$NOTES_FILE" \
      "$([ -n "$inbox" ] && printf ', %s' "$inbox")"
    printf '# active: %s   expired-and-dropped: %s   unreadable: %s\n\n' "$active" "$expired" "$unreadable"
    if [ "$active" -eq 0 ] && [ "$unreadable" -eq 0 ]; then
      printf 'No active operator notes.\n'
    else
      cat "$body"
    fi
  } > "$out"

  echo "operator notes: $active active, $expired expired, $unreadable unreadable -> $out"
}

# ---- archive ----

archive() {
  local findings="$1"
  [ -n "$findings" ] || { echo "usage: vault-notes.sh archive <findings-dir>" >&2; exit 2; }
  local manifest="$findings/vault-notes-manifest.txt"
  [ -s "$manifest" ] || { echo "no vault notes to archive"; return 0; }

  local dest; dest="$(processed_dir)/$(basename "$findings")"
  mkdir -p "$dest" 2>/dev/null || { echo "could not create $dest; leaving notes in the inbox"; return 0; }

  local moved=0 f target
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    target="$dest/$(basename "$f")"
    # A note reused across dates (same filename, archived twice) must not clobber the
    # earlier copy; suffix with a counter rather than losing history.
    if [ -e "$target" ]; then
      local n=2
      while [ -e "${target%.md}-$n.md" ]; do n=$(( n + 1 )); done
      target="${target%.md}-$n.md"
    fi
    mv "$f" "$target" 2>/dev/null && moved=$(( moved + 1 )) || echo "  could not move $f (left in inbox)"
  done < "$manifest"
  echo "archived $moved vault note(s) -> $dest"
}

# ---- publish ----

publish() {
  local report="$1"
  [ -n "$report" ] || { echo "usage: vault-notes.sh publish <report-path>" >&2; exit 2; }
  [ -s "$report" ] || { echo "no report to publish"; return 0; }
  local rdir; rdir="$(reports_dir)"
  [ -n "$rdir" ] || { echo "no vault configured; not publishing"; return 0; }
  mkdir -p "$rdir" 2>/dev/null || { echo "could not create $rdir; not publishing"; return 0; }
  if cp "$report" "$rdir/$(basename "$report")" 2>/dev/null; then
    echo "published report -> $rdir/$(basename "$report")"
  else
    echo "could not publish report to $rdir (continuing)"
  fi
}

# ---- status ----

status() {
  # Same `grep -c` trap collect() hit: zero matches print 0 AND exit 1, so a `|| echo 0`
  # fallback fires as well and the count becomes "0\n0". Harmless here (status only
  # prints it) but it printed nonsense on exactly the header-only notes.md that broke
  # collect, which is the confusing case to be looking at status for.
  local n; n=$(grep -c '^- \[' "$NOTES_FILE" 2>/dev/null) || true
  [ -n "${n:-}" ] || n=0
  printf 'notes file:  %s%s\n' "$NOTES_FILE" "$([ -s "$NOTES_FILE" ] && printf ' (%s line notes)' "$n" || printf ' (absent/empty)')"
  if [ -z "$VAULT_DIR" ]; then
    printf 'vault:       not configured (set AUTODREAM_VAULT_DIR in %s/config)\n' "$AUTODREAM_DIR"
    return 0
  fi
  printf 'vault:       %s%s\n' "$VAULT_DIR" "$([ -d "$VAULT_DIR" ] && printf '' || printf ' (does not exist yet — created on next run)')"
  local inbox; inbox="$(inbox_dir)"
  if [ -d "$inbox" ]; then
    printf 'inbox:       %s pending note(s)\n' "$(find "$inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    local stuck
    stuck=$(find "$inbox" -maxdepth 1 -name '.*.icloud' 2>/dev/null | wc -l | tr -d ' ')
    [ "$stuck" -gt 0 ] && printf 'icloud:      %s file(s) not downloaded locally\n' "$stuck"
  else
    printf 'inbox:       not created yet\n'
  fi
}

case "${1:-}" in
  collect) shift; collect "${1:-}" ;;
  archive) shift; archive "${1:-}" ;;
  publish) shift; publish "${1:-}" ;;
  status)  status ;;
  *) echo "usage: vault-notes.sh {collect <findings-dir>|archive <findings-dir>|publish <report>|status}" >&2; exit 2 ;;
esac
