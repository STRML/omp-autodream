#!/bin/bash
# Emit the ACTIVE on-disk skill surface as a per-line inventory for Layer 2.
#
# The L2 prompt treats the output file as the authoritative active-skill list. Two
# classes are excluded: skills named in ~/.omp/agent/config.yml `skills.ignoredSkills`
# (a YAML block list under `ignoredSkills:`, items are plain scalars after `- ` on
# lines indented deeper than the key) and on-disk skills whose SKILL.md frontmatter
# sets `enabled:` to a false-family value. The built-in binary skills (compiled into
# the omp binary) and project-local `.claude/skills` are not enumerable from the
# runner and are deliberately absent — reconcile those against the session skill
# surface instead.
#
# Corpus: every `$HOME/.claude*` bucket that exists (top-level `skills/*/SKILL.md`
# plus plugin skills found recursively under `plugins/`), and the standalone
# `$HOME/.agents/skills`, `$HOME/.config/opencode/skills`, and
# `$HOME/.omp/agent/managed-skills` roots. Missing roots are normal — an empty scan
# still writes a valid (header-only) inventory. Names are deduplicated: first
# occurrence wins.
#
# Usage: bin/skills-inventory.sh <outfile>
#   <outfile>  inventory destination: 4 header lines, then one `name<TAB>description`
#              line per active SKILL.md (name = frontmatter `name:` — block scalars
#              resolve to their first value line — else the directory basename;
#              description = frontmatter `description:` value, folded blocks joined
#              with single spaces).
# Exits 1 (usage) when <outfile> is missing, or when the inventory cannot be
# produced at <outfile> (unwritable dir) — the caller's `||` fallback then writes an
# unavailable sentinel. Exits 0 on any successful emit, including zero skills found.
# Read-only; uses $HOME throughout, never expands `~`.

set -u

outfile="${1:-}"
if [ -z "$outfile" ]; then
  echo "usage: $0 <outfile>" >&2
  exit 1
fi

# ---- 1. OMP-disabled skill names (skills.ignoredSkills) ---------------------------
# YAML block list under `ignoredSkills:`. Rules honored exactly:
#   - only items indented DEEPER than the `ignoredSkills:` key line are list items;
#   - blank lines INSIDE the block keep parsing;
#   - a same-or-less-indented non-blank line (a sibling key) ends the block;
#   - inline comments (`- skill # note` -> `skill`) and surrounding quotes are
#     stripped from each item.
# Config may be absent -> empty ignore set. python3 is the primary parser (present
# on macOS); a strict awk implementation is the fallback; neither present is the
# only case that degrades to "no ignores", and it logs that on stderr.
CLEAN_ITEM='sub(/[ \t]+#.*$/, "", item); gsub(/^[ \t]+|[ \t]+$/, "", item);
if (length(item) >= 2 && substr(item,1,1) == "\"") { if (substr(item,length(item),1) == "\"") item = substr(item, 2, length(item) - 2) }
else if (length(item) >= 2 && substr(item,1,1) == "\047") { if (substr(item,length(item),1) == "\047") item = substr(item, 2, length(item) - 2) }
if (item != "") print item'
ignored=""
CONF="$HOME/.omp/agent/config.yml"
if [ -r "$CONF" ]; then
  if command -v python3 >/dev/null 2>&1; then
    ignored="$(IGNORED_SKILLS_CONF="$CONF" python3 - <<'PY' 2>/dev/null || true
