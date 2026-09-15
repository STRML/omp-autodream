#!/bin/bash
# Classify one L1 worker failure from its surviving .err artifact.

classify_failure() {
  local errfile="$1" exit_code stdout_section

  if [ ! -s "$errfile" ]; then
    printf '%s\n' unclassified
    return 0
  fi

  exit_code=$(sed -n 's/^worker exit code: \([0-9][0-9]*\) after .*/\1/p' "$errfile" | tail -n 1)
  case "$exit_code" in
    ''|*[!0-9]*)
      printf '%s\n' unclassified
      return 0
      ;;
  esac

  if [ "$exit_code" -eq 0 ] && grep -qx 'worker stdout was empty' "$errfile"; then
    printf '%s\n' silent
    return 0
  fi

  stdout_section=$(awk '
    /^--- worker stdout, last 40 lines ---$/ { in_stdout = 1; next }
    in_stdout && /^--- / { exit }
    in_stdout { print }
  ' "$errfile")

  if printf '%s\n' "$stdout_section" \
      | grep -Eiq 'context[[:space:]_-]length|too[[:space:]]+long|too[[:space:]]+large|token[[:space:]]+limit|maximum[[:space:]]+context|prompt[[:space:]]+is[[:space:]]+too[[:space:]]+long'; then
    printf '%s\n' size
    return 0
  fi

  if printf '%s\n' "$stdout_section" \
      | grep -Eiq '(^|[^0-9])(429|401|403|5[0-9][0-9]|5xx)([^0-9]|$)|rate[[:space:]_-]?limit|too[[:space:]]+many[[:space:]]+requests|overload|quota|unauthori[sz]ed|forbidden|invalid[[:space:]_-]+api[[:space:]_-]+key|auth(entication)?[[:space:]_-]+(error|failed|failure)|token[[:space:]_-]+expired'; then
    printf '%s\n' provider
    return 0
  fi

  printf '%s\n' size
}
