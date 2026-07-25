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

    if ev == "SessionStart":
        # Skip sub-sessions that aren't the pane's primary conversation.
        if data.get("agent_type") or data.get("source") == "fork":
            return
        sid = data.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        cwd = data.get("cwd") or os.getcwd()
        if not UUID_RE.match(sid or ""):
            return
        try:
            os.makedirs(bdir, exist_ok=True)
            tmp = bpath + ".tmp"
            with open(tmp, "w") as fh:
                fh.write("%s\t%s\n" % (cwd, sid))
            os.replace(tmp, bpath)   # atomic publish
        except OSError:
            pass

    elif ev == "SessionEnd":
        ending = data.get("session_id") or ""
        try:
            with open(bpath) as fh:
                rec = fh.read().strip().split("\t")
        except OSError:
            return
        rec_sid = rec[1] if len(rec) > 1 else ""
        # Remove only if this binding is for the ending session (so a different live
        # session that re-bound this pane is never clobbered). Unknown -> remove.
        if not ending or rec_sid == ending:
            try:
                os.remove(bpath)
            except OSError:
                pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass   # a binding-hook failure must never disrupt the claude session
