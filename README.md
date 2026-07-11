# superset-session-resume

Auto-resume your [Superset](https://superset.sh) agent conversations after a **full Mac restart**.

Superset already restores your tabs/panes/workspaces on relaunch — but after a *machine restart* (or kernel panic) it drops each restored pane into a **bare shell** instead of resuming the Claude Code / Codex / Gemini conversation that was running. This tool bridges that gap: when a pane comes back, it resumes the exact session it had.

> **This is a stopgap.** The native fix is [superset-sh/superset#3496](https://github.com/superset-sh/superset/issues/3496) / [PR #5246](https://github.com/superset-sh/superset/pull/5246). When that ships, this tool **detects it and stands down automatically** (see [Migration](#migration)). Until then, this works today.

## Why a restart loses sessions (and a window-close doesn't)

Superset keeps sessions alive via a terminal-host daemon that is a **child of the GUI process**, not a launchd service. Closing the app window leaves the daemon (and your live PTYs) running, so reopening re-attaches. A **machine restart kills the daemon**, so the live agent processes are gone — Superset cold-restores the pane layout + scrollback, but into a fresh shell.

## How it works

Superset's own SQLite (`~/.superset/host/<id>/host.db`) records, per pane, a **stable id** (`paneId` == `terminal_id` == the pane's `SUPERSET_TERMINAL_ID`, which survives a cold restart) → `workspace_id` → `agent_session_id`. That mapping survives the restart.

A tiny `zsh` hook (sourced from your `~/.zshrc`) runs when a restored pane's shell spawns and, **if armed**:

1. looks up *this* pane's prior session in `host.db` (workspace-verified),
2. confirms the worktree + transcript still exist,
3. rebuilds the launcher you actually start that agent with (preserving your flags/wrapper),
4. resumes it — **staggered** so 20-40 panes don't spike your CPU/API at once.

Every agent CLI already persists its own conversation (`~/.claude/projects/…`, `~/.codex/sessions/…`), so "resume" just re-attaches the agent to its transcript.

## Requirements

macOS · `zsh` panes · Superset (tested on v1.13.0) · `python3` + `sqlite3` (both ship with macOS).

## Install

```bash
git clone https://github.com/2solarmax/superset-session-resume.git
cd superset-session-resume && ./install.sh
```

The installer copies the three files to `~/.superset-recovery/`, adds a small guarded block to your `~/.zshrc`, and leaves it **disarmed** (opt-in).

## Use

```bash
superset-resume plan        # dry-run: exactly what would resume (pane → workspace → conversation)
superset-resume on          # arm it — after your NEXT restart, panes auto-resume
superset-resume off         # disarm (default)
superset-resume status      # armed state + what would resume now
superset-resume self-test   # after a reboot: confirm THIS pane maps to a real conversation (no resume)
```

Arm it and leave it armed, so it's already on **before** your next restart. As Superset lazily loads panes, each resumes the first time you click into it.

## Safety

Designed to be a no-op in every normal case and to never break your shell or fork-bomb:

- **Opt-in** (disarmed by default) and **one-shot per pane per boot** (atomic lock).
- Guards: interactive-only, skips inside Claude (`CLAUDECODE`), UUID-validates the pane id (no path traversal), workspace-verified lookup (won't wake an agent in the wrong repo), `PRAGMA quick_check` on the DB, and existence checks (a pruned worktree/transcript → safe no-op, not a fresh session).
- The agent runs as a **child**, so a stale/failed resume falls back to a shell instead of killing the pane; a launcher that can't start (e.g. a wrapper needing creds not ready at boot) **releases the lock so a re-open retries**.
- **Staggered** resumes to avoid a thundering-herd freeze.

## Migration

When Superset ships native auto-resume (#5246 extends `host.db`'s `terminal_sessions` with restore/command metadata), this tool **detects that column and stands down automatically** — it disarms itself, logs it, and `superset-resume status` tells you it's safe to remove. There's also a runtime backstop: if an agent is already running in a pane (native/manual beat it), the hook skips. So there's **no double-resume** during the transition. To fully remove: `superset-resume off`, delete `~/.superset-recovery/`, and remove the `# >>> superset-recovery >>>` block from `~/.zshrc`.

## License

MIT — see [LICENSE](LICENSE). This is our own code; it reads Superset's local `host.db` and runs your agent CLIs. It does not redistribute Superset.

---

Built while diagnosing the restart gap; independently arrived at the same `host.db` mechanism as [#5246](https://github.com/superset-sh/superset/pull/5246). Contributions/issues welcome.
