#!/usr/bin/env bash
# x-bookmarks.sh — pull recent X bookmarks so the aggregator can turn them into ideas.
#
# WHY NOT THE OFFICIAL API
#
# `GET /2/users/:id/bookmarks` has never been on X's free tier and needs Basic at
# $200/mo (checked 2026-08-02). So this speaks to the same internal web GraphQL
# endpoint the bookmarks page itself calls, authenticated with cookies the user pastes
# in once. That is the only mechanism that works, which is also why every browser
# extension in this space does the same thing.
#
# GROUNDING
#
# The request contract below — endpoint shape, bearer token, headers, `features` and
# `fieldToggles` payloads, the queryId discovery walk, and the response path — was taken
# on 2026-08-02 from displace-agency/x-bookmarks-exporter (src/api.ts), a working
# implementation, not from guesswork. Two things there are worth knowing when it breaks:
#
#   * The queryId in the URL path rotates whenever X deploys, so it is scraped from the
#     live JS bundle rather than hardcoded, and cached for a day.
#   * A wrong/stale `features` object comes back as HTTP 400 with a body that NAMES the
#     missing feature flags. That error text is self-documenting: read it and add the
#     named keys to FEATURES below. Do not go hunting.
#
# WHY IT CANNOT FAIL LOUDLY
#
# This runs inside the nightly pipeline. X changing a bundle path at 3am must not cost a
# night's report, so every path here exits 0 and always writes the output file — the
# failure IS the content, reported to the model as a `# x-bookmarks: fetch failed` header
# that PROMPT.md knows how to render. Nothing about a bookmark is worth an exit code.
#
# READ STATE
#
# `collect` merges the fetch into seen.jsonl and then emits every entry still carrying a
# null `read_on` — not just the ones this fetch returned. That matters after a failed
# run: the bookmarks were already recorded as seen (so incremental paging stops at them)
# but were never actually shown to anyone, and emitting only fresh finds would drop them
# forever. `mark-read` is what closes the loop, and run.sh calls it only after a
# non-empty report exists.
#
# Usage:
#   x-bookmarks.sh collect <findings-dir>    # write x-bookmarks.md + manifest
#   x-bookmarks.sh mark-read <findings-dir>  # stamp the manifest's ids as read
#   x-bookmarks.sh status                    # check the setup by hand
#
# Config (env; run.sh sources ~/.claude/autodream/config with `set -a` first):
#   AUTODREAM_DIR   default $HOME/.claude/autodream
#   X_CREDS_FILE    default $AUTODREAM_DIR/x-credentials — sourced as bash, keys:
#                     X_AUTH_TOKEN=...     (the auth_token cookie)
#                     X_CT0=...            (the ct0 cookie)
#   X_STATE_DIR     default $AUTODREAM_DIR/x-bookmarks
#   X_MAX_PAGES     pagination cap, ~20 bookmarks per page      default 3
#   X_MAX_UNREAD    most unread bookmarks to show one report     default 40
#   X_MAX_TEXT      per-post character cap in the report input   default 800
#   X_QUERYID_TTL   seconds to reuse a scraped queryId           default 86400
set -uo pipefail

AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"

# Source the config here too, not only in run.sh — `status` is meant to be run by hand
# and has to see the same settings the nightly run does. Harmless when run.sh already
# sourced it: those values arrive exported, and the snapshot replay keeps them winning.
# `set +u` around the source for the same reason run.sh does it: this script runs under
# nounset, and a single typo'd variable reference in the user-edited config would
# otherwise abort it outright before it could write its output file. run.sh already
# warns about the typo, so stay quiet here rather than complaining twice per run.
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

CREDS_FILE="${X_CREDS_FILE:-$AUTODREAM_DIR/x-credentials}"
STATE_DIR="${X_STATE_DIR:-$AUTODREAM_DIR/x-bookmarks}"
MAX_PAGES="${X_MAX_PAGES:-3}"
MAX_UNREAD="${X_MAX_UNREAD:-40}"
MAX_TEXT="${X_MAX_TEXT:-800}"
QUERYID_TTL="${X_QUERYID_TTL:-86400}"

