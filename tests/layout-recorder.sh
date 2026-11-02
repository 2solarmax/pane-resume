#!/bin/zsh
# layout-recorder.sh — the layout record + restore must actually work (2026-11-02).
#
# Covers the two tools the owner approved on 2026-11-02 ("keep our own record of open
# tabs, groups and their conversations, saved every few minutes"):
#   warp-layout-recorder.py — snapshots Warp's tabs/groups/conversations
#   warp-layout-restore     — reopens the recorded-but-missing conversations
#
# Fails on the half-verified traps this task already hit once:
#   - a report/record that "exists" but writes nothing (the 790137d report defect)
#   - a guard command whose quoting breaks the generated TOML
#   - the throttle letting zero or two recorders through

set -u
here="${0:A:h}"
repo="$here/.."
fails=0; tests=0
ok()  { tests=$((tests+1)); echo "  ok   $1" }
bad() { tests=$((tests+1)); fails=$((fails+1)); echo "  FAIL $1" }
box="$(mktemp -d "${TMPDIR:-/tmp}/layout-recorder.XXXXXX")"
# The restore skips conversations whose folder is under a temp root (by design: a
# throwaway, not a project), so the fake PROJECT must live outside temp.
proj="$(mktemp -d "$HOME/.layout-recorder-test.XXXXXX")"

# ---- 1) recorder against a synthetic Warp sqlite --------------------------------
mkdir -p "$box/home/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable"
mkdir -p "$box/home/.superset-recovery/warp-bindings"
DB="$box/home/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
sqlite3 "$DB" "CREATE TABLE windows(id INTEGER PRIMARY KEY); CREATE TABLE tab_groups(id INTEGER PRIMARY KEY, window_id INTEGER, name TEXT, color TEXT, collapsed BOOLEAN, pinned BOOLEAN); CREATE TABLE tabs(id INTEGER PRIMARY KEY, window_id INTEGER, custom_title TEXT, color TEXT, tab_group_id INTEGER, pinned BOOLEAN); CREATE TABLE pane_nodes(id INTEGER PRIMARY KEY, tab_id INTEGER, parent_pane_node_id INTEGER, flex FLOAT, is_leaf BOOLEAN); CREATE TABLE terminal_panes(id INTEGER PRIMARY KEY, kind TEXT, uuid BLOB, cwd TEXT, is_active BOOLEAN, shell_launch_data BLOB, input_config BLOB, llm_model_override TEXT, active_profile_id TEXT, conversation_ids BLOB, active_conversation_id BLOB);"
sqlite3 "$DB" "INSERT INTO windows VALUES (1); INSERT INTO tab_groups VALUES (10,1,'HW DEV','blue',0,0); INSERT INTO tabs VALUES (1,1,'alpha',NULL,10,0),(2,1,NULL,NULL,NULL,0); INSERT INTO pane_nodes VALUES (100,1,NULL,1,1); INSERT INTO terminal_panes VALUES (100,'x', x'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', '$proj', 1,NULL,NULL,NULL,NULL,NULL,NULL);"
printf '/tmp/proj\t11111111-1111-1111-1111-111111111111' > "$box/home/.superset-recovery/warp-bindings/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
env HOME="$box/home" python3 "$repo/warp-layout-recorder.py" >/dev/null 2>&1
if [[ -s "$box/home/.superset-recovery/layout-snapshots/current.json" ]]; then
  ok "current.json written"
  python3 - "$box/home/.superset-recovery/layout-snapshots/current.json" <<'PY' && ok "snapshot content: group, tab order, pane session" || bad "snapshot content wrong"
import json,sys
s=json.load(open(sys.argv[1]))
w=s["windows"][0]
assert w["groups"][0]["name"]=="HW DEV" and w["groups"][0]["color"]=="blue"
t0,t1=w["tabs"][0],w["tabs"][1]
assert t0["title"]=="alpha" and t0["group_id"]==10 and t1["group_id"] is None
assert t0["panes"][0]["session"].startswith("11111111")
PY
else
  bad "current.json NOT written"
fi

