# omp-autodream

Nightly session review for the **OMP** harness (Oh My Pi). While you sleep it
reads yesterday's session transcripts and leaves you one short report: the mistakes
you keep making, where you lost time, and what's worth remembering.

This is a port of
[cc-autodream](https://github.com/STRML/cc-autodream) that runs the nightly pipeline
on OMP: it reads OMP session transcripts with OMP's models and writes reports to
OMP's own data directory. The interactive triage tool (`review.sh`) is inherited
from cc-autodream and still runs on the Claude Code CLI — see
[review.sh below](#interactive-triage-reviewsh).

## Why

You have dozens of OMP sessions a week. The useful lessons — a wrong assumption you
made twice, a flag that always trips you up, a fix worth keeping — are
buried in transcripts you'll never reread. OMP starts each session fresh and
rediscovers the same friction.

omp-autodream does the rereading for you. Every night it looks across **all** of
yesterday's sessions, ranks what recurs by frequency × severity (so you see the
patterns, not the one-offs), and writes a dated digest you can skim in a minute. The
report is the whole deliverable — under OMP, Layer 2 performs no memory writes, so
nothing else in your session corpus is touched.

## What it uses

- **Session source:** OMP's session store, `~/.omp/agent/sessions/<project>/<ts>_<uuid>.jsonl`.
  OMP's transcripts carry the same substance Claude's do — user/assistant `message`
  records, `custom` records for tool calls, `model_change` provenance — so the triage
  reads full conversation + tool activity, not just prompts.
- **Layer 1 (per-session triage):** `runinfra/deepseek-v4-flash` — cheap, fast.
  Every L1 worker runs with the **advisor disabled** (`--config l1-no-advisor.yml`),
  so a nightly fan-out doesn't boot the expensive advisor model on every session.
- **Layer 2 (aggregation):** `anthropic/claude-opus-5` on the Anthropic subscription
  (file-based `agent.db` OAuth — safe unattended at 3am; no keychain dependency).
- **Changelog window:** still diffs the upstream `anthropics/claude-code` repo, since
  OMP tracks Claude Code releases.

## What you get

A report at `~/.omp/agent/dreams/YYYY-MM-DD.md`. See
[`example/2026-05-25.md`](example/2026-05-25.md) for a real one (60 sessions, seven
ranked patterns, five open questions). The shape:

```markdown
# Dream report — 2026-05-29   (21 sessions)

## Top patterns
1. **Editing files before reading them** ×6  ·  high
   Six sessions hit "File has not been read yet". Read-before-Edit isn't sticking.
   → Pin: always Read a file in-session before the first Edit.
2. **$() in Bash triggers permission prompts** ×4  ·  medium
3. **Assuming the host TZ is Pacific** ×2  ·  medium

## Upstream Claude Code changes
- v2.x.y added `--foo`; relevant to the rush project's deploy script.

## Open questions for the user
1. Add a Read-before-Edit reminder to the project CLAUDE.md?
```

Three ways you actually interact with it:

- **It runs unattended.** A launchd job fires overnight (with morning catch-up
  triggers in case the Mac was asleep). You do nothing.
- **It opens itself.** When a report lands, `notify.sh` writes its open questions to a
  text file and pops it open in your editor — so it's in front of you with morning
  coffee, not waiting to be discovered.
- **It has an interactive suggestion solver.** `review.sh` opens a Claude session
  preloaded with the report and walks the open questions one at a time — restate,
  recommend, then **approve / modify / skip / discuss** — executing the ones you
  approve and logging each decision back into the report.
- **It stays quiet when there's nothing to say.** Most nights the report has no
  open questions, and opening a session just to be told "nothing to do" costs a
  session's tokens to print one line. `review.sh` detects that itself and prints
  the line instead. Same for a report you've already triaged. Anything it can't
  classify still opens the session — a wasted session is cheaper than a buried
  question. `--force` overrides.

## Install

```bash
git clone https://github.com/STRML/omp-autodream ~/git/omp-autodream
cd ~/git/omp-autodream
./install.sh
```

This symlinks `bin/*.sh` and `prompts/*.md` into `~/.omp/agent/autodream/`, creates
`~/.omp/agent/dreams/`, and on macOS installs and bootstraps the nightly launchd
schedule for you (auto-detecting your username, paths, and the `omp` binary — no
plist editing). Because the scripts are symlinks, editing the repo copy takes effect
immediately.

Install writes the advisor-off overlay (`l1-no-advisor.yml`) into `AUTODREAM_DIR`; the
nightly runners pass it as `--config` so no headless worker boots the advisor.

The schedule fires `run.sh` at 03:15 with morning catch-up triggers (06:15/09:15/12:15)
in case the Mac was asleep; the idempotency guard makes all but the first a one-second
no-op. To skip scheduling and only symlink the scripts:

```bash
./install.sh --no-schedule
```

launchd won't *wake* the Mac, so to guarantee the 03:15 trigger runs at all, add a
scheduled wake:

```bash
sudo pmset repeat wake MTWRFSU 03:10:00
```

The hand-editable template lives at `launchd/com.user.autodream.plist.example` if you'd
rather install the job yourself.

## Running it by hand

```bash
~/.omp/agent/autodream/run.sh $(date -v-1d +%Y-%m-%d)       # process yesterday
AUTODREAM_FORCE=1 ~/.omp/agent/autodream/run.sh 2026-05-29  # rebuild a date
~/.omp/agent/autodream/review.sh                            # solve the latest report's questions
~/.omp/agent/autodream/review.sh 2026-05-29                 # triage a specific report
~/.omp/agent/autodream/review.sh --force 2026-05-29         # open it even if there's nothing to triage
```

> **$OMP_BIN** overrides the `omp` binary location (default `/opt/homebrew/bin/omp`).
> The L1 runner model is `AUTODREAM_L1_MODEL` (default `runinfra/deepseek-v4-flash`);
> the L2 aggregator model is `AUTODREAM_L2_MODEL` (default
> `anthropic/claude-opus-5`). All knobs are documented in `bin/run.sh`'s header.

## Interactive triage (review.sh)

`review.sh` is inherited from cc-autodream and still shells out to the **Claude Code
CLI** (`claude`, override with `CLAUDE_BIN`): it runs an interactive session to walk
the report's open questions. The nightly pipeline (L1/L2) is fully on `omp`; only the
interactive solver uses `claude`, so it needs the Claude CLI installed.

`review.sh` exits without opening a session when the report has no open questions
or already carries a `## Triage decisions` section, printing where the report is.
It reads the `<!-- autodream:open-questions=N -->` marker that `PROMPT.md` makes the
nightly run emit; anything ambiguous opens the session as before.

To make it open in its own cmux workspace instead of the current terminal, drop a
config at `~/.omp/agent/autodream/config` (see `example/config.example`):

```bash
AUTODREAM_TRIAGE_SURFACE=cmux    # inline (default) | cmux
```

## Leaving notes for the next run

Notes you leave get answered in the report's **Operator notes** section, with evidence
from that night's sessions — "how often did I actually use /graphify, and did it work?"
comes back as a count and a verdict, not a guess.

From a terminal:

```bash
~/.omp/agent/autodream/autodream-note.sh "evaluate how often /graphify is used"
~/.omp/agent/autodream/autodream-note.sh --expires 2026-10-01 "check the codemaps hook overhead"
```

From anywhere else, including your phone, point autodream at a folder in a synced
vault and drop a markdown file in its inbox:

```bash
# in ~/.omp/agent/autodream/config — quote it, the iCloud path has spaces
AUTODREAM_VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/autodream"
```

The run creates the rest on its own:

| path | what it holds |
| --- | --- |
| `<vault>/inbox/*.md` | drop a note here; one file per note, any filename |
| `<vault>/processed/<date>/` | where a note moves once a report has read it |
| `<vault>/reports/<date>.md` | the nightly report, copied in so you can read it in bed |

Add `expires: YYYY-MM-DD` as YAML frontmatter to a note that should retire itself. A
note is only archived after a report actually read it, so a failed run leaves your
inbox alone, and so does a note you write while a run is in flight.

## Ideas from your X bookmarks

Point autodream at your X bookmarks and the report gains an **Ideas from bookmarks**
section: what you saved, crossed against what you actually worked on that day. A
bookmark that connects to nothing gets left out — the section is the intersection, not
a reading list.

X's official API can't do this (the bookmarks endpoint needs the $200/mo Basic tier),
so this reads the same web endpoint your browser does, with your session cookies:

1. Open x.com in a browser, logged in. DevTools → Application → Cookies → `https://x.com`.
2. Copy the values of `auth_token` and `ct0`.
3. Put them in `~/.omp/agent/autodream/x-credentials`:

```bash
X_AUTH_TOKEN=paste_auth_token_here
X_CT0=paste_ct0_here
```

```bash
chmod 600 ~/.omp/agent/autodream/x-credentials
~/.omp/agent/autodream/x-bookmarks.sh status   # check it took
```

Bookmarks are marked read once a report has covered them, so each one gives you an
idea once. Without that file the feature is simply off. When the cookies expire the
report says so and tells you to re-paste; the run itself never fails over it.

## Running long jobs

A full run usually takes more than 10 minutes. If you're kicking it off from
something that kills long jobs (a Claude Code background task, a flaky ssh session),
use `autodream-now.sh` — it hands the run to launchd, which has no time cap and keeps
going after you disconnect:

```bash
~/.omp/agent/autodream/autodream-now.sh                    # yesterday, right now
~/.omp/agent/autodream/autodream-now.sh 2026-05-29 --force # a specific date, rebuild
~/.omp/agent/autodream/autodream-now.sh 2026-05-29 --watch # follow the log until the report lands
```

## How it works (short version)

Two layers: a cheap per-session pass (Layer 1, `runinfra/deepseek-v4-flash`) extracts
structured findings from each transcript, then a single smarter pass (Layer 2,
`anthropic/claude-opus-5`) ranks them across the whole day and writes the report.
Layer 1 workers invoke `omp -p` headless with the advisor disabled; Layer 2 invokes
`omp -p` on the subscription model. It also diffs the upstream Claude Code changelog
over the day so the report can flag releases that change how you work.

Everything lives on disk (findings JSON, the report, run logs, stats) and every step
is idempotent, so you can rerun any date. Configuration knobs are documented in
`bin/run.sh`'s header.

For the internals — data flow, file map, state layout, environment overrides, the
headless-worker pattern, and the "don't eat your own tail" self-pollution defenses —
see **`codemaps/architecture.md`** and **`CLAUDE.md`**.

## Caveats

- macOS-only as written (BSD `date`, `launchd`, `osascript`/`open`). The core pipeline
  is portable; the scheduling and notify bits are mac-specific. The morning
  open-questions file opens with your default `.md` app; set `AUTODREAM_OPEN`
  (e.g. `subl`, `code -g`, `open -a Obsidian`) to pick a specific editor.
- The nightly pipeline runs headless `omp -p` workers in `--approval-mode yolo` (Layer 1
  workers write findings; the Layer 2 aggregator writes the daily report). Don't run
  it in a shared environment.
- **L1 auth:** the `runinfra` key normally lives in the macOS login keychain (via the
  `!security` escape in `~/.omp/agent/models.yml`). At 3am a locked keychain could kill
  the fan-out; `run.sh` sources `RUNINFRA_API_KEY` from
  `~/.omp/agent/autodream/x-credentials` (chmod 600) when present, else falls back to
  the keychain. Layer 2 needs no key (subscription OAuth via `agent.db`).
- The first run clones `anthropics/claude-code` (small) for the changelog window; it
  degrades gracefully with no git/network.

## License

MIT — see LICENSE.