SEEN="$STATE_DIR/seen.jsonl"
QID_CACHE="$STATE_DIR/query-id"
TODAY="$(date +%F)"

# Public bearer embedded in X's web app — identical for every user, not a secret.
BEARER="${X_BEARER:-AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA}"
UA="${X_USER_AGENT:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36}"
GRAPHQL_BASE="https://x.com/i/api/graphql"

# Verbatim from the reference implementation. X rejects the request with a 400 naming
# any flag it expects and does not find here, so this list is maintained reactively.
FEATURES='{"graphql_timeline_v2_bookmark_timeline":true,"rweb_tipjar_consumption_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"communities_web_enable_tweet_community_results_fetch":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"articles_preview_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"creator_subscriptions_quote_tweet_preview_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"rweb_video_timestamps_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"responsive_web_enhance_cards_enabled":false}'
FIELD_TOGGLES='{"withArticlePlainText":false,"withArticleRichContentState":false,"withGrokAnalyze":false,"withDisallowedReplyControls":false}'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/xbm.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The failure reason goes to a FILE, not a variable, and that is load-bearing. The
# queryId stage is reached through nested command substitutions (`qid=$(get_query_id)`,
# which itself runs `qid=$(detect_query_id)`), and each of those forks a subshell whose
# variable writes are thrown away. A plain `FAIL_REASON=...` inside detect_query_id
# therefore never reaches the caller — so the single most important message this script
# produces, "your cookies expired, here is how to re-paste them", arrived as an empty
# string and the report told the user a fetch had failed for no stated reason. A file
# crosses the subshell boundary; a variable does not.
FAIL_FILE="$TMP/fail-reason"
: > "$FAIL_FILE"
REAUTH_HINT="Open x.com logged in, DevTools > Application > Cookies > https://x.com, copy auth_token and ct0, and rewrite $CREDS_FILE."

fail() { printf '%s' "$1" > "$FAIL_FILE"; return 1; }
fail_reason() { cat "$FAIL_FILE" 2>/dev/null; }

# Whether the queryId came from the cache or a fresh scrape of X's bundle (#38). Same file
# trick and the same reason: get_query_id runs inside a command substitution. Without this
# a night that reused a cached id is indistinguishable from one that proved the scraping
# walk still works, and the walk is the part most likely to break, because it depends on
# X's bundle layout rather than on anything here.
QID_SOURCE_FILE="$TMP/queryid-source"
printf 'not_attempted' > "$QID_SOURCE_FILE"   # no credentials, so the walk never ran
qid_source() { cat "$QID_SOURCE_FILE" 2>/dev/null; }

# ---- credentials ----

load_creds() {
  [ -f "$CREDS_FILE" ] || return 2   # 2 = not configured, which is not a failure
  # `set +u` for the same reason the config source has it. This file is hand-pasted, so a
  # stray unbound reference in it is a live possibility, and under nounset that kills the
  # script outright — before collect can write its output stub. L2 would then see an
  # absent x-bookmarks.md and read the feature as OFF rather than BROKEN, which is exactly
  # the distinction the jq-missing path was restructured to preserve. The `||` below
  # cannot catch it: nounset kills the shell rather than failing the source.
  set +u
  # shellcheck disable=SC1090
  . "$CREDS_FILE" 2>/dev/null || { set -u; fail "credentials file at $CREDS_FILE could not be parsed as shell"; return 1; }
  set -u
  [ -n "${X_AUTH_TOKEN:-}" ] && [ -n "${X_CT0:-}" ] || { fail "credentials file is missing X_AUTH_TOKEN or X_CT0. $REAUTH_HINT"; return 1; }
  return 0
}

