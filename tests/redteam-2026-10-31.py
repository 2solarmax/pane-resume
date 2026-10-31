# Regression suite for the 2026-10-31 red team: every case below is a confirmed,
# sandbox-reproduced attack against commits 613c4b0+9d4baf8. Each must FAIL on the
# pre-fix code (verified by construction: the mutations they kill are the ones the
# verifiers used) and PASS on HEAD.
#
# Cases (red-team finding numbers in comments):
#  R1  suppressed start in P + quit in Q -> P resumes its OWN binding, not the quit sid
#  R2  no suppression, quit in Q -> the quit conversation never comes back anywhere
#  R3  sdk-cli (tool/print) start under a STALE pane id writes no record at all
#  R4  sdk-cli session at history[0] (legacy pollution) never beats a healthy binding
#  R5  oldest-first history file (hand-repaired, real pane 791631fb's shape) with the
#      newest record at the END: the NEWER binding wins, not file position [0]
#  R6  suppressed keeper start: history[0] newer than binding -> keeper still wins
#      (the original keeper fix must keep working)
#  R7  a suppressed session's quit in its own pane does not delete the REAL pane's
#      binding (per-record ownership check)
#  R8  history[0] candidate whose folder is deleted cannot flip the pane to no-restore
#  R9  claim_conversation reaper never deletes a LIVE other-epoch's claims
#  R10 warp-epoch --from-parent actually walks ancestry (flag at argv[2], as the hook
#      calls it)
import json, os, subprocess, sys, tempfile, shutil, time, signal

HOME_BACKUP = os.environ.get("HOME")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(REPO, "warp-session-hook.py")
LIB = os.path.join(REPO, "resume-lib.py")
tmp = tempfile.mkdtemp(prefix="pane-redteam-")
os.environ["HOME"] = tmp
REC = f"{tmp}/.superset-recovery"
os.makedirs(f"{REC}/warp-bindings"); os.makedirs(f"{REC}/warp-last")
os.makedirs(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-quit")
PROJ = f"{tmp}/.claude/projects/-private-tmp"
os.makedirs(PROJ); os.makedirs(f"{tmp}/.claude/sessions")
os.makedirs(f"{tmp}/live-dir", exist_ok=True)
for d in ("live-dir", "live-dir2"):
    os.makedirs(f"{tmp}/{d}", exist_ok=True)

P = "aabbccddeeff00112233445566778899"   # pane P
Q = "11223344556677889900aabbccddeeff"   # pane Q
A = "11111111-2222-3333-4444-555555555555"
B = "99999999-8888-7777-6666-555555555555"
TOOL = "dead0000-beef-0000-0000-000000000000"
OLD = "77777777-7777-7777-7777-777777777777"

ok = 0; fail = 0
def ck(name, cond):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + name)
    ok, fail = (ok + 1, fail) if cond else (ok, fail + 1)

def fire(pane, payload, hook=HOOK, entry=None):
    env = dict(os.environ, TERM_PROGRAM="WarpTerminal", WARP_TERMINAL_SESSION_UUID=pane)
    if entry:
        env["CLAUDE_CODE_ENTRYPOINT"] = entry
    r = subprocess.run([sys.executable, hook], input=json.dumps(payload),
                       env=env, capture_output=True, text=True)
    return r

def transcript(sid, entrypoint="cli", cwd="/tmp", n=2):
    with open(f"{PROJ}/{sid}.jsonl", "w") as fh:
        fh.write(json.dumps({"type": "user", "entrypoint": entrypoint, "cwd": cwd}) + "\n" * n)

def bind(pane, cwd, sid, d="warp-bindings"):
    with open(f"{REC}/{d}/{pane}", "w") as fh:
        fh.write(f"{cwd}\t{sid}\n")

def hist(pane, rows):
    # rows: list of (cwd, sid, ts) written verbatim, positionally — lets tests forge
    # oldest-first legacy files (real pane 791631fb's shape)
    with open(f"{REC}/warp-history/{pane}", "w") as fh:
        for cwd, sid, ts in rows:
            fh.write(f"{cwd}\t{sid}\t{ts}\n")

