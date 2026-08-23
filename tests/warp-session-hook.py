#!/usr/bin/env python3
"""
Warp session-binding hook (claude only) — installed as a Claude Code SessionStart +
SessionEnd hook. Records, per Warp pane, the EXACT live claude session id so the
superset-recovery resume hook can resume that pane's real conversation after a Mac
restart (Warp restores the pane + cwd but drops it to an idle shell).

- SessionStart: write ~/.superset-recovery/warp-bindings/<WARP_TERMINAL_SESSION_UUID>
  = "<cwd>\t<session_id>"  (a marker that a live session exists in this pane).
- SessionEnd:   remove that binding IF it belongs to the ending session (a clean exit
  => don't resume it on reboot; a reboot SIGKILLs the process so SessionEnd never fires
  => the binding survives => we DO resume it).

No-op everywhere except a Warp pane. Fast, dependency-free, never raises (a hook that
errors must not disrupt the session). Skips sub-agent / forked sessions (not the pane's
primary conversation).
"""
import sys, os, json, re

WARP_UUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")


def main():
    uuid = os.environ.get("WARP_TERMINAL_SESSION_UUID", "")
    # Only act inside a Warp pane with a valid pane id.
    if os.environ.get("TERM_PROGRAM") != "WarpTerminal" or not WARP_UUID_RE.match(uuid):
        return
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    ev = data.get("hook_event_name", "")
    home = os.path.expanduser("~")
    bdir = os.path.join(home, ".superset-recovery", "warp-bindings")
    bpath = os.path.join(bdir, uuid)

    # DURABLE record (never deleted) — the crash-proof fallback. 2026-07-27: a Warp crash
    # shut every session down "gracefully", firing SessionEnd, which deleted 23 live
    # bindings at the exact moment they were needed. A terminal crash is indistinguishable
    # from a clean quit at this layer, so we ALSO keep a last-seen record that nothing
    # removes. Resume prefers the live binding and falls back to this.
    lpath = os.path.join(os.path.dirname(bdir), "warp-last", uuid)

    if ev == "SessionStart":
        # Skip sub-sessions that aren't the pane's primary conversation.
        if data.get("agent_type") or data.get("source") == "fork":
            return
        sid = data.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        cwd = data.get("cwd") or os.getcwd()
        if not UUID_RE.match(sid or ""):
            return
        rec = "%s\t%s\n" % (cwd, sid)
        for path in (bpath, lpath):
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                tmp = path + ".tmp"
                with open(tmp, "w") as fh:
                    fh.write(rec)
                os.replace(tmp, path)   # atomic publish
            except OSError:
                pass

    elif ev == "SessionEnd":
        ending = data.get("session_id") or ""
        reason = data.get("reason") or "unknown"
        # Log the reason so we can tell a real user-quit from a crash-driven shutdown.
        try:
            with open(os.path.join(os.path.dirname(bdir), "resume.log"), "a") as fh:
                fh.write("%s warp: SessionEnd pane=%s reason=%s\n"
                         % (__import__("time").strftime("%F %T"), uuid[:8], reason))
        except Exception:
            pass
        # A DELIBERATE quit releases the binding. Max, 2026-08-23, clarifying the
        # 2026-07-27 instruction ("restore every session in the exact pane where it was"):
        # that referred to the whole Warp application coming back after a restart/crash —
        # not to resurrecting a session the user deliberately quit in one pane. Ghost
        # restores of deliberately-quit sessions produced duplicate conversations and the
        # "-swift-star" renames.
        #
        # reason=prompt_input_exit = the user exited at the prompt. Everything else
        # (other, resume, unknown) may be a crash-driven shutdown — 2026-07-27 a crash
        # shut every session down "gracefully" and deleted 23 live bindings at the exact
        # moment they were needed, which is why those must NEVER be dropped here.
        #
        # Guard: only release when no OTHER live process still runs that conversation
        # (a same-pane hand `--resume` fires prompt_input_exit transitively; deleting then
        # would drop the binding the resumed copy needs). The peer registry
        # (~/.claude/sessions/<pid>.json) is the liveness source.
        if reason == "prompt_input_exit" and ending:
            sid = ending if UUID_RE.match(ending) else ""
            if sid and not _sid_live_elsewhere(sid):
                for path in (bpath, lpath):
                    try:
                        os.remove(path)
                    except OSError:
                        pass
        return


def _sid_live_elsewhere(sid):
    """True if any RUNNING claude process other than this one holds the conversation."""
    try:
        sdir = os.path.join(os.path.expanduser("~"), ".claude", "sessions")
        live_pids = set()
        for ln in os.popen("ps -Ao pid=,comm=").read().splitlines():
            parts = ln.split(None, 1)
            if len(parts) == 2 and "claude" in os.path.basename(parts[1].strip()):
                live_pids.add(int(parts[0]))
        for f in os.listdir(sdir):
            if not f.endswith(".json"):
                continue
            try:
                import json as _j
                j = _j.load(open(os.path.join(sdir, f)))
            except Exception:
                continue
            if j.get("sessionId") == sid and j.get("pid") in live_pids:
                return True
    except Exception:
        return True   # cannot prove it is dead -> keep the record (fail toward restorable)
    return False


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass   # a binding-hook failure must never disrupt the claude session
