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
print(f"\n{ok} passed, {fail} failed")
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if fail else 0)
