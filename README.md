# pane-resume

Auto-resume your terminal's agent conversations after a **full Mac restart**. Supports **[Warp](https://warp.dev)** and **[Superset](https://superset.sh)**.

Both terminals restore your windows/tabs/panes and their working directory when you relaunch — but after a *machine restart* they bring each pane back as an **idle shell**, with the Claude Code / Codex / Gemini conversation that was running in it gone. This tool bridges that gap: when a pane comes back, it resumes the exact session it had.

## Why a restart loses sessions (and closing the app doesn't)

Your agent runs as a live process attached to the pane's PTY. Closing the app window usually leaves that process (and its terminal daemon) running, so reopening re-attaches. A **machine restart kills every process**, so the layout and scrollback are restored from disk but the conversation isn't — nothing on disk says "pane X was running conversation Y."

Warp is explicit about this: session restoration brings back panes and working directories, not running processes ([docs](https://docs.warp.dev/terminal/sessions/session-restoration/); see also [#10583](https://github.com/warpdotdev/warp/issues/10583), [#9416](https://github.com/warpdotdev/warp/issues/9416)). Superset has the same gap, tracked in [#3496](https://github.com/superset-sh/superset/issues/3496) / [PR #5246](https://github.com/superset-sh/superset/pull/5246).

## How it works

A tiny `zsh` hook (sourced from your `~/.zshrc`) runs when a restored pane's shell spawns and, **if armed**, resumes that pane's exact prior conversation. Where the pane→conversation mapping comes from differs per terminal:

| Terminal | Pane identity | Session lookup |
|---|---|---|
| **Warp** | `WARP_TERMINAL_SESSION_UUID` (Warp persists it in its own `warp.sqlite` and reuses it on restore) | A binding this tool records itself, via a Claude Code **`SessionStart`/`SessionEnd` hook** — so it's the *exact* session id, not a guess |
| **Superset** | `SUPERSET_TERMINAL_ID` (== `paneId`, survives cold restore) | Superset's own `host.db` (`terminal_agent_bindings`), workspace-verified |

Two records are kept per pane. The **live** binding exists while a conversation is running there: `SessionStart` writes it, `SessionEnd` removes it on a clean exit — so a leftover one means exactly *"this pane had a live session that a restart cut off"*, and that is the one to resume. Alongside it is a **durable** record that is never deleted, only replaced by the next session in that pane. That second record exists because a crash is not a clean exit but the app may still fire `SessionEnd` on the way down: on 2026-07-27 a Warp crash did precisely that on 23 live sessions and wiped every live binding at once. The durable record is what survives that, and what still names the pane afterwards. This all matters when many panes share a working directory: each pane resumes **its own** conversation, not "the most recent one in this folder."

Every agent CLI already persists its conversation (`~/.claude/projects/…`, `~/.codex/sessions/…`), so "resume" just re-attaches the agent to its transcript.

**Warp support is Claude-only for now** (codex/gemini in Warp: coming). Superset supports claude/codex/gemini.

### Adding a terminal

A terminal is an adapter, not a fork. To support one, implement three things in `resume-lib.py`:

| Contract | Warp | Superset |
|---|---|---|
| **Pane identity** — an env var the terminal sets in each pane and *reuses* after a cold restore | `WARP_TERMINAL_SESSION_UUID` | `SUPERSET_TERMINAL_ID` |
| **`resolve*(pane_id)`** — returns `agent \t session_id \t [launcher…]`, or nothing | `resolve_warp()` | `resolve()` |
| **Epoch** — an id for "this run of the terminal", so locks from a previous run are reaped | `warp_epoch()` | `boot_id()` |

Everything else — arming, locking, the launch-at-first-prompt widget, the in-place SIGUSR1 path, pane titling — is terminal-agnostic and shared. If a terminal can't supply a stable pane identity across a restart, it can't be supported: that identity is the whole basis for putting the *right* conversation back in the *right* pane.

## Requirements

macOS · `zsh` panes · Warp and/or Superset · `python3` + `sqlite3` (both ship with macOS).

## Install

```bash
git clone https://github.com/2solarmax/pane-resume.git
cd pane-resume && ./install.sh
```

The installer copies the files to `~/.superset-recovery/`, adds a small guarded block to your `~/.zshrc`, and leaves it **disarmed** (opt-in). For Warp, also register the session-binding hook in `~/.claude/settings.json` (append, don't replace):

```json
{ "hooks": {
  "SessionStart": [ { "hooks": [ { "type": "command", "command": "python3 ~/.superset-recovery/warp-session-hook.py", "timeout": 10 } ] } ],
  "SessionEnd":   [ { "hooks": [ { "type": "command", "command": "python3 ~/.superset-recovery/warp-session-hook.py", "timeout": 10 } ] } ]
} }
```

## Use

```bash
superset-resume plan        # dry-run: exactly what would resume, per terminal
superset-resume on          # arm it — after your NEXT restart, panes auto-resume
superset-resume off         # disarm (default)
superset-resume status      # armed state + what would resume now
superset-resume self-test   # confirm THIS pane maps to a real conversation (no resume)
superset-resume bootstrap   # (Warp) seed bindings for sessions already running
```

Arm it and leave it armed, so it's already on **before** your next restart. Panes resume as the terminal loads them.

### Recovering after a restart you weren't armed for

Arming only helps the *next* restart. If the terminal has already come back with a screen full
of plain shells, two commands bring the conversations back to where they belong:

```bash
restore-in-place            # dry-run: which live panes map to which conversation
restore-in-place --only 1 --go   # do just the first one, to see it work
restore-in-place --go            # do the rest
```

`restore-in-place` types the resume command into panes that are still open, so each
conversation lands back in the pane it came from. Panes whose conversation is already running
are skipped, so it's safe to re-run.

For conversations whose pane no longer exists — a window you closed, or a full quit —
`restore-plan` writes a launch configuration that recreates them:

```bash
restore-plan                # writes a Warp launch configuration
```

Then open it from Warp's command palette (⌘P → "Launch Configuration"). Each pane comes back
with its own title and resumes its own conversation.

### Not all at once

Thirty panes each starting an agent in the same second will bring a laptop to its knees, so
launches are throttled: at most a few agents start at a time, each getting a few seconds to
settle before the next batch. Every path — armed auto-resume, `restore-in-place`, and the
generated launch configuration — goes through the same gate.

It is deliberately impossible for the throttle to strand a pane. Slots expire on their own
rather than being handed back by a releaser (nothing to crash, nothing to deadlock), and every
wait has a hard budget of a few minutes after which the pane launches anyway. The budget is
jittered per pane, because a fixed one would have every waiter give up in the same second —
which is the stampede this exists to prevent. Ctrl-C during the wait leaves you in a plain
shell rather than launching late.

Tune with `superset-resume slots` (shows the current setting), or by writing to
`~/.superset-recovery/starting-cap` and `starting-settle`.

## Safety

Designed to be a no-op in every normal case and to never break your shell or fork-bomb:

- **Opt-in** (disarmed by default) and **one-shot per pane per boot** (atomic lock).
- **Fail-closed everywhere**: no binding, a missing transcript, a working-directory mismatch, or an unrecognized pane → plain shell, never a surprise resume. A fresh tab has no binding, so it can never be hijacked. A conversation you deliberately quit is unbound and won't come back.
- **Zero cost on your daily shell**: no `preexec`/`precmd` hooks, no per-command work. The binding is written once per session lifecycle; the resume hook runs once at shell start, only when armed.
- Guards: interactive-only, skips inside Claude (`CLAUDECODE`), validates the pane id (no path traversal), `PRAGMA quick_check` on Superset's DB, and reads Warp's DB read-only/immutable (it can never disturb Warp's own state).
- The agent runs as a **child**, so a stale/failed resume falls back to a shell instead of killing the pane; a launcher that can't start (e.g. a wrapper needing credentials not ready at boot) **releases the lock so a re-open retries**.
- **Type-ahead drain**: a terminal may re-send the pane's preset command text on restore; the hook drains that pending tty input right before launching, so it isn't delivered into the resumed agent as junk (and can't fire a surprise duplicate launch later).
- Every no-resume decision is logged with its reason in `~/.superset-recovery/resume.log`.

## Migration (Superset)

When Superset ships native auto-resume ([#5246](https://github.com/superset-sh/superset/pull/5246) extends `host.db`'s `terminal_sessions` with restore/command metadata), this tool **detects that column and stands down automatically** — it disarms itself, logs it, and `superset-resume status` tells you it's safe to remove. There's also a runtime backstop: if an agent is already running in a pane, the hook skips. So there's **no double-resume** during the transition. To fully remove: `superset-resume off`, delete `~/.superset-recovery/`, and remove the `# >>> superset-recovery >>>` block from `~/.zshrc`.

## License

MIT — see [LICENSE](LICENSE). This is our own code; it reads the terminals' local databases and runs your agent CLIs. It redistributes neither.

---

Contributions/issues welcome.