def resolve(pane, lib=LIB):
    out = subprocess.run([sys.executable, lib, "resolve-warp", pane],
                         capture_output=True, text=True).stdout.strip().splitlines()
    return out[-1] if out else ""

def foreign_owner(pane):
    """A live zsh registered as the pane's owner but NOT an ancestor of the hook."""
    owner = subprocess.Popen(["zsh", "-c", "sleep 120; :"])
    time.sleep(0.5)
    os.makedirs(f"{REC}/warp-shell", exist_ok=True)
    with open(f"{REC}/warp-shell/{pane}", "w") as fh:
        fh.write(f"{owner.pid}\ttrap1\n")
    return owner

def load_lib(path=LIB):
    import importlib.util
    spec = importlib.util.spec_from_file_location("rl_fix", path)
    mod = importlib.util.module_from_spec(spec)
    os.environ["HOME"] = tmp
    spec.loader.exec_module(mod)
    return mod

print("R1) suppressed start in P, quit in Q -> P keeps its own binding (no cross-pane resurrection):")
transcript(A); transcript(B)
bind(P, "/tmp", A); bind(Q, "/tmp", A)
owner = foreign_owner(P)
fire(P, {"hook_event_name": "SessionStart", "session_id": B, "cwd": "/tmp"})
owner.kill(); owner.wait()
ck("suppressed B in P's history", B in open(f"{REC}/warp-history/{P}").read())
fire(Q, {"hook_event_name": "SessionEnd", "session_id": B, "reason": "prompt_input_exit"})
r = resolve(P)
ck("P resolves to A (its own conversation)", r == f"claude\t{A}")
ck("quit marker written", os.path.exists(f"{REC}/warp-quit/{B}"))
ck("Q's binding kept (it names A, not the quitter B)", os.path.exists(f"{REC}/warp-bindings/{Q}"))

print("R2) quit without any suppression -> the sid is unresumable everywhere:")
fire(P, {"hook_event_name": "SessionEnd", "session_id": A, "reason": "prompt_input_exit"})
r = resolve(Q)
ck("Q does not resurrect the quit A", r == "")

print("R3) sdk-cli under a STALE pane id writes nothing anywhere:")
owner = foreign_owner(P)
fire(P, {"hook_event_name": "SessionStart", "session_id": TOOL, "cwd": "/tmp"}, entry="sdk-cli")
owner.kill(); owner.wait()
h = open(f"{REC}/warp-history/{P}").read()
ck("history free of the tool sid", TOOL not in h)

print("R4) legacy sdk-cli entry at history[0] cannot beat a healthy binding:")
transcript(TOOL, entrypoint="sdk-cli", cwd="/tmp")
# rebuild P's state: healthy binding A (newest), polluted history with TOOL at [0]
shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
hist(P, [("/tmp", TOOL, 100), ("/tmp", A, 50)])      # TOOL newer by ts AND at [0]
bind(P, "/tmp", A)
r = resolve(P)
ck("binding A wins over the sdk-cli history entry", r == f"claude\t{A}")

print("R5) oldest-first history (real 791631fb shape): NEWER binding wins, not position [0]:")
shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
hist(P, [("/tmp", OLD, 1000), ("/tmp", A, 5000)])    # file is oldest-first; A is newest
transcript(OLD)
r = resolve(P)
ck("binding A (newer) wins over file-position[0] OLD", r == f"claude\t{A}")

print("R6) keeper shape: suppressed start newer than binding -> suppressed session wins:")
shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
transcript(A); transcript(B)
bind(P, "/tmp", A)
hist(P, [("/tmp", A, 1000), ("/tmp", OLD, 500)])     # binding's own entry at ts=1000
# the suppressed B lands at [0] with ts=now (> binding) through the REAL hook:
owner = foreign_owner(P)
fire(P, {"hook_event_name": "SessionStart", "session_id": B, "cwd": "/tmp"})
owner.kill(); owner.wait()
r = resolve(P)
ck("suppressed keeper B wins over older binding A", r == f"claude\t{B}")