# The cookies are a full account session — anyone who can read the file can post as the
# user. Warn rather than refuse: a nightly job silently doing nothing is worse than a
# nightly job that works and complains.
warn_perms() {
  local mode; mode=$(stat -f '%OLp' "$CREDS_FILE" 2>/dev/null) || return 0
  case "$mode" in
    600|400) : ;;
    *) echo "  WARNING: $CREDS_FILE is mode $mode; these cookies are a full account session. chmod 600 it." >&2 ;;
  esac
}

curl_x() { curl -sS --max-time 30 -A "$UA" "$@"; }

# Secrets go in a curl config file, never in argv. `-H "cookie: auth_token=..."` puts a
# full account-takeover credential into the process list, where any process running as
# this user can read it out of `ps` for as long as the request is in flight — and the
# nightly run makes several of these while the machine is unattended. `--config` keeps
# them in a 0600 file inside the per-run $TMP, which the EXIT trap removes.
#
# Two authenticated call sites need different header sets: the x.com bookmarks-page fetch
# sends cookies only, the GraphQL call sends cookies plus the CSRF token and bearer. Both
# are written here so there is one place where credentials touch the disk. The JS chunk
# fetch that follows the page load is deliberately unauthenticated — it hits
# abs.twimg.com, a public CDN, and sending a session cookie to it would widen where the
# credential goes for no benefit.
COOKIE_CFG="$TMP/curl-cookie.cfg"
API_CFG="$TMP/curl-api.cfg"

# curl's config parser treats a double-quoted value as escapable, so a `"` or `\` in a
# token would end the string early and break every authenticated fetch. X cookie values
# are hex/base64url in practice, so this is belt-and-braces — but the failure would be a
# curl parse error on a line the user pasted by hand, which is a miserable thing to debug.
cfg_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

write_curl_configs() {
  local tok csrf bearer
  tok="$(cfg_escape "$X_AUTH_TOKEN")"
  csrf="$(cfg_escape "$X_CT0")"
  bearer="$(cfg_escape "$BEARER")"
  ( umask 077
    printf 'header = "cookie: auth_token=%s; ct0=%s"\n' "$tok" "$csrf" > "$COOKIE_CFG"
    {
      printf 'header = "cookie: auth_token=%s; ct0=%s"\n' "$tok" "$csrf"
      printf 'header = "x-csrf-token: %s"\n' "$csrf"
      printf 'header = "authorization: Bearer %s"\n' "$bearer"
      printf 'header = "x-twitter-active-user: yes"\n'
      printf 'header = "x-twitter-auth-type: OAuth2Session"\n'
      printf 'header = "x-twitter-client-language: en"\n'
      printf 'header = "content-type: application/json"\n'
      printf 'header = "referer: https://x.com/i/bookmarks"\n'
    } > "$API_CFG"
  )
}

# ---- queryId discovery ----
# Walks the same path the reference does: bookmarks page -> webpack runtime -> the
# Bookmarks chunk -> the queryId literal beside operationName:"Bookmarks".

extract_qid() { grep -oE 'queryId:"[^"]+",operationName:"Bookmarks"' "$1" 2>/dev/null | head -1 | sed 's/queryId:"//; s/",operationName.*//'; }

