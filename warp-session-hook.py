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
  => the binding survives => we DO resume it). A deliberate quit also leaves a
  warp-quit/<sid> marker so the sid can never be resurrected through another pane's
  history (the same conversation can appear in several panes' records).

No-op everywhere except a Warp pane. Fast, dependency-free, never raises (a hook that
errors must not disrupt the session). Skips sub-agent / forked sessions (not the pane's
primary conversation).
"""
import sys, os, json, re, subprocess, time

WARP_UUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")


def _ancestor_pids(start):
    """Inclusive pid ancestry of `start` via ps ppid-walk; best-effort, capped."""
    pids, cur, hops = [], start, 0
    while hops < 64:
        hops += 1
        try:
            out = subprocess.run(["ps", "-o", "ppid=", "-p", str(cur)],
                                 capture_output=True, text=True).stdout.strip()
        except Exception:
            break
        if not out.isdigit():
            break
        nxt = int(out)
        pids.append(cur)
        if nxt <= 1 or nxt == cur:
            break
        cur = nxt
    return pids


def _append_history(recov, uuid, cwd, sid):
    """Record the session in warp-history/<uuid> (newest first, dedup by sid, capped).
    The single writer for BOTH callers — mainline SessionStart and the suppressed
    stale-uuid path — so the cap cannot drift between two copies (2026-10-31 red team:
    the duplicated cap let a mutant escape the suite, and 11 tool children could evict
    both the pane's real session and a suppressed one)."""
    hpath = os.path.join(recov, "warp-history", uuid)
    prev = []
    try:
        with open(hpath) as fh:
            prev = [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        pass
    entry = "%s\t%s\t%d" % (cwd, sid, int(time.time()))
    prev = [e for e in prev if e.split("\t")[1:2] != [sid]]   # dedup: a re-run moves to front
    prev.insert(0, entry)
    prev = prev[:10]                                           # cap
    tmp = hpath + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("\n".join(prev) + "\n")
    os.replace(tmp, hpath)


def _stale_env_uuid(uuid, recov):
    """True when warp-shell/<uuid> names a live, plausible owner shell that is NOT an
    ancestor of this process — i.e. the env pane id is stale: claude is running inside a
    stray pre-warmed shell stamped with another pane's id (2026-10-11..14), and letting
    SessionStart write would overwrite the REAL pane's record with a conversation that
    never ran there (observed: warp-bindings/82db646d… held honestwriter content)."""
    try:
        with open(os.path.join(recov, "warp-shell", uuid)) as fh:
            owner = int(fh.read().split("\t")[0])
    except Exception:
        return False
    if owner <= 1 or owner == os.getpid():
        return False
    try:
        info = subprocess.run(["ps", "-o", "lstart=,comm=", "-p", str(owner)],
                              capture_output=True, text=True).stdout.strip()
        m = re.match(r"(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(.*)", info)
        if not m:
            return False                                   # unreadable -> don't judge
        if os.path.basename(m.group(2).strip()).lstrip("-") not in ("zsh", "bash", "sh"):
            return False                                   # pid reused by a non-shell
        started = time.mktime(time.strptime(m.group(1), "%a %b %d %H:%M:%S %Y"))
        if started > os.path.getmtime(os.path.join(recov, "warp-shell", uuid)) + 1:
            return False                                   # pid reused after a reboot
    except Exception:
        return False
    return owner not in _ancestor_pids(os.getpid())


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
        # Skip tool/print-mode sessions (`claude -p`, Bash-tool claude, SDK) FIRST, before
        # ANY write: they are not the pane's conversation, but their SessionStart
        # inherited the pane uuid, so writing here evicts the pane's REAL binding —
        # 2026-10-16: a morning deny-test claude spawned by the pane's own session
        # overwrote the "automations monitor" tab's record; the restart then wiped the
        # temp cwd and the tab restored to nothing while its real conversation sat
        # resumable the whole time. 2026-10-31 red team: this check ran AFTER the
        # stale-uuid branch, so a tool session under a stale pane id still landed at
        # warp-history[0] and the resolver would restore it in place of the real
        # conversation — the 2026-10-16 incident again, through history. Order matters:
        # no record at all, in either path, for a tool session.
        if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli":
            try:
                with open(os.path.join(os.path.dirname(bdir), "resume.log"), "a") as fh:
                    fh.write("%s warp: SessionStart pane=%s sid=%s — sdk-cli (tool/print) session; write skipped\n"
                             % (time.strftime("%F %T"), uuid[:8], sid[:8]))
            except OSError:
                pass
            return
        # A session started under a STALE pane id must not overwrite the pane's real
        # record — the registered owner shell is alive but is not this session's shell.
        # But the session itself may be REAL and long-lived: 2026-10-29..31, the owner
        # was a spare pre-warmed shell Warp had handed into pane 8e76fae8 (pid 22185),
        # Max resumed "keeper" (96584429) into that pane by hand, the write was
        # suppressed, and the conversation then ran 2 days recorded NOWHERE — after the
        # 10-31 restart the pane restored an OLDER session instead. So: still append to
        # the pane's HISTORY (append-only, never the single-slot live binding). The
        # resolver's recency-gated history preference can then find it. A deliberately
        # quit session is excluded globally by its warp-quit marker, so this cannot
        # resurrect a quit.
        if _stale_env_uuid(uuid, os.path.dirname(bdir)):
            try:
                with open(os.path.join(os.path.dirname(bdir), "resume.log"), "a") as fh:
                    fh.write("%s warp: SessionStart pane=%s sid=%s — stale uuid, pane owned by another live shell; write suppressed (history kept)\n"
                             % (time.strftime("%F %T"), uuid[:8], sid[:8]))
            except OSError:
                pass
            # Live again, even under a stale pane id: clear any earlier quit marker for
            # THIS sid, or the conversation the user just reopened by hand here would be
            # skipped at the next restore (real sequence in resume.log 2026-10-29
            # 20:13:59: quit marker would have outlived a suppressed reopen 14s later).
            try:
                os.remove(os.path.join(os.path.dirname(bdir), "warp-quit", sid))
            except OSError:
                pass
            try:
                os.makedirs(os.path.join(os.path.dirname(bdir), "warp-history"), exist_ok=True)
                _append_history(os.path.dirname(bdir), uuid, cwd, sid)
            except Exception:
                pass
            return
        # The session is live again (start/resume/compact): any earlier deliberate-quit
        # marker is obsolete — remove it so the resolver will consider this sid again.
        # A marker left behind here would suppress the resume of the very conversation
        # the user just reopened by hand.
        try:
            os.remove(os.path.join(os.path.dirname(bdir), "warp-quit", sid))
        except OSError:
            pass
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
        # SESSION HISTORY — the binding above is a single slot that each SessionStart
        # overwrites, so a short-lived crash-debris session can evict the pane's real
        # long-lived one (2026-08-31: a seconds-old /private/tmp session evicted the
        # maxpool binding; its own transcript was gone, the pane refused to resume, and
        # maxpool had to be hand-restored). The history keeps the pane's recent sessions
        # so the resolver can fall back. Newest first, dedup by sid, capped.
        # A failure here must never disturb the primary binding.
        try:
            os.makedirs(os.path.join(os.path.dirname(bdir), "warp-history"), exist_ok=True)
            _append_history(os.path.dirname(bdir), uuid, cwd, sid)
        except Exception:
            pass

    elif ev == "SessionEnd":
        ending = data.get("session_id") or ""
        reason = data.get("reason") or "unknown"
        # Log the reason (and the sid — the 2026-10-31 audit could not attribute quit
        # events to conversations without it) so we can tell a real user-quit from a
        # crash-driven shutdown.
        try:
            with open(os.path.join(os.path.dirname(bdir), "resume.log"), "a") as fh:
                fh.write("%s warp: SessionEnd pane=%s sid=%s reason=%s\n"
                         % (time.strftime("%F %T"), uuid[:8], (ending or "?")[:8], reason))
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
            # A quit is only a quit when NO live copy remains. The liveness guard is the
            # load-bearing half for EVERYTHING below (marker, global history prune,
            # binding release) — not just the binding: a same-pane hand `--resume`
            # (ccr) fires prompt_input_exit transitively and can fire it AFTER the new
            # copy's SessionStart already cleared the quit marker and re-recorded
            # history. An unconditional write would leave a stale marker naming a LIVE
            # conversation, and the next restart would refuse to restore it — the exact
            # 2026-07-27 lost-session failure this file exists to prevent. When a twin
            # is live the conversation continues; its own eventual true quit fires this
            # path again with no twin, and marks/prunes then.
            if sid and not _sid_live_elsewhere(sid):
                # 2026-10-31 red team: pruning only THIS pane's file was not enough —
                # the same conversation legitimately appears in SEVERAL panes' history
                # files (suppressed starts, hand-resumes into other tabs), and a sid
                # left in another pane's history was resurrected there by the
                # resolver's history-preference rule. Two closures:
                #  (a) prune the sid from EVERY pane's history file (the sid is
                #      global — one quit means quit everywhere);
                #  (b) write warp-quit/<sid> with the quit time, honoured by the
                #      resolver on every route (binding, warp-last, history). The
                #      session's own next SessionStart anywhere removes the marker, so
                #      a hand-reopened conversation is resumable again.
                # A marker newer than a history entry prunes it at read time too, so a
                # concurrent append race cannot re-arm a quit.
                try:
                    qdir = os.path.join(os.path.dirname(bdir), "warp-quit")
                    os.makedirs(qdir, exist_ok=True)
                    qtmp = os.path.join(qdir, sid) + ".tmp"
                    with open(qtmp, "w") as fh:
                        fh.write("%d\n" % int(time.time()))
                    os.replace(qtmp, os.path.join(qdir, sid))
                except OSError:
                    pass
                hroot = os.path.join(os.path.dirname(bdir), "warp-history")
                try:
                    for name in os.listdir(hroot):
                        hpath = os.path.join(hroot, name)
                        try:
                            with open(hpath) as fh:
                                lines = [ln.strip() for ln in fh if ln.strip()]
                        except OSError:
                            continue
                        keep = [ln for ln in lines
                                if ln.split("\t")[1:2] != [sid]]
                        if len(keep) != len(lines):   # never rewrite files we did not change
                            tmp = hpath + ".tmp"
                            with open(tmp, "w") as fh:
                                fh.write("\n".join(keep) + ("\n" if keep else ""))
                            os.replace(tmp, hpath)
                except OSError:
                    pass
                # Remove a record ONLY when it names the quitting sid. The env pane id
                # can be STALE for a suppressed session (the keeper configuration), and
                # an unconditional remove deleted the REAL pane's binding for a session
                # that never owned it — the pane then restored empty. Per-record, so a
                # mixed state (binding names A, warp-last names the quitter) does the
                # right thing for each.
                for path in (bpath, lpath):
                    try:
                        with open(path) as fh:
                            recorded = fh.read().strip().split("\t")
                        if len(recorded) >= 2 and recorded[1] == sid:
                            os.remove(path)
                    except FileNotFoundError:
                        pass
                    except OSError:
                        pass
        return


def _sid_live_elsewhere(sid):
    """True if any RUNNING claude process other than this one holds the conversation."""
    try:
        sdir = os.path.join(os.path.expanduser("~"), ".claude", "sessions")
        live_pids = set()
        for ln in subprocess.run(["ps", "-Ao", "pid=,comm="],
                                 capture_output=True, text=True).stdout.splitlines():
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
    # Layout snapshot (2026-11-02, owner-approved): a conversation just started or ended,
    # which is exactly when the layout changed. Detached, throttled to one real run per
    # 3 min machine-wide by the recorder itself; --if-due costs one stat() otherwise.
    try:
        subprocess.Popen(
            [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "warp-layout-recorder.py"), "--if-due"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass
