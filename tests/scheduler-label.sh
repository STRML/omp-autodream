#!/usr/bin/env bash
# Unit tests for bin/scheduler-label.sh.
#
# One test per row of the #14 failure matrix. The bug this covers produced no
# error on the host it broke, so every assertion here is on the returned label
# and the exit status, never on a log line.
#
# Nothing touches launchctl or the real ~/Library/LaunchAgents: the script reads
# LAUNCH_AGENTS_DIR, and the tests point it at a sandbox.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUT="$REPO/bin/scheduler-label.sh"

PASS=0
FAIL=0
SANDBOX=""

cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
nope() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

assert_eq() {
  local want="$1" got="$2" what="$3"
  if [ "$want" = "$got" ]; then ok "$what"; else nope "$what" "want [$want] got [$got]"; fi
}

USER_SLUG="$(id -un | tr -dc 'a-zA-Z0-9')"
DEFAULT="com.$USER_SLUG.omp-autodream"

# Write a plist that schedules $2/run.sh under label $1.
make_plist() {
  local label="$1" runner_dir="$2" file="$LA/$1.plist"
  cat > "$file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$runner_dir/run.sh</string>
    </array>
</dict>
</plist>
PLIST
  printf '%s\n' "$file"
}

# The -review sibling runs review.sh, so it must never be adopted.
make_review_plist() {
  local label="$1" runner_dir="$2"
  cat > "$LA/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>exec "\$1" "\$(date -v-1d +%Y-%m-%d)"</string>
        <string>triage</string>
        <string>$runner_dir/review.sh</string>
    </array>
</dict>
</plist>
PLIST
}

reset_sandbox() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/scheduler-label.XXXXXX")"
  LA="$SANDBOX/LaunchAgents"
  OMP="$SANDBOX/omp/autodream"
  CC="$SANDBOX/claude/autodream"
  mkdir -p "$LA" "$OMP" "$CC"
  export LAUNCH_AGENTS_DIR="$LA"
}

run_sut() { # run_sut <target> -> sets SUT_OUT / SUT_RC
  SUT_OUT="$(bash "$SUT" "$1" 2>"$SANDBOX/err")"
  SUT_RC=$?
  SUT_ERR="$(cat "$SANDBOX/err")"
}

printf 'scheduler-label\n'

# --- row: no autodream plist exists at all ---------------------------------
reset_sandbox
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "empty LaunchAgents dir yields the omp-specific default"
assert_eq "0" "$SUT_RC" "empty LaunchAgents dir exits 0"

# --- row: the LaunchAgents dir does not exist ------------------------------
reset_sandbox
export LAUNCH_AGENTS_DIR="$SANDBOX/nope"
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "a missing LaunchAgents dir yields the default, not a literal glob"
assert_eq "0" "$SUT_RC" "a missing LaunchAgents dir exits 0"
export LAUNCH_AGENTS_DIR="$LA"

# --- row: a foreign install holds a DIFFERENT label (the #14 regression) ---
# This is the exact shape of the host that broke: cc-autodream scheduled under
# com.<user>.autodream. The old code adopted that label and overwrote the job.
reset_sandbox
make_plist "com.$USER_SLUG.autodream" "$CC" >/dev/null
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "a plist running another install's run.sh is not adopted"
assert_eq "0" "$SUT_RC" "a foreign label under a different name is not a conflict"

# and it must be left exactly as it was
if grep -q "$CC/run.sh" "$LA/com.$USER_SLUG.autodream.plist"; then
  ok "the foreign plist is left pointing at its own runner"
else
  nope "the foreign plist is left pointing at its own runner" "it was rewritten"
fi

# --- row: our own prior install, default label -----------------------------
reset_sandbox
make_plist "$DEFAULT" "$OMP" >/dev/null
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "our own plist at the default label is adopted"
assert_eq "0" "$SUT_RC" "adopting our own plist exits 0"

# --- row: our own prior install under a NON-default label ------------------
# A re-install must stay idempotent: adopt whatever label the user gave us
# rather than orphaning that job and scheduling a second one.
reset_sandbox
make_plist "com.example.autodream-omp" "$OMP" >/dev/null
run_sut "$OMP"
assert_eq "com.example.autodream-omp" "$SUT_OUT" "our own plist under a custom label is adopted"
assert_eq "0" "$SUT_RC" "adopting a custom label exits 0"

# --- row: the default label is held by a foreign install -------------------
reset_sandbox
make_plist "$DEFAULT" "$CC" >/dev/null
run_sut "$OMP"
assert_eq "3" "$SUT_RC" "a foreign install squatting the default label exits 3"
assert_eq "$DEFAULT" "$SUT_OUT" "a conflict still prints a usable label for namespace-only callers"
case "$SUT_ERR" in
  *"$LA/$DEFAULT.plist"*) ok "the conflict message names the offending plist" ;;
  *) nope "the conflict message names the offending plist" "stderr was [$SUT_ERR]" ;;
esac

# --- row: the .ondemand sibling is skipped ---------------------------------
# Adopting it would nest a second .ondemand suffix on autodream-now's label.
reset_sandbox
make_plist "$DEFAULT.ondemand" "$OMP" >/dev/null
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "the .ondemand sibling is not adopted as the base label"

# --- row: the -review sibling is skipped -----------------------------------
reset_sandbox
make_review_plist "com.$USER_SLUG.autodream-review" "$CC"
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "a plist running review.sh is not adopted"

# --- row: an unreadable / malformed plist ----------------------------------
reset_sandbox
printf 'this is not a plist\n' > "$LA/com.broken.autodream.plist"
make_plist "$DEFAULT" "$OMP" >/dev/null
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "a malformed plist is skipped rather than fatal"
assert_eq "0" "$SUT_RC" "a malformed plist does not change the exit status"

