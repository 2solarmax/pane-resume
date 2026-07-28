# Plan: stop overriding your tab colours, unify the alias, and let you rehearse a crash

## 1. My configs have been overriding your tab-group colours (38 tabs)

`restore-plan` writes `color = "blue"` into every tab config. Measured from `warp.sqlite`:

| Group | Its colour | Tabs inheriting it | Tabs forced blue by me |
|---|---|---|---|
| BUGS | red | 0 | 7 |
| DEV | none | 1 | 7 |
| TOOLING | cleared | 0 | 6 |
| AGENTS | magenta | 0 | 5 |
| GTM | yellow | 0 | 5 |
| OPS | green | 1 | 4 |
| DONE | none | 0 | 4 |

`tabs.color IS NULL` is how a tab says "I have no colour of my own" — those are the ones showing
their group's colour. You also have `preserve_active_tab_color = true` (`~/.warp/settings.toml:22`),
which is exactly the behaviour you described.

**Fix:** never emit `color` from `restore-plan`, and remove it from your four Claude configs.

Already-open tabs keep their forced blue — the colour is stored per tab in Warp's live database.
Clearing those 38 means editing `warp.sqlite`, which is only safe while Warp is closed. Offered,
not done: this is a cosmetic fix and your open work is not worth the risk.

## 2. The alias

Your `.zshrc` says `cc` **is** `cc all` — *"DEFAULT: maxpool 'all' profile … (== `cc all`)"*, with
`cc all` kept only "for backward compatibility". So the configs saying `cc all` are the long form
of the same thing.

`ccnew` is a function of yours that does one extra thing before `cc all`:

```zsh
ccnew() {
  if [[ "$PWD" == "$HOME" ]]; then
    d=$(cat "$HOME/.warp/last_dir"); [[ -n "$d" && -d "$d" ]] && builtin cd "$d"
  fi
  cc all --dangerously-skip-permissions "$@"
}
```

It exists to work around new tabs opening in `$HOME`. **It is currently broken**:
`~/.warp/last_dir` contains `/`, so on a `$HOME` tab it would `cd /`.

**Fix:** all four configs use `cc --dangerously-skip-permissions` — your alias, your flag, one
spelling. `ccnew` is then unused by any config; leaving the function alone (it is yours), just
unreferenced.

## 3. The working directory

Warp's setting is **Settings → Features → Session → "Working directory for new sessions"**, with
`Home Directory` (the default) / `Previous session's directory` / `Custom` / `Advanced`. It is not
in your `settings.toml`, so it is on the default — which is why `ccnew` was invented.

**Fix:** the configs omit `directory` so they follow that setting, and you set it once to
*Previous session's directory*. That is the supported version of what `ccnew` was faking, and it
removes the broken `last_dir` dependency. The one exception is `claude_worktree.toml`, whose
`directory = "{{repo}}"` is a real parameter and stays.

`restore-plan`'s generated configs keep their explicit `directory` — a restored conversation must
land in its own project, not wherever you happened to be.

## 4. What the mystery configs are

| Entry | What it is | Verdict |
|---|---|---|
| `(unnamed)` | `restore_04ee4d05.toml` — **mine**, left over from the double-open test | delete |
| Claude / ×2 / ×4 / new worktree | yours, Jul 26-27 | keep, edit per above |
| My Tab Config | Warp's own "+ New tab config" template, saved Jul 25. One pane wrapped in a pointless one-child split, `[params]` empty | yours to keep or delete — it does nothing a plain tab doesn't |
| New tab: maxkrasnykh | `startup_config.toml`, Apr 15 — Warp's default startup config, opens `~` | Warp's, leave it |

## 5. Rehearsing a crash — the answer to "can I test this without losing my work?"

Yes, and it should not require crashing anything. Add:

```
superset-resume rehearse
```

It copies your REAL pane records into a scratch tree, runs the identical resolve → liveness →
claim logic against them under a synthetic epoch, and prints, per pane: **would restore / would
stand down (and why) / cannot restore (and why)**. It launches nothing, signals nothing, and
touches neither `~/.superset-recovery` nor Warp.

That answers the question a real crash would answer — *"if Warp died right now, what comes back?"* —
with zero risk. What it cannot prove is Warp's own half (that it re-uses pane uuids on restore),
which only a real relaunch exercises.

The honest ladder, cheapest first:

1. `superset-resume rehearse` — proves the mapping and the dedup. No risk.
2. One disposable pane: open a new tab, start a throwaway session, kill the agent (not the pane),
   `restore-in-place --only N --go`. Proves the real launch path in a pane you do not care about.
3. A deliberate Warp quit-and-reopen. This is the only true test. **The risk is inconvenience, not
   loss**: every transcript is on disk regardless, so the worst case is panes come back as plain
   shells and you reopen them with `restore-plan`.

## Files

| File | Change |
|---|---|
| `restore-plan` | stop emitting `color` |
| `superset-resume` | add `rehearse` |
| `~/.warp/tab_configs/claude*.toml` | `cc --dangerously-skip-permissions`, no `color`, no `directory` (except the worktree param) — **user's files, backed up first** |
| `~/.warp/tab_configs/restore_04ee4d05.toml` | delete (mine) |

## Verification

1. A generated tab config contains no `color` key; open one and confirm `tabs.color IS NULL` in
   `warp.sqlite` for the new tab.
2. Each edited Claude config still parses as TOML and still opens a working agent.
3. `rehearse` output matches reality for a pane whose state is known (one currently live, one
   whose transcript is gone, one of the 5 multi-bound conversations).
4. `rehearse` writes nothing: snapshot `~/.superset-recovery` and `~/.warp` before and after.
5. The crash-restore path still works after these edits — re-run the claim race test.