detect_query_id() {
  local html="$TMP/bookmarks.html"
  curl_x --config "$COOKIE_CFG" \
         -o "$html" -w '%{http_code}' "https://x.com/i/bookmarks" > "$TMP/code" 2>/dev/null
  local code; code=$(cat "$TMP/code" 2>/dev/null)
  [ -s "$html" ] || { fail "could not load x.com/i/bookmarks (HTTP ${code:-none})"; return 1; }
  # X serves the login flow instead of redirecting when the session cookie is dead.
  if grep -q -e 'LoginForm' -e '/i/flow/login' "$html" 2>/dev/null; then
    fail "X returned its login page — the auth_token/ct0 cookies are expired or invalid. $REAUTH_HINT"
    return 1
  fi

  # Candidate bundles, cheapest first: any client-web JS URL printed in the HTML, then
  # the Bookmarks chunk reconstructed from the webpack runtime's id->name and id->hash
  # maps (the chunk's own filename is never in the HTML; only the runtime knows it).
  local cands="$TMP/cands"; : > "$cands"
  grep -oE 'https://abs\.twimg\.com/responsive-web/client-web/[A-Za-z0-9._~-]+\.js' "$html" 2>/dev/null \
    | grep -E 'main\.|bundle\.Bookmarks' >> "$cands"

  local chunk_id name hash
  chunk_id=$(grep -oE '[0-9]+:"(shared~bundle\.BookmarkFolders~bundle\.Bookmarks|bundle\.Bookmarks)"' "$html" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$chunk_id" ]; then
    name=$(grep -oE "${chunk_id}:\"[^\"]+\"" "$html" 2>/dev/null | head -1 | sed 's/^[0-9]*:"//; s/"$//')
    # The id appears in both the name map and the hash map; the hash map's value is the
    # pure-hex one, and it is the later occurrence. The width is NOT fixed and must not be
    # pinned: this read `{7,8}` until 2026-09-11, when X moved to 16-char hashes
    # (`34778:"c316cbd4536390c0"`). The regex then matched nothing, `hash` came back empty,
    # no candidate URL was ever built, and the walk reported "could not find the Bookmarks
    # queryId in any X JS bundle" on every run from at least 2026-09-05. The quotes on both
    # ends are what keep this from matching the name entry instead.
    hash=$(grep -oE "${chunk_id}:\"[a-f0-9]{7,64}\"" "$html" 2>/dev/null | tail -1 | sed 's/^[0-9]*:"//; s/"$//')
    if [ -n "$name" ] && [ -n "$hash" ]; then
      # The filename carries one more hex digit than the map stores — `main.<16>a.js` in the
      # page beside `main:"<16>"` in the map, and the Bookmarks chunk resolved at
      # `<name>.c316cbd4536390c0a.js` against a map value of `c316cbd4536390c0`. That digit
      # is not derivable from the map, so enumerate it. `a` first because both chunks
      # observed on 2026-09-11 used it, so the common path costs one request; the bare hash
      # is second in case X ever stops truncating. Each miss is a cheap 404 and the loop
      # below stops at the first bundle that yields a queryId.
      local sfx
      for sfx in "${hash}a" "$hash" "${hash}b" "${hash}c" "${hash}d" "${hash}e" "${hash}f" \
                 "${hash}0" "${hash}1" "${hash}2" "${hash}3" "${hash}4" \
                 "${hash}5" "${hash}6" "${hash}7" "${hash}8" "${hash}9"; do
        printf 'https://abs.twimg.com/responsive-web/client-web/%s.%s.js\n' "$name" "$sfx" >> "$cands"
      done
    fi
  fi

  # Order-preserving dedupe, NOT `sort -u`. The suffix candidates above are deliberately
  # ordered cheapest-first, and sorting threw that away — the digit variants would sort
  # ahead of `a`, so the one that actually resolves came last and the cap cut it off first.
  local url qid n=0
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    # Bounded, but wide enough to walk the whole suffix enumeration plus main/vendor.
    n=$(( n + 1 )); [ "$n" -gt 24 ] && break
    curl_x -H 'referer: https://x.com/' -o "$TMP/chunk.js" "$url" >/dev/null 2>&1 || continue
    qid=$(extract_qid "$TMP/chunk.js")
    if [ -n "$qid" ]; then printf '%s' "$qid"; return 0; fi
  done < <(awk '!seen[$0]++' "$cands")

  fail "could not find the Bookmarks queryId in any X JS bundle (X changed its bundle layout; see the grounding note in this script)"
  return 1
}

get_query_id() {
  if [ -s "$QID_CACHE" ]; then
    local age; age=$(( $(date +%s) - $(stat -f '%m' "$QID_CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$QUERYID_TTL" ]; then
      printf 'cache' > "$QID_SOURCE_FILE"
      cat "$QID_CACHE"; return 0
    fi
  fi
  local qid
  if ! qid=$(detect_query_id); then printf 'failed' > "$QID_SOURCE_FILE"; return 1; fi
  printf 'fresh' > "$QID_SOURCE_FILE"
  mkdir -p "$STATE_DIR" && printf '%s' "$qid" > "$QID_CACHE"
  printf '%s' "$qid"
}

# ---- fetch ----

# $1=queryId $2=cursor(optional) -> writes $TMP/page.json, echoes nothing
fetch_page() {
  local qid="$1" cursor="${2:-}" vars
  if [ -n "$cursor" ]; then
    vars=$(jq -nc --arg c "$cursor" '{count:20,includePromotedContent:false,cursor:$c}')
  else
    vars='{"count":20,"includePromotedContent":false}'
  fi
  local code
  code=$(curl_x --get "$GRAPHQL_BASE/$qid/Bookmarks" \
    --data-urlencode "variables=$vars" \
    --data-urlencode "features=$FEATURES" \
    --data-urlencode "fieldToggles=$FIELD_TOGGLES" \
    --config "$API_CFG" \
    -o "$TMP/page.json" -w '%{http_code}' 2>/dev/null)

  case "$code" in
    200) : ;;
    401|403) fail "X rejected the credentials (HTTP $code) — the cookies are expired. $REAUTH_HINT"; return 1 ;;
    429)     fail "X rate-limited the request (HTTP 429); it will be retried tomorrow"; return 1 ;;
    400)     # Almost always a rotated queryId or a new required feature flag. Both are
             # recoverable, and the body names which — quote it rather than paraphrase.
             rm -f "$QID_CACHE"
             fail "X returned HTTP 400: $(head -c 300 "$TMP/page.json" 2>/dev/null | tr '\n' ' ')"; return 1 ;;
    *)       fail "X returned HTTP ${code:-none}"; return 1 ;;
  esac
  jq -e . "$TMP/page.json" >/dev/null 2>&1 || { fail "X returned a response that is not JSON"; return 1; }
  return 0
}

