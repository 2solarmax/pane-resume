# Exercise warp-session-hook.py's SessionEnd: deliberate quit drops the binding, crash
# keeps it, resume keeps it, and a live-twin quit keeps it.
import json, os, subprocess, sys, tempfile, shutil
HOME_BACKUP = os.environ.get("HOME")
tmp = tempfile.mkdtemp()
os.environ["HOME"] = tmp
os.makedirs(f"{tmp}/.superset-recovery/warp-bindings")
os.makedirs(f"{tmp}/.superset-recovery/warp-last")
HOOK = "/Users/maxkrasnykh/pane-resume/warp-session-hook.py"
PANE = "aabbccddeeff00112233445566778899"
SID = "11111111-2222-3333-4444-555555555555"
def setup():
    rec = f"/tmp\tx\n"  # placeholder; real record written by SessionStart below
    for d in ("warp-bindings","warp-last"):
        with open(f"{tmp}/.superset-recovery/{d}/{PANE}","w") as f: pass
def fire(ev, payload):
    env = dict(os.environ, TERM_PROGRAM="WarpTerminal", WARP_TERMINAL_SESSION_UUID=PANE)
    # the hook writes records as "cwd\tsid\n" via SessionStart; emulate a bound pane:
    if ev=="SessionStart":
        with open(f"{tmp}/.superset-recovery/warp-bindings/{PANE}","w") as f: f.write(f"/tmp\t{SID}\n")
        with open(f"{tmp}/.superset-recovery/warp-last/{PANE}","w") as f: f.write(f"/tmp\t{SID}\n")
    r = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), env=env, capture_output=True, text=True)
    return r
def bound():
    return os.path.exists(f"{tmp}/.superset-recovery/warp-bindings/{PANE}") and \
           os.path.exists(f"{tmp}/.superset-recovery/warp-last/{PANE}")
ok=0; fail=0
def ck(name, cond):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ")+name); ok,fail=(ok+1,fail) if cond else (ok,fail+1)
# no sessions dir -> _sid_live_elsewhere fails toward "keep" (conservative)
os.makedirs(f"{tmp}/.claude/sessions", exist_ok=True)  # empty registry
print("1) deliberate quit (prompt_input_exit), no live twin:")
setup(); fire("SessionStart", {"hook_event_name":"SessionStart","session_id":SID,"cwd":"/tmp"})
fire("SessionEnd", {"hook_event_name":"SessionEnd","session_id":SID,"reason":"prompt_input_exit"})
ck("binding dropped", not bound())
print("2) crash-style end (reason=other):")
setup(); fire("SessionStart", {"hook_event_name":"SessionStart","session_id":SID,"cwd":"/tmp"})
fire("SessionEnd", {"hook_event_name":"SessionEnd","session_id":SID,"reason":"other"})
ck("binding kept", bound())
print("3) resume end:")
setup(); fire("SessionStart", {"hook_event_name":"SessionStart","session_id":SID,"cwd":"/tmp"})
fire("SessionEnd", {"hook_event_name":"SessionEnd","session_id":SID,"reason":"resume"})
ck("binding kept", bound())
# 4-6 + mutant: SessionStart must refuse to write when the env pane id is STALE —
# warp-shell/<uuid> names a live owner shell that is not an ancestor of this process
# (claude inside a stray pre-warmed shell, 2026-10-14). Legit cases (owner is the
# parent shell; owner dead) must still write.
import time as _time
NEW_SID = "99999999-8888-7777-6666-555555555555"
OLD_SID = "77777777-7777-7777-7777-777777777777"
def seed_old():
    os.makedirs(f"{tmp}/.superset-recovery/warp-shell", exist_ok=True)
    for d in ("warp-bindings","warp-last"):
        with open(f"{tmp}/.superset-recovery/{d}/{PANE}","w") as f: f.write(f"/tmp\t{OLD_SID}\n")
