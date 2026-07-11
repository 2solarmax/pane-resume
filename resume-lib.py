#!/usr/bin/env python3
"""
superset-recovery core library (hardened).

Superset restores your panes/tabs/workspaces after a Mac restart but drops each
pane into a bare shell instead of resuming its agent conversation. Superset's own
host.db records, per pane, a STABLE id (paneId == terminal_id == SUPERSET_TERMINAL_ID
that survives a cold restart) -> workspace_id -> agent_session_id. So we can look up
exactly which conversation each restored pane had and resume it.

Read-only brain: integrity/existence-checked, workspace-verified, busy-retrying
host.db lookups + atomic staggering. NEVER writes host.db, NEVER resumes on its own.

Commands:
  resolve <terminal_id> <workspace_id>  -> "<agent>\\t<session_id>" (verified) or ""
  plan                                  -> human table of what WOULD resume (dry-run)
  slot                                  -> atomically-unique stagger slot for THIS boot
  bootid                                -> stable id of the current boot ("" if unknown)
"""
import sys, os, glob, sqlite3, subprocess, re, time, json

HOME = os.path.expanduser("~")
RECOV = os.path.join(HOME, ".superset-recovery")
CLAUDE_PROJECTS = os.path.join(HOME, ".claude", "projects")
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")


def host_db():
    """The ACTIVE host.db — most recently modified, so a stale/second install
    (lexically-first) can't shadow the real one."""
    c = glob.glob(os.path.join(HOME, ".superset", "host", "*", "host.db"))
    if not c:
        return None
    # prefer the db Superset currently has open (its -wal is freshest); fall back to db mtime
    def freshness(db):
        try:
            wal = db + "-wal"
            return max(os.path.getmtime(db), os.path.getmtime(wal) if os.path.exists(wal) else 0)
        except OSError:
            return 0
    return max(c, key=freshness)


def boot_id():
    """Stable per-boot id; distinct across boots so stale locks/slots can't block
    a later boot. Empty string on total failure (caller then skips locking)."""
    try:
        out = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True).stdout
        m = re.search(r"sec\s*=\s*(\d+)", out)
        if m:
            return m.group(1)
    except Exception:
        pass
    # last-resort per-boot value (avoids the constant "0" that collapses all boots)
    for p in ("/private/var/run/utmpx", "/private/var/run", "/dev/console"):
        try:
            return str(int(os.stat(p).st_mtime))
        except OSError:
            continue
    return ""


def _connect_ro(db, attempts=5):
    """Read-only connect with bounded backoff on a transient BUSY/LOCKED db
    (Superset's own WAL replay at cold-restart holds the lock briefly)."""
    delay = 0.25
    last = None
    for _ in range(attempts):
        con = None
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1.0)
            con.execute("SELECT 1")  # force a real touch so a lock surfaces here
            return con
        except sqlite3.OperationalError as e:
            if con is not None:
                try:
                    con.close()   # don't leak the handle across retries
                except Exception:
                    pass
            last = e
            if "locked" in str(e).lower() or "busy" in str(e).lower():
                time.sleep(delay)
                delay *= 2
                continue
            raise
    if last:
        raise last
    return None


def _integrity_ok(con):
    try:
        r = con.execute("PRAGMA quick_check").fetchone()
        return bool(r) and r[0] == "ok"
    except Exception:
        return False


def _norm_agent(agent_id):
    a = (agent_id or "").lower()
    if "claude" in a:
        return "claude"
    if "codex" in a:
        return "codex"
    if "gemini" in a:
        return "gemini"
    return ""   # only auto-resume agents with a known non-interactive resume


def _transcript_exists(agent, cwd, sid):
    """For claude, confirm the conversation transcript is still on disk — else
    `claude --resume` would silently start a FRESH session (defeating the point)."""
    if agent != "claude":
        return True   # codex/gemini transcript layout differs; rely on worktree check
    m = glob.glob(os.path.join(CLAUDE_PROJECTS, "*", f"{sid}.jsonl"))
    return bool(m)


def resolve(term_id, ws_id):
    """Workspace-VERIFIED, existence-checked lookup. Returns '<agent>\\t<sid>' only
    if: the binding's workspace matches this pane's (guards Superset's cross-workspace
    leak), the worktree still exists, and (claude) the transcript still exists.
    Any transient error -> '' WITHOUT side effects, so the caller can safely retry."""
    if not UUID_RE.match(term_id or "") or not UUID_RE.match(ws_id or ""):
        return ""
    db = host_db()
    if not db:
        return ""
    try:
        con = _connect_ro(db)
        if con is None:
            return ""
        # query the binding DIRECTLY (terminal_id is its PK) — no inner join to
        # terminal_sessions, so an FK-off orphan can't drop a valid row.
        row = con.execute(
            "SELECT tab.agent_id, tab.agent_session_id, w.worktree_path "
            "FROM terminal_agent_bindings tab "
            "LEFT JOIN workspaces w ON w.id = tab.workspace_id "
            "WHERE tab.terminal_id = ? AND tab.workspace_id = ? "
            "AND tab.agent_session_id IS NOT NULL",
            (term_id, ws_id)).fetchone()
        if not row:
            con.close(); return ""
        agent = _norm_agent(row[0]); raw_agent = row[0]
        sid, worktree = row[1], row[2]
        if not agent or not sid or not UUID_RE.match(sid) \
           or not worktree or not os.path.isdir(worktree) \
           or not _transcript_exists(agent, worktree, sid):
            con.close(); return ""
    except sqlite3.OperationalError:
        return ""   # transient busy after retries — safe no-op, retryable
    except Exception:
        return ""
    # LAUNCH-COMMAND REUSE (mirrors PR #5246) — BEST-EFFORT ONLY. Rebuild the launcher
    # the user starts this agent with (host_agent_configs preset) so flags/wrappers
    # survive (e.g. `cc all --dangerously-skip-permissions`). A missing/renamed table
    # (other Superset versions) or a parse error MUST degrade to a bare resume, never
    # abort — so recovery still works. Match by raw agent_id first, then normalized.
    launch = []
    try:
        prow = con.execute(
            "SELECT command, args_json FROM host_agent_configs "
            "WHERE preset_id IN (?, ?) ORDER BY (preset_id = ?) DESC LIMIT 1",
            (raw_agent, agent, raw_agent)).fetchone()
        if prow and prow[0]:
            launch = [prow[0]]                      # command; args appended if parseable
            try:
                a = json.loads(prow[1] or "[]")
                if isinstance(a, list):
                    for x in a:
                        if isinstance(x, (str, int, float)):
                            s = str(x)
                            if s and "\n" not in s and "\t" not in s:   # tab-transport safe
                                launch.append(s)
            except Exception:
                pass                                # keep [command] only
    except Exception:
        launch = []                                 # table missing/renamed -> bare resume
    finally:
        try:
            con.close()
        except Exception:
            pass
    return "\t".join([agent, sid] + launch)


def _label(sid):
    """Human label = first real user message, located by the globally-unique sid
    (no fragile reconstruction of Claude's project-dir encoding)."""
    m = glob.glob(os.path.join(CLAUDE_PROJECTS, "*", f"{sid}.jsonl"))
    if not m:
        return ""
    try:
        import json
        with open(m[0], "r", errors="ignore") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") == "user":
                    c = o.get("message", {}).get("content")
                    txt = None
                    if isinstance(c, list):
                        for p in c:
                            if isinstance(p, dict) and p.get("type") == "text":
                                txt = p["text"]; break
                    elif isinstance(c, str):
                        txt = c
                    if txt:
                        t = " ".join(txt.split())
                        if t and t[0] not in "<" and not t.startswith("Caveat"):
                            return t[:60]
    except Exception:
        pass
    return ""


def live_terminal_ids():
    ids = set()
    try:
        ps = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            p = line.strip().split(None, 1)
            if len(p) == 2 and any(a in p[1].lower() for a in ("claude", "codex", "gemini")):
                env = subprocess.run(["ps", "eww", "-o", "command=", "-p", p[0]], capture_output=True, text=True).stdout
                mm = re.search(r"SUPERSET_TERMINAL_ID=([0-9a-f-]{36})", env)
                if mm:
                    ids.add(mm.group(1))
    except Exception:
        pass
    return ids