import os, re
try:
    lines = open(os.environ.get("IGNORED_SKILLS_CONF", ""), "r", encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit(0)
key_indent = -1
in_block = False
for raw in lines:
    if not in_block:
        stripped = raw.lstrip(" \t")
        if stripped.startswith("ignoredSkills:"):
            key_indent = len(raw) - len(stripped)
            in_block = True
        continue
    if not raw.strip():
        continue                      # blank line inside the block keeps parsing
    indent = len(raw) - len(raw.lstrip(" \t"))
    if indent <= key_indent:
        in_block = False              # sibling key at same-or-less indent ends the block
        continue
    s = raw.lstrip(" \t")
    if not s.startswith("- "):
        continue
    item = s[2:]
    item = re.sub(r"[ \t]+#.*$", "", item)   # inline comment
    item = item.strip()
    if len(item) >= 2 and item[0] == item[-1] and item[0] in ('"', "'"):
        item = item[1:-1]
    if item:
        print(item)
PY
)"
  elif command -v awk >/dev/null 2>&1; then
    ignored="$(awk '
      BEGIN { in_block = 0; key_indent = -1 }
      {
        if (!in_block) {
          st = $0; sub(/^[ \t]+/, "", st)
          if (st ~ /^ignoredSkills:/) { in_block = 1; key_indent = index($0, st) - 1 }
          next
        }
        st = $0; sub(/^[ \t]+/, "", st)
        if (st == "") next                          # blank inside block keeps parsing
        indent = index($0, st) - 1
        if (indent <= key_indent) { in_block = 0; next }   # sibling key ends the block
        if (st ~ /^- /) {
          item = st; sub(/^- /, "", item)
          '"$CLEAN_ITEM"'
        }
      }
    ' "$CONF" 2>/dev/null || true)"
  else
    echo "skills-inventory.sh: no python3/awk for ignoredSkills parse; treating ignore list as empty" >&2
  fi
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
# FM_NAME / FM_DESC / FM_ENABLED.
#   name:  single line, or a block scalar (`>`, `>-`, `|`, `|-`) whose value is the
#          first following indented line; a name left empty resolves to the caller's
#          directory-basename fallback.
#   description: single line, or a folded block (`>`/`>-`): all following
#          more-indented lines joined with single spaces.
#   enabled: only a false-family value (false, False, 0, no) disables the skill.
# Parsing stops at the closing frontmatter delimiter.
read_frontmatter() {
  local f="$1" line lspace line_nw in_fm=0 desc_block=0 pending_name=0 rest rest_nw
  FM_NAME=""; FM_DESC=""; FM_ENABLED=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_fm" = 0 ]; then
      [ "$line" = "---" ] && in_fm=1
      continue
    fi
    [ "$line" = "---" ] && break

    lspace=""; line_nw=""
    case "$line" in
      *[![:space:]]*)
        lspace="${line%%[![:space:]]*}"
        line_nw="${line#"$lspace"}"
        ;;
    esac

    # A pending block-scalar name takes the first following indented (content) line.
    if [ "$pending_name" = 1 ]; then
      [ -n "$line_nw" ] || continue                 # blank: keep waiting
      if [ -z "$lspace" ]; then
        pending_name=0                              # column-0 line: no folded value -> fallback
      else
        FM_NAME="$line_nw"
        pending_name=0
      fi
      continue
    fi

    # A folded description joins every following more-indented line; a column-0 line
    # ends the fold and is then processed as a normal key below.
    if [ "$desc_block" = 1 ]; then
      case "$line" in
        "") continue ;;                             # blank inside the fold
        *[![:space:]]*)
          if [ -n "$lspace" ]; then
            [ -n "$FM_DESC" ] && FM_DESC="$FM_DESC "
            FM_DESC="$FM_DESC$line_nw"
            continue
          fi
          desc_block=0                              # column-0 line ends the fold
          ;;
      esac
    fi

    case "$line" in
      name:*)
        rest="${line#name:}"
        rest_nw="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest_nw" in
          ">"|">-"|"|"|"|-") pending_name=1 ;;
          *)
            FM_NAME="${rest_nw%"${rest_nw##*[![:space:]]}"}"
            FM_NAME="${FM_NAME%\"}"; FM_NAME="${FM_NAME#\"}"
            FM_NAME="${FM_NAME%\'}"; FM_NAME="${FM_NAME#\'}"
            ;;
        esac
        ;;
      description:*)
        rest="${line#description:}"
        rest_nw="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest_nw" in
          ">"|">-"|"|"|"|-") FM_DESC=""; desc_block=1 ;;
          *)
            FM_DESC="${rest_nw%"${rest_nw##*[![:space:]]}"}"
            FM_DESC="${FM_DESC%\"}"; FM_DESC="${FM_DESC#\"}"
            FM_DESC="${FM_DESC%\'}"; FM_DESC="${FM_DESC#\'}"
            ;;
        esac
        ;;
      enabled:*)
        rest="${line#enabled:}"
        rest_nw="${rest#"${rest%%[![:space:]]*}"}"
        rest_nw="${rest_nw%%[[:space:]]*}"          # first token (drops inline comment)
        rest_nw="${rest_nw%\"}"; rest_nw="${rest_nw#\"}"
        rest_nw="${rest_nw%\'}"; rest_nw="${rest_nw#\'}"
        case "$rest_nw" in
          false|False|0|no) FM_ENABLED=0 ;;
        esac
        ;;
    esac
  done < "$f"
}

