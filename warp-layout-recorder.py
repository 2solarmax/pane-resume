#!/usr/bin/env python3
"""
warp-layout-recorder — our own record of Warp's open tabs, groups and conversations.

Why this exists (2026-10-31/11-02): when the laptop dies, Warp restores only part of
its own layout, and Warp's database keeps only the CURRENT layout — no history. So the
one thing that would let us rebuild the setup after a crash is a copy WE keep. The
owner approved it 2026-11-02: "keep our own record of open tabs, groups and their
conversations, saved every few minutes".

Every run writes ~/.superset-recovery/layout-snapshots/current.json (atomic replace)
and appends one line to archive.jsonl, so the state at the last save is always on disk
even if the machine dies mid-write. A snapshot costs one read-only query against
Warp's sqlite plus one directory listing of pane-resume's bindings.

Read-only against Warp: mode=ro (not immutable) so recent commits in the WAL are
visible; on any error the run writes nothing and logs why — never touches Warp's DB.

Who runs it: the Warp tabs themselves, never a background job. macOS privacy
protection denies a LaunchAgent any read of another app's Group Container
("Operation not permitted" / sqlite "authorization denied", probed 2026-11-02 from a
launchd job), while a process inside a Warp tab inherits Warp's own access. So it is
called from resume-hook.zsh's prompt hook and from warp-session-hook.py on every
SessionStart/SessionEnd, throttled here to one real snapshot per THROTTLE seconds
across ALL tabs (a stamp file + O_EXCL claim), detached so a prompt never waits.

Run by hand:  warp-layout-recorder.py          (snapshot now, ignores the throttle)
              warp-layout-recorder.py --if-due (what the hooks call)
"""
import glob
import json
import os
import re
import sqlite3
import sys
import time

HOME = os.path.expanduser("~")
RECOV = os.path.join(HOME, ".superset-recovery")
SNAP_DIR = os.path.join(RECOV, "layout-snapshots")
CURRENT = os.path.join(SNAP_DIR, "current.json")
ARCHIVE = os.path.join(SNAP_DIR, "archive.jsonl")
RECORDER_LOG = os.path.join(RECOV, "recorder.log")
BINDINGS = os.path.join(RECOV, "warp-bindings")
WARP_UUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")
STAMP = os.path.join(SNAP_DIR, ".last-run")
THROTTLE = 180   # seconds between real snapshots, machine-wide