print("R7) suppressed session's quit does not delete the pane's REAL binding:")
shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
transcript(A); transcript(B)
bind(P, "/tmp", A); bind(P, "/tmp", A, d="warp-last")
owner = foreign_owner(P)
fire(P, {"hook_event_name": "SessionStart", "session_id": B, "cwd": "/tmp"})
owner.kill(); owner.wait()
fire(P, {"hook_event_name": "SessionEnd", "session_id": B, "reason": "prompt_input_exit"})
ck("P's binding still names A", open(f"{REC}/warp-bindings/{P}").read().strip() == f"/tmp\t{A}")
ck("P's warp-last still names A", open(f"{REC}/warp-last/{P}").read().strip() == f"/tmp\t{A}")

print("R8) history candidate with a deleted folder cannot leave the pane empty:")
shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
GONE_DIR = f"{tmp}/gone-dir"
transcript("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
hist(P, [(GONE_DIR, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 9000), ("/tmp", A, 1000)])
bind(P, "/tmp", A)
r = resolve(P)
ck("unlaunchable newer candidate ignored; binding A resumes", r == f"claude\t{A}")

print("R9) claim reaper leaves a LIVE other-epoch's claims alone:")
rl = load_lib()
e1, e2 = "warp-%d-%s" % (1, "X"), "warp-%d-%s" % (os.getpid(), "Y")
os.makedirs(f"{REC}/resuming/{e1}", exist_ok=True)
os.makedirs(f"{REC}/resuming/{e1}/{'11111111-2222-3333-4444-555555555555'}", exist_ok=True)
ck("claim under e2 succeeds", rl.claim_conversation(B, e2) is True)
ck("e1's live claim survived (dir still there)",
   os.path.exists(f"{REC}/resuming/{e1}/{'11111111-2222-3333-4444-555555555555'}"))

print("R10) warp-epoch --from-parent (as the hook calls it) walks ancestry:")
import stat
psdir = f"{tmp}/bin"; os.makedirs(psdir, exist_ok=True)
pshim = f"{psdir}/ps"
with open(pshim, "w") as fh:
    fh.write("#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in "
             "--parent-pid=777) exit 0;; esac; done\n"
             "if [ \"$1\" = \"-o\" ] && [ \"$2\" = \"ppid=,command=\" ]; then "
             "echo '1 /Applications/Warp.app/Contents/MacOS/stable terminal-server --parent-pid=777'; exit 0; fi\n"
             "if [ \"$1\" = \"-o\" ] && [ \"$2\" = \"pid=,lstart=\" ]; then "
             "echo '777 Sat Oct 31 14:09:33 2026'; exit 0; fi\nexit 0\n")
os.chmod(pshim, os.stat(pshim).st_mode | stat.S_IEXEC)
env = dict(os.environ, HOME=tmp, PATH=f"{psdir}:/usr/bin:/bin")
out = subprocess.run([sys.executable, LIB, "warp-epoch", "--from-parent"],
                     capture_output=True, text=True, env=env).stdout.strip()
ck("epoch came from the walked parent (777), not lowest-pid scan", out == "warp-777-SatOct311409332026")

print("M) mutants — each new guard is load-bearing:")
M = tempfile.mkdtemp()
def mutant(dst, old, new):
    s = open(HOOK).read()
    assert s.count(old) >= 1, f"pattern missing: {old!r}"
    open(dst, "w").write(s.replace(old, new, 1))

# M1: move the sdk-cli gate back below the stale branch (the shipped 613c4b0 order)
s = open(HOOK).read()
i_sdk = s.index('if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli":')
i_stale = s.index("if _stale_env_uuid(uuid, os.path.dirname(bdir)):")
assert i_sdk < i_stale, "sdk gate must sit above the stale branch in HEAD"
# extract the sdk block and re-insert it AFTER the stale branch's return
sdk_block_end = s.index("return", i_sdk)
sdk_block_end = s.index("\n", sdk_block_end) + 1
sdk_block = s[i_sdk:sdk_block_end]
s2 = s.replace(sdk_block, "", 1)
# Insert the sdk block AFTER the stale branch's `return` line. The block carries its
# own 8-space indent; find the return that ends the stale branch and splice after it.
stale_if = "if _stale_env_uuid(uuid, os.path.dirname(bdir)):"
pos = s2.index(stale_if)
ret_line = "\n            return\n"
stale_ret = s2.index(ret_line, pos) + len(ret_line)
mhook = f"{M}/m1.py"
open(mhook, "w").write(s2[:stale_ret] + "        " + sdk_block + s2[stale_ret:])
import ast as _ast
_ast.parse(open(mhook).read())   # the mutant must be valid python
shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
owner = foreign_owner(P)
fire(P, {"hook_event_name": "SessionStart", "session_id": TOOL, "cwd": "/tmp"},
     hook=mhook, entry="sdk-cli")
owner.kill(); owner.wait()
_h1 = f"{REC}/warp-history/{P}"
ck("M1: sdk-under-stale mutant IS caught (tool sid leaked into history)",
   os.path.exists(_h1) and TOOL in open(_h1).read())

# M2: drop the recency comparison (prefer history[0] whenever it differs) — the exact
# shipped 9d4baf8 condition. Build a lib mutant by stripping the two gate lines.
s = open(LIB).read()
old_gate = ("        if (hts is not None and bts is not None and hts > bts\n"
            "                and hmt is not None and bmt is not None and hmt > bmt\n"
            "                and UUID_RE.match(hsid)\n")
if old_gate in s:
    mlib = f"{M}/m2.py"
    open(mlib, "w").write(s.replace(old_gate,
        "        if (True\n                and UUID_RE.match(hsid)\n", 1))
    shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
    shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
    transcript(A); transcript(OLD)
    hist(P, [("/tmp", OLD, 1000), ("/tmp", A, 5000)])   # A newest, at file END
    bind(P, "/tmp", A)
    r = resolve(P, lib=mlib)
    ck("M2: no-recency-check mutant IS caught (older sid would win)",
       r == f"claude\t{OLD}")
else:
    ck("M2: recency gate pattern present in lib", False)

# M3: unconditional binding delete on quit (the shipped aaa9913..9d4baf8 behavior)
mhook3 = f"{M}/m3.py"
s = open(HOOK).read()
old3 = ("                for path in (bpath, lpath):\n"
        "                    try:\n"
        "                        with open(path) as fh:\n"
        "                            recorded = fh.read().strip().split(\"\\t\")\n"
        "                        if len(recorded) >= 2 and recorded[1] == sid:\n"
        "                            os.remove(path)\n")
if old3 in s:
    open(mhook3, "w").write(s.replace(old3,
        "                for path in (bpath, lpath):\n"
        "                    try:\n"
        "                        os.remove(path)\n", 1))
    shutil.rmtree(f"{REC}/warp-history"); os.makedirs(f"{REC}/warp-history")
    shutil.rmtree(f"{REC}/warp-quit"); os.makedirs(f"{REC}/warp-quit")
    transcript(A); transcript(B)
    bind(P, "/tmp", A)
    owner = foreign_owner(P)
    fire(P, {"hook_event_name": "SessionStart", "session_id": B, "cwd": "/tmp"})
    owner.kill(); owner.wait()
    fire(P, {"hook_event_name": "SessionEnd", "session_id": B, "reason": "prompt_input_exit"},
         hook=mhook3)
    ck("M3: unconditional-delete mutant IS caught (real binding would be wiped)",
       not os.path.exists(f"{REC}/warp-bindings/{P}"))
else:
    ck("M3: ownership-check pattern present in hook", False)

shutil.rmtree(M, ignore_errors=True)

print(f"\n{ok} passed, {fail} failed")
os.environ["HOME"] = HOME_BACKUP
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if fail else 0)
