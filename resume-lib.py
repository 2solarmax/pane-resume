#!/usr/bin/env python3
"""
superset-recovery core library (hardened).

Superset restores your panes/tabs/workspaces after a Mac restart but drops each
pane into a bare shell instead of resuming its agent conversation. Superset's own
host.db records, per pane, a STABLE id (paneId == terminal_id == SUPERSET_TERMINAL_ID
that survives a cold restart) -> workspace_id -> agent_session_id. So we can look up
exactly which conversation each restored pane had and resume it.

Read-only brain: integrity/existence-checked, workspace-verified, busy-retrying
host.db lookups. NEVER writes host.db, NEVER resumes on its own.

Commands:
  resolve <terminal_id> <workspace_id>  -> "<agent>\\t<session_id>" (verified) or ""
  plan                                  -> human table of what WOULD resume (dry-run)
  bootid                                -> stable id of the current boot ("" if unknown)
"""
import sys, os, glob, sqlite3, subprocess, re, time, json

HOME = os.path.expanduser("~")
RECOV = os.path.join(HOME, ".superset-recovery")
CLAUDE_PROJECTS = os.path.join(HOME, ".claude", "projects")
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")       # claude/superset ids: 36-char dashed UUID
WARP_UUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")   # Warp pane id: 32 hex, no dashes
WARP_BINDINGS = os.path.join(RECOV, "warp-bindings")
# Durable last-seen pane->session record. NEVER deleted by SessionEnd — the
# crash-proof fallback (2026-07-27: a Warp crash fired SessionEnd on 23 live
# sessions and wiped their bindings). resolve_warp falls back to this.
WARP_LAST = os.path.join(RECOV, "warp-last")


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
    """Stable per-boot id; distinct across boots so stale locks can't block
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
    """Human label = the conversation's real NAME (`ai-title`/`aiTitle` — what Claude
    shows you), falling back to its first user message if it hasn't been named yet.
    Located by the globally-unique sid (no fragile project-dir encoding)."""
    m = glob.glob(os.path.join(CLAUDE_PROJECTS, "*", f"{sid}.jsonl"))
    if not m:
        return ""
    try:
        named = ""
        with open(m[0], "r", errors="ignore") as fh:
            for line in fh:
                if '"ai-title"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") == "ai-title":
                    named = o.get("aiTitle") or named
        if named:
            return " ".join(named.split())[:60]
    except Exception:
        pass
    try:
        # NOTE: no `import json` here — json is imported at module scope. A function-local
        # import would make `json` local to this WHOLE function, so the ai-title lookup
        # above would raise UnboundLocalError and silently fall through to this fallback.
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
    resumed it) — the hook then skips, so it can't start a second. Matches BOTH the
    Superset pane id (SUPERSET_TERMINAL_ID, 36-char dashed) and the Warp pane id
    (WARP_TERMINAL_SESSION_UUID, 32 hex) so the dedup works in either terminal."""
    if not (UUID_RE.match(term_id or "") or WARP_UUID_RE.match(term_id or "")):
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
            mw = re.search(r"WARP_TERMINAL_SESSION_UUID=([0-9a-fA-F]{32})", env)
            if mw and mw.group(1) == term_id:
                return True
    except Exception:
        pass
    return False


# --- Warp adapter (claude only, v1) ----------------------------------------
# Warp restores tab/pane layout + working directory after a Mac restart but drops each
# pane into an idle shell (running processes are NOT resumed — Warp docs; feature reqs
# superset-sh: warpdotdev/warp#10583, #9416). Warp has no pane->agent-session record, so
# we build our OWN exact binding: our Claude SessionStart hook writes warp-bindings/<pane
# uuid> = "<cwd>\t<session_id>" while a session is LIVE in that pane, and the SessionEnd
# hook removes it on clean exit. A reboot cuts the session off WITHOUT a SessionEnd, so a
# leftover binding means exactly "this pane had a live claude session killed by the
# restart" — resume that EXACT session (no cwd->newest guessing that would pile every pane
# in a shared dir onto one session). Pane identity = WARP_TERMINAL_SESSION_UUID, which Warp
# persists in terminal_panes and reuses on restore.

def warp_epoch():
    """Identity of the CURRENT Warp run: its main process start time.

    Resume must fire ONCE PER WARP LAUNCH per pane — not once per shell. Keying the
    one-shot lock on the boot (the old behaviour) meant: quit a session -> the pane's
    next shell resumed it again -> you could not quit (2026-07-27, live loop). Keying it
    on the Warp run gives both halves: a crash/relaunch is a NEW epoch so every pane
    restores, while inside one run a pane resumes at most once, so a quit stays quit.
    Empty string if Warp isn't found (caller then falls back to the boot id)."""
    try:
        out = subprocess.run(["ps", "-Ao", "pid=,lstart=,command="],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "Warp.app/Contents/MacOS/" in line and "--type=" not in line:
                parts = line.split(None, 1)
                pid = parts[0]
                started = parts[1].split("/Applications")[0].strip()
                return "warp-%s-%s" % (pid, re.sub(r"[^0-9A-Za-z]", "", started))
    except Exception:
        pass
    return ""


def _warp_db():
    """Path to Warp's session-restoration sqlite (Group Container). Glob the team-id
    prefix so a different Warp build/team-id still resolves. None if not found."""
    for p in glob.glob(os.path.join(
            HOME, "Library", "Group Containers", "*.dev.warp",
            "Library", "Application Support", "dev.warp.Warp-Stable", "warp.sqlite")):
        return p
    return None


def _warp_pane_cwd(uuid):
    """Best-effort live cwd Warp records for this pane (INDEXED uuid point-lookup —
    terminal_panes.uuid is UNIQUE; never the unindexed 73MB blocks scan). immutable=1 =
    no locks, reads the main db only, so it can NEVER disturb Warp's live DB. Any error
    (db/table/column absent, busy) -> None -> caller degrades gracefully."""
    db = _warp_db()
    if not db:
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True, timeout=1.0)
        try:
            row = con.execute(
                "SELECT cwd FROM terminal_panes WHERE uuid = ?",
                (bytes.fromhex(uuid),)).fetchone()
        finally:
            con.close()
        return row[0] if row and row[0] else None
    except Exception:
        return None


def _wlog(msg):
    """Append a one-line diagnostic to resume.log. Every no-resume path says WHY, so a
    silent 'nothing happened' after a restart is diagnosable (esp. the first reboot, which
    validates the uuid-stability assumption). Never raises."""
    try:
        with open(os.path.join(RECOV, "resume.log"), "a") as fh:
            fh.write("%s warp: %s\n" % (time.strftime("%F %T"), msg))
    except Exception:
        pass


def resolve_warp(uuid):
    """Warp restore resolver (claude). Returns '<agent>\\t<sid>' (launcher chosen by the
    hook) or '' for no-resume. '' on: no binding (fresh tab / cleanly-exited / uuid not
    stable across restore), missing transcript, or a live cwd mismatch. Each case is
    logged distinctly — 'no binding' after a restart means the uuid was NOT reused."""
    if not WARP_UUID_RE.match(uuid or ""):
        return ""
    parts, src = None, ""
    for path, tag in ((os.path.join(WARP_BINDINGS, uuid), "live"),
                      (os.path.join(WARP_LAST, uuid), "last-seen")):
        try:
            with open(path, "r") as fh:
                parts = fh.read().strip().split("\t"); src = tag
            break
        except OSError:
            continue
    if parts is None:
        # Neither record -> nothing ever ran in this pane -> no resume. (After a restart
        # this also covers "Warp assigned a NEW pane uuid" — fail-closed, never wrong.)
        _wlog("no record for pane %s — no resume (fresh pane or uuid not reused)" % uuid[:8])
        return ""
    if len(parts) < 2:
        _wlog("malformed binding for pane %s — no resume" % uuid[:8])
        return ""
    cwd, sid = parts[0], parts[1]
    if not sid or not UUID_RE.match(sid):
        _wlog("bad session id in binding for pane %s — no resume" % uuid[:8])
        return ""
    # transcript must still exist, else `claude --resume` starts a FRESH session
    if not _transcript_exists("claude", cwd, sid):
        _wlog("transcript gone for %s (pane %s) — no resume" % (sid[:8], uuid[:8]))
        return ""
    # defense-in-depth (NON-blocking on absence): if Warp still lists this pane its cwd
    # must match the binding's -> a genuine mismatch skips (fail-closed). Absent/unreadable
    # (Warp may not have rewritten the row yet the instant the restored shell spawns) ->
    # TRUST the self-recorded binding and proceed. realpath so a symlinked path
    # (/tmp -> /private/tmp) isn't a false mismatch.
    live_cwd = _warp_pane_cwd(uuid)
    if live_cwd is None:
        _wlog("pane %s not yet in warp.sqlite — trusting binding (proceed)" % uuid[:8])
    elif os.path.realpath(live_cwd) != os.path.realpath(cwd):
        _wlog("cwd mismatch pane %s (warp=%s binding=%s) — no resume" % (uuid[:8], live_cwd, cwd))
        return ""
    return "\t".join(["claude", sid])


def gc_warp_bindings(max_age_days=14):
    """Sweep orphan bindings (a pane crashed/was killed so SessionEnd never fired).
    mtime-based + best-effort 'uuid no longer a Warp pane'. Cheap; SessionEnd handles
    the clean-exit case, so this only mops up crashes."""
    removed = 0
    try:
        names = os.listdir(WARP_BINDINGS)
    except OSError:
        return 0
    now = time.time()
    live = None
    db = _warp_db()
    if db:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True, timeout=1.0)
            try:
                live = {r[0].hex() for r in con.execute("SELECT uuid FROM terminal_panes") if r[0]}
            finally:
                con.close()
        except Exception:
            live = None
    for name in names:
        p = os.path.join(WARP_BINDINGS, name)
        try:
            old = (now - os.path.getmtime(p)) > max_age_days * 86400
            gone = (live is not None and WARP_UUID_RE.match(name) and name.lower() not in live)
            if old or gone:
                os.remove(p); removed += 1
        except OSError:
            pass
    return removed


def _proc_cwd(pid):
    """Exact working directory of a live process (macOS lsof)."""
    try:
        out = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                             capture_output=True, text=True).stdout
        for l in out.splitlines():
            if l.startswith("n"):
                return l[1:]
    except Exception:
        pass
    return None


def bootstrap_warp():
    """Seed bindings for claude sessions ALREADY running in Warp panes, so they resume on
    the next restart even though their SessionStart fired before this hook was installed.
    Reads each live claude process's OWN env (exact uuid + sid) + its lsof cwd. Skips
    sub-agent/child sessions (not the pane's primary conversation). Returns count written."""
    n = 0
    try:
        os.makedirs(WARP_BINDINGS, exist_ok=True)
        ps = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout
    except Exception:
        return 0
    for line in ps.splitlines():
        p = line.strip().split(None, 1)
        if len(p) < 2 or "claude" not in p[1].lower():
            continue
        try:
            env = subprocess.run(["ps", "eww", "-o", "command=", "-p", p[0]],
                                 capture_output=True, text=True).stdout
        except Exception:
            continue
        mu = re.search(r"WARP_TERMINAL_SESSION_UUID=([0-9a-fA-F]{32})", env)
        ms = re.search(r"CLAUDE_CODE_SESSION_ID=([0-9a-fA-F-]{36})", env)
        if not mu or not ms:
            continue   # need both the pane id and the session id (a Warp claude pane)
        # NOTE: no CLAUDE_CODE_CHILD_SESSION filter — `ps eww` truncates the long env before
        # that var, so it's unreliable here. Per-uuid the sid is consistent (helper procs
        # share it); the SessionStart hook corrects any binding going forward.
        uuid, sid = mu.group(1), ms.group(1)
        cwd = _proc_cwd(p[0]) or HOME
        if not _transcript_exists("claude", cwd, sid):
            continue
        wrote = False
        for d in (WARP_BINDINGS, WARP_LAST):
            try:
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, uuid), "w") as fh:
                    fh.write("%s\t%s\n" % (cwd, sid))
                wrote = True
            except OSError:
                pass
        if wrote:
            n += 1
    return n


def warp_plan():
    """Dry-run: what WOULD resume in Warp right now (one line per live binding)."""
    try:
        names = sorted(os.listdir(WARP_BINDINGS))
    except OSError:
        names = []
    live = [n for n in names if WARP_UUID_RE.match(n)]
    print(f"# {len(live)} Warp pane(s) have a live-session binding "
          f"[resume after next restart]\n")
    for n in live:
        r = resolve_warp(n)
        if not r:
            continue
        _agent, sid = r.split("\t")[:2]
        try:
            cwd = open(os.path.join(WARP_BINDINGS, n)).read().split("\t")[0].replace(HOME, "~")
        except OSError:
            cwd = "?"
        lbl = _label(sid)
        print(f"{cwd}\n   claude {sid[:8]}…  {('- ' + lbl) if lbl else ''}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if cmd == "resolve" and len(sys.argv) >= 4:
        print(resolve(sys.argv[2], sys.argv[3]))
    elif cmd == "resolve-warp" and len(sys.argv) >= 3:
        print(resolve_warp(sys.argv[2]))
    elif cmd == "plan":
        plan()
    elif cmd == "warp-plan":
        warp_plan()
    elif cmd == "gc-warp":
        print(gc_warp_bindings())
    elif cmd == "bootstrap-warp":
        print(bootstrap_warp())
    elif cmd == "bootid":
        print(boot_id())
    elif cmd == "warp-epoch":
        print(warp_epoch())
    elif cmd == "label" and len(sys.argv) >= 3:
        print(_label(sys.argv[2]))
    elif cmd == "pane-label" and len(sys.argv) >= 3:
        # What WAS this pane running? Reads the durable record, prints a human topic.
        # Used to re-label a restored-but-empty pane, so after a crash every pane still
        # says which conversation it held (Warp shows only the cwd, identical everywhere).
        u = sys.argv[2]
        out = ""
        if WARP_UUID_RE.match(u or ""):
            for d in (WARP_BINDINGS, WARP_LAST):
                try:
                    parts = open(os.path.join(d, u)).read().strip().split("\t")
                    if len(parts) > 1:
                        out = _label(parts[1]) or ""
                        if out:
                            break
                except OSError:
                    continue
        print(out)
    elif cmd == "native":
        print("1" if native_resume_present() else "0")
    elif cmd == "agent-running" and len(sys.argv) >= 3:
        print("1" if agent_running(sys.argv[2]) else "0")
    else:
        print(__doc__)
