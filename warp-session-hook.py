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
        # NEVER remove the record. Max, 2026-07-27: "It doesn't matter who quits it, I or
        # somebody else. I need to be able to restore every session in the exact pane where
        # it was." So a session that ends — for ANY reason, including a deliberate quit —
        # stays restorable in its own pane. The record is only ever REPLACED, by the next
        # SessionStart in that same pane. Losing a pane's session is the failure mode that
        # matters; re-opening one you'd finished is a keystroke to close.
        return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass   # a binding-hook failure must never disrupt the claude session