def plan():
    db = host_db()
    if not db:
        print("no host.db found — is Superset installed for this user?"); return
    try:
        con = _connect_ro(db)
    except Exception:
        print("host.db is busy/unreadable right now — try again in a moment."); return
    if con is None:
        print("host.db not available."); return
    if not _integrity_ok(con):
        print("host.db integrity check FAILED — aborting, resume nothing."); con.close(); return
    rows = con.execute(
        "SELECT ts.id, w.worktree_path, w.branch, tab.agent_id, tab.agent_session_id "
        "FROM terminal_sessions ts "
        "JOIN terminal_agent_bindings tab ON tab.terminal_id = ts.id "
        "LEFT JOIN workspaces w ON w.id = tab.workspace_id "
        "WHERE ts.status = 'active' AND tab.agent_session_id IS NOT NULL "
        "ORDER BY w.worktree_path, tab.last_event_at DESC").fetchall()
    con.close()
    live = live_terminal_ids()
    known = [r for r in rows if _norm_agent(r[3])]
    if live:
        shown = [r for r in known if r[0] in live]
        note = f"open now; {len(known) - len(shown)} stale/older active row(s) hidden"
    else:
        shown = known
        note = "host.db 'active' rows (run before a reboot to filter to open panes)"
    print(f"# {len(shown)} pane(s) would resume  [{note}]\n")
    last = None
    for _tid, wt, branch, agent_id, sid in shown:
        wt_disp = (wt or "?").replace(HOME, "~")
        if wt_disp != last:
            print(f"{wt_disp}  [{branch or '?'}]"); last = wt_disp
        print(f"   {_norm_agent(agent_id):<7} {sid[:8]}…  {('- ' + _label(sid)) if _label(sid) else ''}")


def slot():
    """Atomically-unique stagger index for this boot. O_EXCL create-the-index means
    concurrently-firing panes (a reboot fires them all at once) each get a DISTINCT
    slot -> distinct sleep -> real staggering (no thundering-herd collapse)."""
    bid = boot_id()
    if not bid:
        print(0); return   # unknown boot -> don't stagger (never share a constant bucket)
    d = os.path.join(RECOV, "slots", bid)
    try:
        os.makedirs(d, exist_ok=True)
        i = 0
        while i < 100000:
            try:
                fd = os.open(os.path.join(d, str(i)), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
                os.close(fd)
                print(i); return
            except FileExistsError:
                i += 1
        print(0)
    except Exception:
        print(0)


# --- migration / de-dup: stand down once Superset ships native auto-resume ---
# v1.13.0 terminal_sessions columns. When Superset's native cold-restore auto-resume
# (superset-sh/superset#5246) ships, it EXTENDS terminal_sessions with restore/command
# metadata. Any column beyond this set => native is present => this userland tool must
# stand down (auto-disarm) to avoid a double-resume. A false positive only ever DISARMS
# (safe); it never causes a double-launch.
_V1_TERMINAL_SESSIONS_COLS = {
    "id", "origin_workspace_id", "status", "created_at", "last_attached_at", "ended_at",
}
# Match a RESUME-RELATED new column, not just any addition — so an unrelated future
# column can't prematurely disarm the user. #5246 persists the launch/resume command.
_NATIVE_COL_HINT = re.compile(r"command|resume|launch|restore|agent", re.I)

def native_resume_present():
    db = host_db()
    if not db:
        return False
    try:
        con = _connect_ro(db)
        cols = {r[1] for r in con.execute("PRAGMA table_info(terminal_sessions)")}
        con.close()
        extra = cols - _V1_TERMINAL_SESSIONS_COLS
        return any(_NATIVE_COL_HINT.search(c) for c in extra)
    except Exception:
        return False

def agent_running(term_id):
    """True if an agent process is already bound to this pane (native/manual already
    resumed it) — the hook then skips, so it can't start a second."""
    if not UUID_RE.match(term_id or ""):
        return False
    try:
        ps = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            p = line.strip().split(None, 1)
            if len(p) < 2 or not any(a in p[1].lower() for a in ("claude", "codex", "gemini")):
                continue
            env = subprocess.run(["ps", "eww", "-o", "command=", "-p", p[0]], capture_output=True, text=True).stdout
            m = re.search(r"SUPERSET_TERMINAL_ID=([0-9a-f-]{36})", env)
            if m and m.group(1) == term_id:
                return True
    except Exception:
        pass
    return False


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if cmd == "resolve" and len(sys.argv) >= 4:
        print(resolve(sys.argv[2], sys.argv[3]))
    elif cmd == "plan":
        plan()
    elif cmd == "slot":
        slot()
    elif cmd == "bootid":
        print(boot_id())
    elif cmd == "native":
        print("1" if native_resume_present() else "0")
    elif cmd == "agent-running" and len(sys.argv) >= 3:
        print("1" if agent_running(sys.argv[2]) else "0")
    else:
        print(__doc__)