# ---- 2) throttle: exactly one of N simultaneous recorders -----------------------
rm -f "$box/home/.superset-recovery/layout-snapshots/.last-run" "$box/home/.superset-recovery/layout-snapshots/.last-run.claim" "$box/home/.superset-recovery/layout-snapshots/archive.jsonl"
python3 - "$box" "$repo" <<'PY' && ok "throttle: exactly one winner among 8 racers" || bad "throttle allowed zero or many"
import os,subprocess,sys
box,repo=sys.argv[1],sys.argv[2]
env={**os.environ,"HOME":box+"/home"}
ps=[subprocess.Popen([sys.executable,repo+"/warp-layout-recorder.py","--if-due"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) for _ in range(8)]
for p in ps:
    p.wait()
n=sum(1 for _ in open(box+"/home/.superset-recovery/layout-snapshots/archive.jsonl"))
sys.exit(0 if n==1 else 1)
PY

# ---- 3) restore: guard + TOML validity + skip-live ------------------------------
mkdir -p "$box/home/.warp/tab_configs" "$box/bin"
cat > "$box/home/.superset-recovery/resume-lib.py" <<'PY'
import sys
a=sys.argv
LIVE=("22222222",)
if a[1]=="conversation-live": print(1 if a[2][:8] in LIVE else 0)
elif a[1]=="label": print("Conv "+a[2][:8])
PY
cp "$box/home/.superset-recovery/layout-snapshots/current.json" "$box/home/.superset-recovery/layout-snapshots/current.json.bak"
python3 - "$box/home/.superset-recovery/layout-snapshots/current.json" "$proj" <<'PY'
import json,sys
proj=sys.argv[2]
snap={"ts":"t","windows":[{"id":1,
  "groups":[{"id":10,"window_id":1,"name":"HW DEV","color":None,"collapsed":False,"pinned":False}],
  "tabs":[{"id":1,"window_id":1,"title":"alpha","color":None,"group_id":10,"pinned":False,
    "panes":[{"uuid":"a"*32,"cwd":proj,"session":"11111111-1111-1111-1111-111111111111"},
             {"uuid":"b"*32,"cwd":proj,"session":"22222222-2222-2222-2222-222222222222"}]}]}]}
json.dump(snap,open(sys.argv[1],"w"))
PY
printf '#!/bin/sh\necho "$@" >> %s/opened.log\n' "$box" > "$box/bin/open"; chmod +x "$box/bin/open"
printf '#!/bin/sh\n:\n' > "$box/bin/sleep"; chmod +x "$box/bin/sleep"
sed "s#sys.executable#sys.executable#" "$repo/warp-layout-restore" > "$box/wl.py"
env HOME="$box/home" PATH="$box/bin:$PATH" python3 "$box/wl.py" --open > "$box/out.txt" 2>&1
[[ -n "${LAYOUT_TEST_DEBUG:-}" ]] && cat "$box/out.txt"
grep -q "1 already running" "$box/out.txt" && ok "restore skips the live conversation" || bad "restore did not skip the live one"
grep -q "1 missing" "$box/out.txt" && ok "restore counts the missing one" || bad "restore miscounted missing"
if [[ -f "$box/opened.log" ]] && grep -q "warp://tab_config/restore_11111111" "$box/opened.log"; then
  ok "restore opened the missing conversation via tab config"
else
  bad "restore did not open the missing conversation"
fi
python3 - "$box/home/.warp/tab_configs/restore_11111111.toml" <<'PY' && ok "generated TOML parses; guard runs before the resume" || bad "generated TOML or guard command broken"
import sys,tomllib,shlex
d=tomllib.load(open(sys.argv[1],"rb"))
cmd=d["panes"][0]["commands"][0]
parts=shlex.split(cmd)
assert any(p=="guard" for p in parts) and "--resume" in parts
assert parts[-1].startswith("11111111")
PY

# ---- 4) restore refuses to act when it cannot tell what is open -----------------
# The probe answers label lookups fine but FAILS the liveness check, so the only thing
# that can stop an open is the refusal itself (no vacuous pass from an empty plan).
cat > "$box/home/.superset-recovery/resume-lib.py" <<'PY'
import sys
a=sys.argv
if a[1]=="label": print("Conv "+a[2][:8]); sys.exit(0)
sys.exit(3)   # liveness probe failure: restore must not guess
PY
rm -f "$box/opened.log" "$box/home/.warp/tab_configs/"*.toml(N)
env HOME="$box/home" PATH="$box/bin:$PATH" python3 "$box/wl.py" --open > "$box/out2.txt" 2>&1
rc=$?
if grep -q "Cannot tell" "$box/out2.txt" && [[ ! -f "$box/opened.log" ]] && (( rc != 0 )); then
  ok "probe failure -> refuses to open, says so, exits non-zero"
else
  bad "probe failure: refusal message/exit missing or something was opened"
fi

# ---- 5) open-time recheck: a conversation reopened BETWEEN plan and open is skipped
# The probe says "not live" on the plan pass and "live" on the open-time recheck,
# simulating the owner reopening it by hand while the restore runs.
cat > "$box/home/.superset-recovery/resume-lib.py" <<'PY'
import sys,os
a=sys.argv
if a[1]=="label": print("Conv "+a[2][:8]); sys.exit(0)
if a[1]=="conversation-live":
    if a[2][:8]=="22222222": print(1); sys.exit(0)
    seen=os.path.join(os.environ["HOME"],".probe-seen-"+a[2][:8])
    if os.path.exists(seen): print(1)
    else:
        open(seen,"w").close(); print(0)
PY
rm -f "$box/opened.log" "$box/home/.probe-seen-"*(N)
env HOME="$box/home" PATH="$box/bin:$PATH" python3 "$box/wl.py" --open > "$box/out3.txt" 2>&1
if grep -q "became open while this was running" "$box/out3.txt" && [[ ! -f "$box/opened.log" ]]; then
  ok "open-time recheck skips a conversation reopened mid-restore"
else
  bad "open-time recheck missing: opened a conversation that became live mid-restore"
fi

# ---- 6) throttle claim is exclusive even with an expired window ------------------
# Pre-age the stamp so EVERY racer sees the window as expired. The instrumented racer
# holds 0.3s AFTER winning the claim, BEFORE the re-check — the tightest overlap: with a
# non-exclusive claim (O_CREAT only) two holders sit inside together, both pass the
# re-check (stamp still unwritten), and both snapshot. Exactly-one archive line must hold.
rm -f "$box/home/.superset-recovery/layout-snapshots/archive.jsonl" "$box/home/.superset-recovery/layout-snapshots/.last-run.claim"
touch -t 202001010000 "$box/home/.superset-recovery/layout-snapshots/.last-run"
python3 - "$box" "$repo" <<'PY' && ok "throttle: O_EXCL claim admits one racer when the window has expired" || bad "throttle claim not exclusive"
import os,subprocess,sys,time
box,repo=sys.argv[1],sys.argv[2]
env={**os.environ,"HOME":box+"/home"}
code=open(repo+"/warp-layout-recorder.py").read()
code=code.replace("def snapshot():","def snapshot():\n    return {'ts':'t','windows':[]}",1)
code=code.replace("    os.close(fd)\n","    os.close(fd)\n    time.sleep(0.3)\n",1)
open(box+"/slow-recorder.py","w").write(code)
assert "time.sleep(0.3)" in code, "race-hold anchor missing"
import ast; ast.parse(code)
ps=[subprocess.Popen([sys.executable,box+"/slow-recorder.py","--if-due"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) for _ in range(12)]
for p in ps: p.wait()
a=box+"/home/.superset-recovery/layout-snapshots/archive.jsonl"
n=sum(1 for _ in open(a)) if os.path.exists(a) else 0
sys.exit(0 if n==1 else 1)
PY

# ---- 7) fast path: inside the window, --if-due never even creates a claim file ------
# The pre-claim stamp check is the cheap path every prompt in every tab takes. Without
# it the recorder is still correct (the re-check under the claim enforces the window)
# but creates and deletes a claim file on every prompt. Pin the cheap path itself.
rm -f "$box/home/.superset-recovery/layout-snapshots/.last-run.claim"
touch "$box/home/.superset-recovery/layout-snapshots/.last-run"
python3 - "$box" "$repo" <<'PY' && ok "fast path: in-window --if-due touches no claim file" || bad "fast path missing: claim file churned inside the window"
import os,subprocess,sys
box,repo=sys.argv[1],sys.argv[2]
d=box+"/home/.superset-recovery/layout-snapshots"
code=open(repo+"/warp-layout-recorder.py").read()
# instrument: record every claim-file creation attempt
code=code.replace("    claim = STAMP + \".claim\"","    claim = STAMP + \".claim\"\n    open(os.path.join(SNAP_DIR,'.claim-attempts'),'a').write('x')",1)
open(box+"/inst.py","w").write(code)
env={**os.environ,"HOME":box+"/home"}
for _ in range(3):
    subprocess.run([sys.executable,box+"/inst.py","--if-due"],env=env)
sys.exit(1 if os.path.exists(d+"/.claim-attempts") else 0)
PY

# ---- 8) AUTO mode: transient probe failure retries and then opens ----------------
# Tests 6/7 left an EMPTY snapshot behind (their stub recorder writes windows=[]), so
# re-seed one recorded-but-missing conversation for the auto tests to restore.
python3 - "$box/home/.superset-recovery/layout-snapshots/current.json" "$proj" <<'PY'
import json,sys
snap={"ts":"t","windows":[{"id":1,"groups":[],"tabs":[{"id":1,"window_id":1,"title":None,
  "color":None,"group_id":None,"pinned":False,
  "panes":[{"uuid":"e"*32,"cwd":sys.argv[2],"session":"66666666-6666-6666-6666-666666666666"}]}]}]}
json.dump(snap,open(sys.argv[1],"w"))
PY
cat > "$box/home/.superset-recovery/resume-lib.py" <<'PY'
import sys,os
a=sys.argv
C=os.path.join(os.environ["HOME"],".probe-count")
n=int(open(C).read()) if os.path.exists(C) else 0
open(C,"w").write(str(n+1))
if a[1]=="label": print("Conv "+a[2][:8]); sys.exit(0)
if n<2: sys.exit(3)          # first two liveness probes fail (restore wave still starting)
print(0)
PY
rm -f "$box/opened.log" "$box/home/.probe-count"(N) "$box/home/.warp/tab_configs/"*.toml(N)
python3 - "$box" "$repo" <<'PY' && ok "auto mode: retries a transient probe failure, then opens" || bad "auto mode gave up or opened wrongly"
import os,subprocess,sys
box,repo=sys.argv[1],sys.argv[2]
src=open(repo+"/warp-layout-restore").read().replace("sys.executable","sys.executable")
src=src.replace("for wait in (20, 40, 60):","for wait in (0, 0, 0):")
open(box+"/wl-auto.py","w").write(src)
env={**os.environ,"HOME":box+"/home","PATH":box+"/bin:"+os.environ["PATH"]}
r=subprocess.run([sys.executable,box+"/wl-auto.py","--open","--auto"],capture_output=True,text=True,env=env)
import os as _o
if _o.environ.get("LAYOUT_TEST_DEBUG"): print("DBG rc",r.returncode,"| out:",r.stdout[-200:].replace(chr(10)," "),"| err:",r.stderr[-300:])
opened=os.path.exists(box+"/opened.log")
alog=os.path.exists(box+"/home/.superset-recovery/auto-restore.log")
sys.exit(0 if (opened and alog and r.returncode==0) else 1)
PY

# ---- 9) AUTO mode: a probe that never settles opens NOTHING ----------------------
cat > "$box/home/.superset-recovery/resume-lib.py" <<'PY'
import sys
a=sys.argv
if a[1]=="label": print("Conv "+a[2][:8]); sys.exit(0)
sys.exit(3)
PY
rm -f "$box/opened.log"(N)
python3 - "$box" "$repo" <<'PY' && ok "auto mode: unsettled probe -> nothing opened, logged, non-zero" || bad "auto mode opened despite an unsettled probe"
import os,subprocess,sys
box,repo=sys.argv[1],sys.argv[2]
src=open(repo+"/warp-layout-restore").read().replace("for wait in (20, 40, 60):","for wait in (0, 0, 0):")
open(box+"/wl-auto2.py","w").write(src)
env={**os.environ,"HOME":box+"/home","PATH":box+"/bin:"+os.environ["PATH"]}
r=subprocess.run([sys.executable,box+"/wl-auto2.py","--open","--auto"],capture_output=True,text=True,env=env)
opened=os.path.exists(box+"/opened.log")
logged=os.path.exists(box+"/home/.superset-recovery/auto-restore.log")
sys.exit(0 if ((not opened) and logged and r.returncode!=0) else 1)
PY

rm -rf "$box" "$proj"
echo "result: $((tests - fails)) passed, $fails failed"
exit $(( fails > 0 ))