def due():
    """True for exactly one caller per THROTTLE window, across every tab at once.

    The stamp's mtime says when the last run started. A caller that finds it old races
    to create a claim file with O_EXCL — the kernel lets exactly one win — and only the
    winner refreshes the stamp and runs. A claim older than a minute is a crashed run's
    leftover and is cleared, so a dead recorder can never block the next one forever."""
    try:
        if time.time() - os.path.getmtime(STAMP) < THROTTLE:
            return False
    except OSError:
        pass
    os.makedirs(SNAP_DIR, exist_ok=True)
    claim = STAMP + ".claim"
    try:
        if time.time() - os.path.getmtime(claim) > 60:
            os.unlink(claim)
    except OSError:
        pass
    try:
        fd = os.open(claim, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except OSError:
        return False
    os.close(fd)
    try:
        # Re-check UNDER the claim (double-checked locking). A racer that read the stamp
        # as old, then stalled until the previous winner had refreshed the stamp AND
        # released the claim, would otherwise win a second time inside one window —
        # measured 2026-11-02: 5-10 winners out of 12 racers without this line.
        try:
            if time.time() - os.path.getmtime(STAMP) < THROTTLE:
                return False
        except OSError:
            pass
        with open(STAMP, "w"):
            pass
    finally:
        try:
            os.unlink(claim)
        except OSError:
            pass
    return True

# A pane uuid -> conversation id map, from pane-resume's own durable records. Read at
# snapshot time so the snapshot is self-contained: restoring it later must not depend
# on today's bindings still being around.
def _pane_sessions():
    out = {}
    try:
        for pane in os.listdir(BINDINGS):
            if not WARP_UUID_RE.match(pane):
                continue
            try:
                with open(os.path.join(BINDINGS, pane)) as fh:
                    sid = fh.read().strip().split("\t")[-1]
                if re.match(r"^[0-9a-fA-F-]{36}$", sid):
                    out[pane.lower()] = sid
            except OSError:
                continue
    except OSError:
        pass
    return out


def _warp_db():
    for p in glob.glob(os.path.join(
            HOME, "Library", "Group Containers", "*.dev.warp",
            "Library", "Application Support", "dev.warp.Warp-Stable", "warp.sqlite")):
        return p
    return None


def _log(msg):
    try:
        with open(RECORDER_LOG, "a") as fh:
            fh.write("%s %s\n" % (time.strftime("%F %T"), msg))
    except OSError:
        pass


def snapshot():
    """The whole layout as one dict, or None if Warp's DB could not be read.

    Tabs are listed in id order within a window — Warp assigns increasing ids as tabs
    open, so id order is the tab-bar order at snapshot time (the column Warp itself
    orders the tab bar by when restoring). Group membership is by tab_group_id; the
    group's own name/color/collapsed/pinned ride along once per group."""
    db = _warp_db()
    if not db:
        return None
    panes = _pane_sessions()
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0)
    try:
        windows = {}
        groups = {}
        tabs = {}
        for wid in (r[0] for r in con.execute("SELECT id FROM windows")):
            windows[wid] = {"id": wid, "groups": [], "tabs": []}
        for gid, wid, name, color, collapsed, pinned in con.execute(
                "SELECT id, window_id, name, color, collapsed, pinned FROM tab_groups"):
            groups[gid] = {"id": gid, "window_id": wid, "name": name,
                           "color": color, "collapsed": bool(collapsed), "pinned": bool(pinned)}
            windows.setdefault(wid, {"id": wid, "groups": [], "tabs": []})["groups"].append(gid)
        # A tab's panes: leaf pane_nodes rows joined to terminal_panes by row id, in id
        # order so split panes keep their tree order.
        for tid, wid, title, color, gid, pinned in con.execute(
                "SELECT id, window_id, custom_title, color, tab_group_id, pinned FROM tabs ORDER BY id"):
            tabs[tid] = {"id": tid, "window_id": wid, "title": title, "color": color,
                         "group_id": gid, "pinned": bool(pinned), "panes": []}
            windows.setdefault(wid, {"id": wid, "groups": [], "tabs": []})["tabs"].append(tid)
        for pn_id, tab_id, leaf in con.execute(
                "SELECT id, tab_id, is_leaf FROM pane_nodes ORDER BY id"):
            t = tabs.get(tab_id)
            if t is None or not leaf:
                continue
            row = con.execute(
                "SELECT lower(hex(uuid)), cwd FROM terminal_panes WHERE id = ?", (pn_id,)).fetchone()
            if not row:
                continue
            uuid_hex, cwd = row
            t["panes"].append({"uuid": uuid_hex, "cwd": cwd,
                               "session": panes.get(uuid_hex, "")})
        return {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "epoch": os.environ.get("WARP_EPOCH", ""),
            "windows": [
                {"id": w["id"],
                 "groups": [groups[g] for g in w["groups"] if g in groups],
                 "tabs": [tabs[t] for t in w["tabs"] if t in tabs]}
                for w in windows.values()
            ],
        }
    finally:
        con.close()


def write(snap):
    os.makedirs(SNAP_DIR, exist_ok=True)
    body = json.dumps(snap, ensure_ascii=False)
    tmp = "%s.%d.tmp" % (CURRENT, os.getpid())   # per-process: a by-hand run can overlap a hook run
    with open(tmp, "w") as fh:
        fh.write(body)
    os.replace(tmp, CURRENT)          # atomic: a crash mid-write never corrupts current
    with open(ARCHIVE, "a") as fh:    # append-only history; pruned by size, not by date
        fh.write(body + "\n")
    _prune_archive()


def _prune_archive(keep=2000):
    """The archive is diagnosis material, not a promise: keep the most recent lines and
    drop the rest. A day of 5-minute snapshots is ~288 lines, so 2000 ≈ the last week."""
    try:
        with open(ARCHIVE) as fh:
            lines = fh.readlines()
        if len(lines) <= keep:
            return
        tmp = ARCHIVE + ".tmp"
        with open(tmp, "w") as fh:
            fh.writelines(lines[-keep:])
        os.replace(tmp, ARCHIVE)
    except OSError:
        pass


def main():
    if "--if-due" in sys.argv[1:] and not due():
        return 0
    try:
        snap = snapshot()
    except Exception as e:
        _log("ERROR %s: %s — snapshot NOT written" % (type(e).__name__, e))
        return 1
    if snap is None:
        _log("ERROR could not read warp.sqlite — snapshot NOT written")
        return 1
    write(snap)
    n_tabs = sum(len(w["tabs"]) for w in snap["windows"])
    n_sessions = len({p["session"] for w in snap["windows"] for t in w["tabs"]
                      for p in t["panes"] if p["session"]})
    _log("OK %d windows %d tabs %d conversations" %
         (len(snap["windows"]), n_tabs, n_sessions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