# Parse one page's JSON into JSONL bookmark records on stdout. Mirrors the reference's
# parseTweet: the visibility wrapper puts the real tweet under .tweet, and the author
# handle moved from user legacy to user core, so both are tried.
parse_page() {
  jq -c --arg today "$TODAY" '
    [ (.data.bookmark_timeline_v2.timeline.instructions // [])[] | (.entries // [])[] ]
    | map(select(.content.itemContent.tweet_results.result != null))
    | map(.content.itemContent.tweet_results.result)
    | map(if .tweet then .tweet else . end)
    | map(select(.legacy != null))
    | map({
        id: (.rest_id // ""),
        author: ((.core.user_results.result.core.screen_name
                  // .core.user_results.result.legacy.screen_name) // "unknown"),
        text: (.legacy.full_text // ""),
        links: [ (.legacy.entities.urls // [])[] | .expanded_url ],
        created_at: (.legacy.created_at // ""),
        first_seen: $today,
        read_on: null
      })
    | map(select(.id != ""))
    | map(. + {url: ("https://x.com/" + .author + "/status/" + .id)})
    | .[]
  ' "$TMP/page.json" 2>/dev/null
}

next_cursor() {
  jq -r '
    [ (.data.bookmark_timeline_v2.timeline.instructions // [])[] | (.entries // [])[]
      | select((.content.cursorType == "Bottom") or ((.entryId // "") | startswith("cursor-bottom")))
      | .content.value ] | (.[0] // "")
  ' "$TMP/page.json" 2>/dev/null
}

known_ids() { [ -s "$SEEN" ] && jq -r '.id' "$SEEN" 2>/dev/null || true; }

# Walk pages newest-first, stopping at the first already-seen bookmark (the timeline is
# reverse-chronological, so everything past it is old) or at the page cap.
fetch_new() {
  local qid; qid=$(get_query_id) || return 1
  local known="$TMP/known"; known_ids | sort > "$known"
  local out="$TMP/new.jsonl"; : > "$out"
  local cursor="" page=1

  while [ "$page" -le "$MAX_PAGES" ]; do
    fetch_page "$qid" "$cursor" || return 1
    parse_page > "$TMP/page.jsonl"
    [ -s "$TMP/page.jsonl" ] || break

    local line id hit=0
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | jq -r '.id' 2>/dev/null)
      if grep -qxF "$id" "$known" 2>/dev/null; then hit=1; break; fi
      printf '%s\n' "$line" >> "$out"
    done < "$TMP/page.jsonl"
    [ "$hit" -eq 1 ] && break

    cursor=$(next_cursor)
    [ -n "$cursor" ] || break
    page=$(( page + 1 ))
    sleep 2   # the reference paces pages; do not look like a scraper
  done
  return 0
}

# Append genuinely-new records to the state file.
#
# The temp file lives in STATE_DIR, not in $TMP. $TMP is a mktemp -d under TMPDIR, which
# on macOS is a different filesystem, so `mv` from there is a copy-then-unlink rather than
# a rename — precisely NOT the atomic swap the old comment claimed. Same directory means a
# real rename, and the mv is gated on the copy having actually succeeded: a truncated
# seen.jsonl silently re-surfaces every lost bookmark as unread, so the next report
# re-serves posts the user has already been shown.
merge_state() {
  mkdir -p "$STATE_DIR"
  [ -f "$SEEN" ] || : > "$SEEN"
  local tmp="$STATE_DIR/.seen.jsonl.new.$$"
  if ! cat "$SEEN" > "$tmp"; then
    rm -f "$tmp"
    echo "x-bookmarks: could not stage a state update; leaving seen.jsonl untouched" >&2
    return 1
  fi
  # Ids accepted during THIS run. Dedupe used to consult only $SEEN, which is the state
  # as it was before the run — so when X's cursor pagination returned the same post on
  # two pages (it does; the timeline shifts between requests, which is why paging is
  # paced at all) neither copy was in $SEEN and both got written. One bookmark, two rows,
  # shown twice in the report and eating two of the MAX_UNREAD slots.
  local accepted="$TMP/accepted-ids"; : > "$accepted"
  if [ -s "$TMP/new.jsonl" ]; then
    local line id
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | jq -r '.id' 2>/dev/null)
      [ -n "$id" ] || continue
      grep -qxF "$id" "$accepted" 2>/dev/null && continue
      printf '%s\n' "$id" >> "$accepted"
      jq -e --arg id "$id" 'select(.id == $id)' "$SEEN" >/dev/null 2>&1 && continue
      printf '%s\n' "$line" >> "$tmp"
    done < "$TMP/new.jsonl"
  fi
  mv "$tmp" "$SEEN" || { rm -f "$tmp"; echo "x-bookmarks: state update failed; seen.jsonl unchanged" >&2; return 1; }
}

# ---- collect ----

collect() {
  local findings="$1"
  [ -n "$findings" ] || { echo "usage: x-bookmarks.sh collect <findings-dir>" >&2; exit 2; }
  mkdir -p "$findings"
  collect_bookmarks "$findings"
  local rc=$?
  # Stamped on every path, including the ones that returned early, because "the walk did
  # not run tonight" is exactly the state this exists to make visible (#38). run.sh reads
  # it back into run-stats.txt.
  printf '%s\n' "$(qid_source)" > "$findings/x-bookmarks-queryid.txt"
  return $rc
}

collect_bookmarks() {
  local findings="$1"
  local out="$findings/x-bookmarks.md" manifest="$findings/x-bookmarks-manifest.txt"
  : > "$manifest"

  load_creds
  case $? in
    2) printf '# x-bookmarks: not configured (no credentials at %s)\n' "$CREDS_FILE" > "$out"
       echo "x-bookmarks: not configured; skipping"
       return 0 ;;
    1) printf '# x-bookmarks: fetch failed — %s\n' "$(fail_reason)" > "$out"
       echo "x-bookmarks: $(fail_reason)"
       return 0 ;;
  esac
  warn_perms
  write_curl_configs

  if ! fetch_new; then
    # A failed fetch still lets previously-recorded unread bookmarks through below —
    # they are already on disk and the model can still use them. Only say "failed" when
    # there is also nothing to show.
    merge_state
    if ! emit_unread "$out" "$manifest" "$(fail_reason)"; then
      printf '# x-bookmarks: fetch failed — %s\n' "$(fail_reason)" > "$out"
    fi
    echo "x-bookmarks: $(fail_reason)"
    return 0
  fi

  merge_state
  emit_unread "$out" "$manifest" "" || printf '# x-bookmarks: no unread bookmarks\n' > "$out"
  echo "x-bookmarks: $(wc -l < "$manifest" | tr -d ' ') unread -> $out"
  return 0
}

# Write every unread bookmark as a markdown block. Returns 1 when there are none, so the
# caller can choose a different header. $3, when set, is a warning banner to prepend.
emit_unread() {
  local out="$1" manifest="$2" warn="${3:-}"
  [ -s "$SEEN" ] || return 1
  local unread="$TMP/unread.jsonl"
  # Sort by tweet id descending — NOT by position in the file. The fetch appends each
  # page newest-first, so file order is only chronological within a single run and
  # interleaves across runs; taking the head or the tail of it silently served the
  # oldest 40 bookmarks. Snowflake ids increase with time, but they exceed 2^53, so
  # `tonumber` would round them: sort by (length, string) instead, which orders numeric
  # strings correctly whether or not X shortens ids again.
  jq -sc 'map(select(.read_on == null)) | sort_by([(.id | length), .id]) | reverse | .[]' \
    "$SEEN" 2>/dev/null | head -n "$MAX_UNREAD" > "$unread"
  [ -s "$unread" ] || return 1

  local total; total=$(jq -c 'select(.read_on == null)' "$SEEN" 2>/dev/null | wc -l | tr -d ' ')
  {
    printf '# Unread X bookmarks\n'
    [ -n "$warn" ] && printf '\n> Note: this run could not reach X (%s). The bookmarks below were captured earlier and are still unread.\n' "$warn"
    printf '\n%s unread bookmark(s)' "$total"
    [ "$total" -gt "$MAX_UNREAD" ] && printf '; showing the %s most recent' "$MAX_UNREAD"
    printf '.\n\n'
    jq -r --argjson cap "$MAX_TEXT" '
      "## @" + .author + "\n" +
      .url + "\n\n" +
      (if (.text | length) > $cap then (.text[0:$cap] + " […]") else .text end) + "\n" +
      (if (.links | length) > 0 then "\nLinks: " + (.links | join(", ")) + "\n" else "" end)
    ' "$unread"
  } > "$out"
  jq -r '.id' "$unread" > "$manifest"
  return 0
}

# ---- mark-read ----

mark_read() {
  local findings="$1"
  [ -n "$findings" ] || { echo "usage: x-bookmarks.sh mark-read <findings-dir>" >&2; exit 2; }
  local manifest="$findings/x-bookmarks-manifest.txt"
  [ -s "$manifest" ] || { echo "x-bookmarks: nothing to mark read"; return 0; }
  [ -s "$SEEN" ] || return 0

  # Staged inside STATE_DIR so the mv below is a same-filesystem rename, not a copy —
  # same reasoning as merge_state.
  local tmp="$STATE_DIR/.seen.jsonl.read.$$" ids
  ids=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$manifest" 2>/dev/null) || ids='[]'
  # `.id` is bound to $i BEFORE the pipe into $ids. Inside `$ids | index(.id)` the `.`
  # has already been rebound to the array, so `.id` indexes the array with a string and
  # jq errors out on every line — a silent no-op that leaves everything unread forever.
  if jq -c --argjson ids "$ids" --arg today "$TODAY" '
        .id as $i
        | if (.read_on == null) and (($ids | index($i)) != null)
          then .read_on = $today else . end
      ' "$SEEN" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$SEEN" || { rm -f "$tmp"; echo "x-bookmarks: read-state update failed; they stay unread" >&2; return 0; }
    echo "x-bookmarks: marked $(wc -l < "$manifest" | tr -d ' ') bookmark(s) read"
  else
    rm -f "$tmp"
    echo "x-bookmarks: could not update read state (leaving them unread)" >&2
  fi
  return 0
}

# ---- status ----

status() {
  if [ ! -f "$CREDS_FILE" ]; then
    printf 'credentials: absent (%s) — feature is off\n' "$CREDS_FILE"
    return 0
  fi
  printf 'credentials: %s (mode %s)\n' "$CREDS_FILE" "$(stat -f '%OLp' "$CREDS_FILE" 2>/dev/null || echo '?')"
  warn_perms
  if load_creds; then
    printf 'keys:        X_AUTH_TOKEN and X_CT0 both set\n'
  else
    printf 'keys:        INCOMPLETE — %s\n' "$(fail_reason)"
    return 0
  fi
  if [ -s "$SEEN" ]; then
    printf 'state:       %s known, %s unread (%s)\n' \
      "$(wc -l < "$SEEN" | tr -d ' ')" \
      "$(jq -c 'select(.read_on == null)' "$SEEN" 2>/dev/null | wc -l | tr -d ' ')" "$SEEN"
  else
    printf 'state:       empty (%s)\n' "$SEEN"
  fi
  if [ -s "$QID_CACHE" ]; then
    printf 'queryId:     cached, %ss old (ttl %ss)\n' \
      "$(( $(date +%s) - $(stat -f '%m' "$QID_CACHE" 2>/dev/null || echo 0) ))" "$QUERYID_TTL"
  else
    printf 'queryId:     not yet scraped\n'
  fi
}

# A missing jq must NOT short-circuit the dispatch below. It used to `exit 0` right here,
# which broke the one invariant everything downstream leans on: collect always writes its
# output file. run.sh's `|| log` never fired (the exit status was 0) and PROMPT.md treats
# an absent file as "feature not enabled, do not mention it" — so a user with working
# credentials and bookmarks piling up saw the section silently vanish from every report,
# with nothing anywhere distinguishing "off" from "broken". run.sh builds the launchd
# agent's PATH itself, so jq going missing there is a real configuration, not a theory.
# Report it the same way every other failure is reported: as the content of the file.
HAVE_JQ=1
command -v jq >/dev/null 2>&1 || HAVE_JQ=0

case "${1:-}" in
  collect)
    shift
    if [ "$HAVE_JQ" = "0" ]; then
      findings="${1:-}"
      [ -n "$findings" ] || { echo "usage: x-bookmarks.sh collect <findings-dir>" >&2; exit 2; }
      mkdir -p "$findings"
      : > "$findings/x-bookmarks-manifest.txt"
      printf '# x-bookmarks: fetch failed — jq is not installed or not on PATH, so bookmarks cannot be parsed\n' \
        > "$findings/x-bookmarks.md"
      echo "x-bookmarks: jq not found; wrote a failure stub" >&2
      exit 0
    fi
    collect "${1:-}" ;;
  mark-read)
    shift
    [ "$HAVE_JQ" = "1" ] || { echo "x-bookmarks: jq not found; cannot update read state (they stay unread)" >&2; exit 0; }
    mark_read "${1:-}" ;;
  status)
    [ "$HAVE_JQ" = "1" ] || printf 'jq:          NOT FOUND — the feature cannot run without it\n'
    status ;;
  *) echo "usage: x-bookmarks.sh {collect <findings-dir>|mark-read <findings-dir>|status}" >&2; exit 2 ;;
esac