# ---- 3. Emit (temp file in the outfile's dir, then an atomic rename) ---------------
emitted=""
already_emitted() {                                  # $1=name ; first occurrence wins
  local name="$1" e
  [ -n "$emitted" ] || return 1
  while IFS= read -r e; do
    [ "$name" = "$e" ] && return 0
  done <<< "$emitted"
  return 1
}

scan_skill() {                                       # $1=path to SKILL.md ; emit if active
  local s="$1" name
  [ -f "$s" ] || return 0
  read_frontmatter "$s"
  [ "$FM_ENABLED" = 1 ] || return 0
  name="$FM_NAME"
  case "$name" in
    ">"|">-"|"|"|"|-") name="" ;;
  esac
  [ -n "$name" ] || name="$(basename "$(dirname "$s")")"
  in_ignored "$name" && return 0
  already_emitted "$name" && return 0
  emitted="$emitted
$name"
  printf '%s\t%s\n' "$name" "$FM_DESC"
}

outdir="$(dirname "$outfile")"
mkdir -p "$outdir" 2>/dev/null || true
tmpfile="$(mktemp "$outdir/skills-inventory.XXXXXX" 2>/dev/null)" || {
  echo "skills-inventory.sh: cannot create a temp inventory in $outdir (unwritable?)" >&2
  exit 1
}

{
  printf '# skills-inventory.txt — authoritative active on-disk skill list for L2 (write: bin/skills-inventory.sh)\n'
  printf '# Lines: name<TAB>description. Excludes skills.ignoredSkills and frontmatter `enabled: false`.\n'
  printf '# Scanned: every $HOME/.claude* bucket (user skills + plugin skills) plus agent/opencode/OMP managed roots; deduplicated by name, first wins.\n'
  printf '# Built-in binary skills are compiled into the omp binary and are NOT listed — reconcile via the session skill surface.\n'

  # Standalone roots first.
  for root in "$HOME/.agents/skills" "$HOME/.config/opencode/skills" "$HOME/.omp/agent/managed-skills"; do
    for s in "$root"/*/SKILL.md; do
      scan_skill "$s"
    done
  done

  # Corpus buckets: every existing `$HOME/.claude*` directory. Quote the glob so it
  # expands to buckets (~/.claude, ~/.claude-ds4, ...) without the shell mangling it.
  for bucket in "$HOME"/.claude*; do
    [ -d "$bucket" ] || continue
    for s in "$bucket/skills"/*/SKILL.md; do
      scan_skill "$s"
    done
    if [ -d "$bucket/plugins" ]; then
      # Plugin skills live at arbitrary depth; `find` + `-path` beats a `*` glob that
      # cannot cross `/`.
      while IFS= read -r s; do
        scan_skill "$s"
      done < <(find "$bucket/plugins" -maxdepth 8 -path '*/skills/*/SKILL.md' -type f 2>/dev/null)
    fi
  done
} > "$tmpfile"

if [ -f "$tmpfile" ] && mv -f "$tmpfile" "$outfile"; then
  exit 0
fi
echo "skills-inventory.sh: could not produce $outfile" >&2
rm -f "$tmpfile"
exit 1