def fire_raw(payload, hook=HOOK):
    env = dict(os.environ, TERM_PROGRAM="WarpTerminal", WARP_TERMINAL_SESSION_UUID=PANE)
    return subprocess.run([sys.executable, hook], input=json.dumps(payload), env=env, capture_output=True, text=True)
def rec(d):
    try: return open(f"{tmp}/.superset-recovery/{d}/{PANE}").read()
    except OSError: return ""

print("4) SessionStart under a STALE uuid (live foreign owner shell):")
seed_old()
owner = subprocess.Popen(["zsh","-c","sleep 60; :"]); _time.sleep(0.6)
with open(f"{tmp}/.superset-recovery/warp-shell/{PANE}","w") as f: f.write(f"{owner.pid}\ttrap1\n")
fire_raw({"hook_event_name":"SessionStart","session_id":NEW_SID,"cwd":"/tmp"})
ck("binding untouched", rec("warp-bindings") == f"/tmp\t{OLD_SID}\n")
ck("warp-last untouched", rec("warp-last") == f"/tmp\t{OLD_SID}\n")
ck("history not polluted", NEW_SID not in open(f"{tmp}/.superset-recovery/warp-history/{PANE}").read() if os.path.exists(f"{tmp}/.superset-recovery/warp-history/{PANE}") else True)
owner.kill(); owner.wait()

print("5) SessionStart under the pane's OWN shell (owner is an ancestor):")
seed_old()
pidfile, gofile = f"{tmp}/ownerpid", f"{tmp}/go"
env5 = dict(os.environ, TERM_PROGRAM="WarpTerminal", WARP_TERMINAL_SESSION_UUID=PANE)
p5 = subprocess.Popen(["zsh","-f","-c",f"echo $$ > {pidfile}; while [[ ! -e {gofile} ]]; do sleep 0.05; done; {sys.executable} {HOOK}"],
                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env5, text=True)
for _ in range(200):
    if os.path.exists(pidfile): break
    _time.sleep(0.05)
zpid = int(open(pidfile).read().strip())
with open(f"{tmp}/.superset-recovery/warp-shell/{PANE}","w") as f: f.write(f"{zpid}\ttrap1\n")
open(gofile,"w").close()
p5.communicate(input=json.dumps({"hook_event_name":"SessionStart","session_id":NEW_SID,"cwd":"/tmp"}), timeout=60)
ck("binding written for this session", rec("warp-bindings") == f"/tmp\t{NEW_SID}\n")

print("6) SessionStart when the registered owner is DEAD:")
seed_old()
with open(f"{tmp}/.superset-recovery/warp-shell/{PANE}","w") as f: f.write("999999\ttrap1\n")
fire_raw({"hook_event_name":"SessionStart","session_id":NEW_SID,"cwd":"/tmp"})
ck("binding written (dead owner does not block)", rec("warp-bindings") == f"/tmp\t{NEW_SID}\n")

print("M) mutant: stale-uuid guard disabled -> suppression must vanish:")
M = tempfile.mkdtemp()
mhook = f"{M}/warp-session-hook.py"
subprocess.run([sys.executable, "/Users/maxkrasnykh/pane-resume/tests/mutate.py", HOOK, mhook,
                "if _stale_env_uuid(uuid, os.path.dirname(bdir)):",
                "if False and _stale_env_uuid(uuid, os.path.dirname(bdir)):"], check=True)
seed_old()
owner = subprocess.Popen(["zsh","-c","sleep 60; :"]); _time.sleep(0.6)
with open(f"{tmp}/.superset-recovery/warp-shell/{PANE}","w") as f: f.write(f"{owner.pid}\ttrap1\n")
fire_raw({"hook_event_name":"SessionStart","session_id":NEW_SID,"cwd":"/tmp"}, hook=mhook)
ck("mutant overwrites (guard is load-bearing)", rec("warp-bindings") == f"/tmp\t{NEW_SID}\n")
owner.kill(); owner.wait()
shutil.rmtree(M, ignore_errors=True)

print(f"\n{ok} passed, {fail} failed")
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if fail else 0)
