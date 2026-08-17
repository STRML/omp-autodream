#!/bin/bash
# Emit the ACTIVE on-disk skill surface as a per-line inventory for Layer 2.
#
# The L2 prompt treats the output file as the authoritative active-skill list. Two
# classes are excluded: skills named in ~/.omp/agent/config.yml `skills.ignoredSkills`
# (a YAML block list under `ignoredSkills:`, items are plain scalars after `- ` on
# indented lines) and on-disk skills whose SKILL.md frontmatter sets `enabled: false`.
# The built-in binary skills (compiled into the omp binary) and project-local
# `.claude/skills` are not enumerable from the runner and are deliberately absent —
# reconcile those against the session skill surface instead.
#
# Usage: bin/skills-inventory.sh <outfile>
#   <outfile>  inventory destination: 4 header lines, then one `name<TAB>description`
#              line per active SKILL.md (name = frontmatter `name:` else the directory
#              basename; description = frontmatter `description:` value, first line).
# Exits 1 (usage) when <outfile> is missing; otherwise exits 0 even with zero skills
# found — an unusable inventory must never fail the caller. Read-only; uses $HOME
# throughout, never expands `~`.

set -u

outfile="${1:-}"
if [ -z "$outfile" ]; then
  echo "usage: $0 <outfile>" >&2
  exit 1
fi

# ---- 1. OMP-disabled skill names (skills.ignoredSkills) ---------------------------
# YAML block list under `ignoredSkills:`; items are `- name-scalar` on indented
# lines. The block ends at the first column-zero non-blank line (or EOF). Config may
# be absent -> empty ignore set.
ignored=""
if [ -r "$HOME/.omp/agent/config.yml" ]; then
  in_block=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"ignoredSkills:"*) in_block=1 ; continue ;;
    esac
    [ "$in_block" = 1 ] || continue
    if [ -n "${line%%[![:space:]]*}" ]; then         # indented or blank: still in block
      case "$line" in
        *"- "*)
          item="${line#*-}"
          item="${item#"${item%%[![:space:]]*}"}"    # strip leading whitespace
          item="${item%"${item##*[![:space:]]}"}"    # strip trailing whitespace
          item="${item%\"}"; item="${item#\"}"       # strip double quotes
          item="${item%\'}"; item="${item#\'}"       # strip single quotes
          [ -n "$item" ] && ignored="$ignored
$item"
          ;;
      esac
    else
      in_block=0                                     # column-zero line: block over
    fi
  done < "$HOME/.omp/agent/config.yml"
fi

in_ignored() {                                       # $1=name ; exact membership
  local name="$1" item
  [ -n "$ignored" ] || return 1
  while IFS= read -r item; do
    [ "$name" = "$item" ] && return 0
  done <<< "$ignored"
  return 1
}

# ---- 2. Frontmatter reader ---------------------------------------------------------
# Reads the YAML frontmatter of one SKILL.md (file head up to the closing `---`) into
# FM_NAME / FM_DESC / FM_ENABLED. description may be single-line or folded (`>` / `|`):
# in the folded case take the first value line. `enabled: false` flips FM_ENABLED to 0.
read_frontmatter() {
  local f="$1" line rest rest_nw in_fm=0 desc_pending=0
  FM_NAME=""; FM_DESC=""; FM_ENABLED=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_fm" = 0 ]; then
      [ "$line" = "---" ] && in_fm=1
      continue
    fi
    [ "$line" = "---" ] && break                      # closing frontmatter
    if [ "$desc_pending" = 1 ]; then                  # folded description: first value line
      case "$line" in
        "") : ;;
        *)
          FM_DESC="${line#"${line%%[![:space:]]*}"}"
          FM_DESC="${FM_DESC%"${FM_DESC##*[![:space:]]}"}"
          desc_pending=0
          ;;
      esac
      continue
    fi
    case "$line" in
      name:*)
        FM_NAME="${line#name:}"
        FM_NAME="${FM_NAME#"${FM_NAME%%[![:space:]]*}"}"
        FM_NAME="${FM_NAME%"${FM_NAME##*[![:space:]]}"}"
        FM_NAME="${FM_NAME%\"}"; FM_NAME="${FM_NAME#\"}"
        FM_NAME="${FM_NAME%\'}"; FM_NAME="${FM_NAME#\'}"
        ;;
      description:*)
        rest="${line#description:}"
        rest_nw="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest_nw" in
          ""|">"*|"|"*) FM_DESC=""; desc_pending=1 ;;
          *)
            FM_DESC="${rest_nw%"${rest_nw##*[![:space:]]}"}"
            FM_DESC="${FM_DESC%\"}"; FM_DESC="${FM_DESC#\"}"
            FM_DESC="${FM_DESC%\'}"; FM_DESC="${FM_DESC#\'}"
            ;;
        esac
        ;;
      enabled:*)
        case "$line" in
          *"false"*) FM_ENABLED=0 ;;
        esac
        ;;
    esac
  done < "$f"
}

# ---- 3. Emit ----------------------------------------------------------------------
mkdir -p "$(dirname "$outfile")" 2>/dev/null || true
{
  printf '# skills-inventory.txt — authoritative active on-disk skill list for L2 (write: bin/skills-inventory.sh)\n'
  printf '# Lines: name<TAB>description. Excludes skills.ignoredSkills and frontmatter `enabled: false`.\n'
  printf '# Built-in binary skills are compiled into the omp binary and are NOT listed — reconcile via the session skill surface.\n'
  printf '# Project-local .claude/skills are NOT enumerable from the runner; absence here is not absence.\n'
} > "$outfile"

for skill in \
  "$HOME/.claude/skills"/*/SKILL.md \
  "$HOME/.agents/skills"/*/SKILL.md \
  "$HOME/.config/opencode/skills"/*/SKILL.md \
  "$HOME/.claude/plugins"/*/skills/*/SKILL.md \
  "$HOME/.omp/agent/managed-skills"/*/SKILL.md; do
  [ -f "$skill" ] || continue
  read_frontmatter "$skill"
  [ "$FM_ENABLED" = 1 ] || continue
  name="$FM_NAME"
  [ -n "$name" ] || name="$(basename "$(dirname "$skill")")"
  in_ignored "$name" && continue
  printf '%s\t%s\n' "$name" "$FM_DESC" >> "$outfile"
done

exit 0