# --- row: the target carries a trailing slash ------------------------------
reset_sandbox
make_plist "$DEFAULT" "$OMP" >/dev/null
run_sut "$OMP/"
assert_eq "$DEFAULT" "$SUT_OUT" "a trailing slash on the target still matches our own plist"

# --- row: the target is reached through a symlink --------------------------
reset_sandbox
make_plist "$DEFAULT" "$OMP" >/dev/null
ln -s "$SANDBOX/omp" "$SANDBOX/omp-link"
run_sut "$SANDBOX/omp-link/autodream"
assert_eq "$DEFAULT" "$SUT_OUT" "a symlinked target still matches our own plist"

# --- row: both a foreign install and our own are present -------------------
# Ours wins regardless of glob order, and the foreign one is not a conflict
# because it does not hold our default label.
reset_sandbox
make_plist "com.$USER_SLUG.autodream" "$CC" >/dev/null
make_plist "$DEFAULT" "$OMP" >/dev/null
run_sut "$OMP"
assert_eq "$DEFAULT" "$SUT_OUT" "with both installs present, ours is adopted"
assert_eq "0" "$SUT_RC" "with both installs present, exit is 0"


# --- install.sh must not write a plist it was refused --------------------------
# The helper only advises. The regression stops only if install.sh honours the
# non-zero status, so drive the real installer down its real scheduling path.
#
# HOME is the sandbox, so install_schedule's $HOME/Library/LaunchAgents and the
# helper's default agree without either needing a test-only override. launchctl
# is shimmed: if the refusal ever stops working, the test records the call
# instead of mutating this machine's launchd.
reset_sandbox
unset LAUNCH_AGENTS_DIR
FAKE_HOME="$SANDBOX/home"
FAKE_LA="$FAKE_HOME/Library/LaunchAgents"
mkdir -p "$FAKE_LA" "$SANDBOX/shim"
LA="$FAKE_LA"
cat > "$SANDBOX/shim/launchctl" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$LAUNCHCTL_CALLS"
SHIM
chmod +x "$SANDBOX/shim/launchctl"
export LAUNCHCTL_CALLS="$SANDBOX/launchctl-calls"
: > "$LAUNCHCTL_CALLS"

FOREIGN="$FAKE_LA/$DEFAULT.plist"
make_plist "$DEFAULT" "$CC" >/dev/null
BEFORE="$(cat "$FOREIGN")"

HOME="$FAKE_HOME" PATH="$SANDBOX/shim:$PATH" \
  bash "$REPO/install.sh" "$SANDBOX/omp" >"$SANDBOX/install.out" 2>&1
INSTALL_RC=$?

assert_eq "$BEFORE" "$(cat "$FOREIGN")" "install.sh leaves a foreign plist byte-identical"
assert_eq "0" "$INSTALL_RC" "a refused schedule does not fail the whole install"

if grep -q "bootstrap" "$LAUNCHCTL_CALLS" 2>/dev/null; then
  nope "install.sh bootstraps nothing when refused" "launchctl calls: $(cat "$LAUNCHCTL_CALLS")"
else
  ok "install.sh bootstraps nothing when refused"
fi

if grep -qi "already scheduled by" "$SANDBOX/install.out"; then
  ok "install.sh reports why the schedule was skipped"
else
  nope "install.sh reports why the schedule was skipped" "output: $(tail -5 "$SANDBOX/install.out")"
fi

# A refusal must not then advise arming a wake schedule for the job it declined
# to install. The logic state and what the user is told have to agree.
if grep -q 'pmset repeat wake' "$SANDBOX/install.out"; then
  nope "a refused schedule does not advise pmset" "install.out still prints the wake advice"
else
  ok "a refused schedule does not advise pmset"
fi

# The symlinks must still be there - a refused schedule is not a failed install.
if [ -L "$SANDBOX/omp/autodream/run.sh" ]; then
  ok "a refused schedule still installs the symlinks"
else
  nope "a refused schedule still installs the symlinks" "run.sh symlink missing"
fi

# --- a REAL scheduling failure must still fail the install ------------------
# The refusal path returns non-zero, so the caller has to swallow it. Swallowing
# every non-zero return instead would convert a broken plist or a failed
# bootstrap into an exit-0 install that claims everything is in place - the same
# silent-success shape as #14. Simulate one with a launchctl shim that fails.
reset_sandbox
unset LAUNCH_AGENTS_DIR
FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME/Library/LaunchAgents" "$SANDBOX/shim"
cat > "$SANDBOX/shim/launchctl" <<'SHIM'
#!/bin/bash
case "$1" in
  bootstrap) echo "bootstrap: simulated failure" >&2; exit 5 ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "$SANDBOX/shim/launchctl"

HOME="$FAKE_HOME" PATH="$SANDBOX/shim:$PATH" \
  bash "$REPO/install.sh" "$SANDBOX/omp" >"$SANDBOX/fail.out" 2>&1
FAIL_RC=$?

if [ "$FAIL_RC" -ne 0 ]; then
  ok "a failed launchctl bootstrap fails the install (exit $FAIL_RC)"
else
  nope "a failed launchctl bootstrap fails the install" "install.sh exited 0 on a broken schedule"
fi

if grep -qi "Schedule FAILED" "$SANDBOX/fail.out"; then
  ok "a real scheduling failure is reported as a failure, not as 'in place'"
else
  nope "a real scheduling failure is reported as a failure, not as 'in place'" "output: $(tail -5 "$SANDBOX/fail.out")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
