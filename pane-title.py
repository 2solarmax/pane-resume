#!/usr/bin/env python3
"""
pane-title — label each terminal pane with the CONVERSATION it holds, instead of the
working directory (which is identical across dozens of panes and tells you nothing).

Runs as a Claude Code hook (SessionStart + UserPromptSubmit). Reads the hook JSON on
stdin, works out what this conversation is about, and writes an OSC title escape to the
pane's own terminal. Verified 2026-07-27: Warp honours per-pane OSC titles.

Also usable directly:   pane-title.py "some text"     (set this pane's title)
                        pane-title.py --clear         (back to the default)

Never raises — a title is cosmetic and must never disturb a session.
"""
import sys, os, json, glob

MAX = 60          # headers are wide; 60 chars reads well without crowding the controls
HOME = os.path.expanduser("~")
PROJ = os.path.join(HOME, ".claude", "projects")


def set_title(text):
    """Write the OSC title to the pane's controlling terminal (not stdout — stdout is
    captured by the hook runner, so it would never reach the pane)."""
    if not text:
        return
    text = " ".join(str(text).split())[:MAX]
    for dev in ("/dev/tty",):
        try:
            with open(dev, "w") as tty:
                tty.write("\033]0;%s\007" % text)
                tty.flush()
            return True
        except Exception:
            continue
    return False


def first_message(transcript):
    """What this conversation is about = its first real user message."""
    try:
        with open(transcript, errors="ignore") as fh:
            for i, line in enumerate(fh):
                if i > 400:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") != "user":
                    continue
                c = o.get("message", {}).get("content")
                t = None
                if isinstance(c, list):
                    for p in c:
                        if isinstance(p, dict) and p.get("type") == "text":
                            t = p.get("text"); break
                elif isinstance(c, str):
                    t = c
                if not t:
                    continue
                t = " ".join(t.split())
                # skip system-injected noise, pasted paths and image markers
                if not t or t[0] == "<" or t.startswith("Caveat") or t.startswith("[Request"):
                    continue
                if t.startswith("[Image") and len(t) < 30:
                    continue
                return t
    except Exception:
        pass
    return ""


def transcript_for(sid):
    m = glob.glob(os.path.join(PROJ, "*", "%s.jsonl" % sid))
    return m[0] if m else ""


def main():
    # Direct use: pane-title.py "text" | --clear
    if len(sys.argv) > 1:
        if sys.argv[1] == "--clear":
            set_title(os.getcwd().replace(HOME, "~"))
        else:
            set_title(" ".join(sys.argv[1:]))
        return

    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    sid = data.get("session_id") or ""
    label = ""
    # Prefer the conversation's own opening message (stable across the whole session).
    tp = data.get("transcript_path") or (transcript_for(sid) if sid else "")
    if tp:
        label = first_message(tp)
    # Brand-new session: nothing written yet -> use the prompt being submitted.
    if not label:
        label = data.get("prompt") or ""
    if not label:
        # Still nothing (fresh session, no prompt yet) — show the folder, not a stale title.
        label = os.path.basename(data.get("cwd") or os.getcwd()) or ""
    set_title(label)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
