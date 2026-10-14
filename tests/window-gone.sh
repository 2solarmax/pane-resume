#!/bin/zsh
# A restore must survive Warp closing or relaunching in the middle of it.
#
# Driver (2026-10-11): Max reopened Warp a minute into a restore. The queued resumes in the
# OLD run's shells kept launching for 2.5 minutes into terminals with no window — 76 agents
# nobody could see or type into. The NEW run's tabs then saw those invisible copies as
# "already running", stood down, and 21 of them stayed empty with nothing saying which
# conversation they held.
#
# Each behaviour is tested in both directions against the SHIPPED logic, plus mutants that
# prove each check can fail (red-team round 1 showed 3 of 4 mutants surviving an earlier
# version of this file, because it only exercised test overrides):
#   A. wait-slot refuses to launch when the Warp run the pane was born in has ENDED, or the
#      pane shell is orphaned — on the slot-grant path AND the give-up path — and launches
#      when the run is alive, the id is a boot-id fallback, or nothing can be read.
#   B. conversation-live ignores a REAL orphaned Warp-pane copy (parent = launchd, no
#      override), still stands down for an attached copy, and ignores the launchd signature
#      for a non-Warp process (Superset successor hand-off re-parents visible shells).
#   C. the hook passes --epoch only for a real warp-… run id; the stand-down line names the
#      conversation, never offers a reopen line (that would make a second visible copy), and
#      does not expand prompt escapes in the name.
#
# Isolation: fake HOME, fake agents (perl renamed to `claude --resume <id>`). Nothing outside
# this test is signalled.
setopt no_err_exit   # checks capture non-zero exits on purpose; failures are counted
SR="${1:-$HOME/pane-resume/superset-resume}"
LIB="${2:-$HOME/pane-resume/resume-lib.py}"
HOOK="${3:-${SR:h}/resume-hook.zsh}"
pass=0; fail=0
ck() {
  if [[ "$2" == "$3"* ]]; then print "  ok   $1"; pass=$((pass + 1))
  else print "  FAIL $1: got '$2' want '$3'*"; fail=$((fail + 1)); fi
}

TMP=$(mktemp -d); FAKES=()
cleanup() { for p in $FAKES; do kill $p 2>/dev/null; done; rm -rf $TMP }
trap cleanup EXIT
export HOME="$TMP"; mkdir -p "$TMP/.superset-recovery" "$TMP/.claude/projects/-tmp"
cp "$LIB" "$TMP/.superset-recovery/resume-lib.py"
[[ -f "${LIB:h}/titlelib.py" ]] && cp "${LIB:h}/titlelib.py" "$TMP/.superset-recovery/"
echo 1 > "$TMP/.superset-recovery/starting-cap"
freeslot() { command rm -rf "$TMP/.superset-recovery/starting" 2>/dev/null; return 0; }
LIVE=$(python3 "$LIB" warp-epoch)            # the REAL current Warp run (read-only)
DEAD="warp-999999-SunOct110000002026"        # a run whose pid does not exist
ws() {  # ws <epoch-or-empty> <label> [env...] -> exit code of wait-slot
  local ep="$1" lb="$2"; shift 2
  freeslot
  if [[ -n "$ep" ]]; then env "$@" bash "$SR" wait-slot --epoch "$ep" "$lb" </dev/null >/dev/null 2>&1
  else env "$@" bash "$SR" wait-slot "$lb" </dev/null >/dev/null 2>&1; fi
  echo $?
}

# ---------------------------------------------------------------------------------------
print "A. launch refused only when THIS tab's window is really gone (checked at wait end)"
TS="/Applications/Warp.app/Contents/MacOS/stable terminal-server --parent-pid=80549"
ck "window present (terminal-server's app alive) -> launches" \
   "$(ws warp-x a1 PANE_RESUME_TEST_SHELL_PPID=999 PANE_RESUME_TEST_TS_CMD="$TS" PANE_RESUME_TEST_LIVE_PIDS='80549')" "0"
ck "Warp app gone (window closed) -> refused (3)" \
   "$(ws warp-x a2 PANE_RESUME_TEST_SHELL_PPID=999 PANE_RESUME_TEST_TS_CMD="$TS" PANE_RESUME_TEST_LIVE_PIDS='')" "3"
ck "pane shell orphaned to launchd -> refused (3)" \
   "$(ws warp-x a3 PANE_RESUME_TEST_SHELL_PPID=1)" "3"
# N1: relaunch overlap — the queued id names the OLD app, but THIS tab belongs to the NEW one
ck "relaunch overlap: id names old app, tab's own app alive -> launches" \
   "$(ws warp-70001-OLD a6 PANE_RESUME_TEST_SHELL_PPID=999 PANE_RESUME_TEST_TS_CMD="${TS/80549/80777}" PANE_RESUME_TEST_LIVE_PIDS='80777')" "0"
ck "parent is not a Warp terminal-server (tmux etc) -> launches" \
   "$(ws warp-x a7 PANE_RESUME_TEST_SHELL_PPID=999 PANE_RESUME_TEST_TS_CMD='tmux: server' PANE_RESUME_TEST_LIVE_PIDS='')" "0"
ck "boot-id fallback epoch is never sent (hook) -> no check, launches" \
   "$(ws '' a4 PANE_RESUME_TEST_SHELL_PPID=1)" "0"
# Reviewer round-3 finding 2: the REAL liveness lines (kill -0 / ps -p on the app pid)
# never ran under test — every case overrode them. Run both directions with NO overrides.
REAL_TS_PID=$(ps -Ao pid=,command= | grep "Warp.app/Contents/MacOS/stable terminal-server" | grep -v grep | head -1 | awk '{print $1}')
if [[ -n "$REAL_TS_PID" ]]; then
  r=$(freeslot; PANE_RESUME_TEST_SHELL_PPID=$REAL_TS_PID bash "$SR" wait-slot --epoch warp-x a9 </dev/null >/dev/null 2>&1; echo $?)
  ck "no-override: real live terminal-server parent -> launches (0)" "$r" "0"
else
  print "  skip (no terminal-server running here)"
fi
r=$(freeslot; PANE_RESUME_TEST_SHELL_PPID=999 PANE_RESUME_TEST_TS_CMD="/Applications/Warp.app/Contents/MacOS/stable terminal-server --parent-pid=999999" bash "$SR" wait-slot --epoch warp-x a10 </dev/null >/dev/null 2>&1; echo $?)
ck "no-override: app pid gone -> refused (3)" "$r" "3"
grep -q "WINDOW-GONE a2 -> launch refused" "$TMP/.superset-recovery/resume.log" \
  && ck "refusal logged with its label" "yes" "yes" || ck "refusal logged with its label" "no" "yes"
r=$(freeslot; PANE_RESUME_TEST_SHELL_PPID=1 bash "$SR" wait-slot --epoch warp-x a8 </dev/null 2>&1 >/dev/null)
ck "refusal tells the tab, not just the log" "$(print -r -- $r | grep -c 'not resumed')" "1"
# give-up path (F2): every slot held by someone else + a 0s budget
freeslot; mkdir -p "$TMP/.superset-recovery/starting/0"; touch "$TMP/.superset-recovery/starting/0"
r=$(PANE_RESUME_TEST_SHELL_PPID=1 PANE_RESUME_TEST_BUDGET=0 bash "$SR" wait-slot --epoch warp-x giveup </dev/null >/dev/null 2>&1; echo $?)
ck "give-up path with window gone -> still refused (3)" "$r" "3"
ck "refusal never deletes a slot it does not own" "$(ls "$TMP/.superset-recovery/starting" | wc -l | tr -d ' ')" "1"

# ---------------------------------------------------------------------------------------
print "B. an invisible copy no longer leaves the visible tab empty (real process tree)"
SID=11111111-2222-3333-4444-555555555555
SIDNW=99999999-2222-3333-4444-555555555555        # a conversation with NO Warp record
mkdir -p "$TMP/.superset-recovery/warp-last"
print "/tmp\t$SID" > "$TMP/.superset-recovery/warp-last/aabbccddeeff00112233445566778899"
# a REAL orphan: a Warp-pane agent whose parent exits -> re-parented to launchd
( WARP_TERMINAL_SESSION_UUID=aabbccddeeff00112233445566778899 \
    env -i /usr/bin/perl -e '$0="claude --resume '$SID'"; sleep 60' & ) ; sleep 0.5
ORPH=$(pgrep -f "claude --resume $SID"); FAKES+=($ORPH)
ck "fixture really is orphaned (ppid 1)" "$(ps -o ppid= -p $ORPH | tr -d ' ')" "1"
ck "orphaned Warp copy -> tab restores (0)" "$(python3 "$LIB" conversation-live $SID)" "0"
grep -q "IGNORED-WINDOWLESS pid=$ORPH sid=$SID" "$TMP/.superset-recovery/resume.log" \
  && ck "ignored copy is logged" "yes" "yes" || ck "ignored copy is logged" "no" "yes"
# N2: the same orphan, but its transcript was JUST written -> it is busy -> stand down
print '{}' > "$TMP/.claude/projects/-tmp/$SID.jsonl"
ck "windowless but BUSY (written <30s ago) -> state 2 (wait, not stand-down)" "$(python3 "$LIB" conversation-live $SID)" "2"
touch -t 202001010000 "$TMP/.claude/projects/-tmp/$SID.jsonl"
ck "windowless and idle -> tab restores (0)" "$(python3 "$LIB" conversation-live $SID)" "0"
kill $ORPH 2>/dev/null
# attached copy: child of this test shell
WARP_TERMINAL_SESSION_UUID=aabbccddeeff00112233445566778899 env -i /usr/bin/perl -e '$0="claude --resume '$SID'"; sleep 60' & ATT=$!; FAKES+=($ATT); sleep 0.3
ck "attached Warp copy -> tab stands down (1)" "$(python3 "$LIB" conversation-live $SID)" "1"
kill $ATT 2>/dev/null; wait $ATT 2>/dev/null
# non-Warp orphan (Superset hand-off shape): launchd parent must NOT count as windowless
( env -i /usr/bin/perl -e '$0="claude --resume '$SIDNW'"; sleep 60' & ) ; sleep 0.5
SUP=$(pgrep -f "claude --resume $SIDNW"); FAKES+=($SUP)
ck "orphaned NON-Warp copy -> still counts as live (1)" "$(python3 "$LIB" conversation-live $SIDNW)" "1"
kill $SUP 2>/dev/null

# ---------------------------------------------------------------------------------------
print "C. hook wiring and the empty-tab line"
ck "hook passes --epoch only for a warp-… run id" "$(grep -c '"\$bootid" == warp-\*' "$HOOK")" "1"
ck "hook's epoch-wait line carries --epoch"        "$(grep -c 'wait-slot --epoch' "$HOOK")" "1"
SID2=22222222-3333-4444-5555-666666666666
print '{"type":"ai-title","aiTitle":"warm 100%F{red} outreach %~"}' > "$TMP/.claude/projects/-tmp/$SID2.jsonl"
fn=$(awk '/_pane_resume_explain\(\) \{/,/^    \}$/' "$HOOK")
out=$(zsh -c "lib=$TMP/.superset-recovery/resume-lib.py; $fn; _pane_resume_explain 'is already open in another tab — this one stays empty' $SID2" 2>&1)
ck "names the conversation, escapes NOT expanded" "$(print -r -- $out | grep -c 'warm 100%F{red} outreach %~')" "1"
ck "says why the tab is empty"                    "$(print -r -- $out | grep -c 'already open in another tab')" "1"
ck "offers NO reopen line (would duplicate)"      "$(print -r -- $out | grep -c 'cc all --resume')" "0"
ck "both stand-down paths call it"                "$(grep -c '_pane_resume_explain "is' "$HOOK")" "2"
ck "hook has the wait-for-hidden branch"      "$(grep -c 'WAIT-HIDDEN' "$HOOK")" "1"
ck "wait branch's reopen line is inside it"   "$(sed -n '/WAIT-HIDDEN/,/esac\|^      fi/p' "$HOOK" | grep -c 'cc all --resume')" "1"

print "D. the CD-wrapped line actually runs (2026-10-13: && was quote-escaped -> cd error)"
D="$TMP/dir with space"; mkdir -p "$D"
base=( echo CDLINE-OK )
# take the prefix construction VERBATIM from the shipped hook (not a re-typed copy)
pfx_line=$(grep -m1 '_PANE_RESUME_PREFIX="( cd -- ' "$HOOK" | sed 's/^ *typeset -g //')
[[ -n "$pfx_line" ]] || { print "  FAIL hook prefix line not found"; fail=$((fail+1)); }
_plan_parts=( CD "$D" ); eval "$pfx_line"; _PANE_RESUME_SUFFIX=" ; pwd )"
line="${_PANE_RESUME_PREFIX}${(j: :)${(q)base[@]}}${_PANE_RESUME_SUFFIX}"
out=$(zsh -c "D=${(qq)D}; eval ${(qq)line}" 2>&1)
ck "built line executes in the target dir" "$out" "CDLINE-OK
$D"
ck "no backslash-escaped && in the built line" "$(print -r -- $line | grep -c '\\\&\\\&')" "0"

# E: a HAND-STARTED session (registry, no --resume) must count as live (2026-10-13 a36e02ad)
SIDH=44444444-5555-6666-7777-888888888888
( perl -e '$0="claude"; sleep 60' & echo $! > "$TMP/fakepid" ); sleep 0.3
FAKEH=$(cat "$TMP/fakepid"); FAKES+=($FAKEH)
mkdir -p "$TMP/.claude/sessions"
printf '{"sessionId":"%s","pid":%s}' "$SIDH" "$FAKEH" > "$TMP/.claude/sessions/$FAKEH.json"
ck "hand-started live session -> stands down (1)" "$(python3 "$LIB" conversation-live $SIDH)" "1"
kill $FAKEH 2>/dev/null
printf '{"sessionId":"%s","pid":%s}' "$SIDH" 999999 > "$TMP/.claude/sessions/$FAKEH.json"
ck "registry entry with dead pid -> not live (0)" "$(python3 "$LIB" conversation-live $SIDH)" "0"

# F: a STRAY shell Warp hands to a new tab still carries an OLD tab's pane id (2026-10-14
# 12:00, 2026-10-13 14:17). If that pane's own shell is alive, the stray must do nothing.
print "F. a stray shell carrying another live tab's pane id stays silent"
PU=ccddeeff00112233445566778899aabb
mkdir -p "$TMP/.superset-recovery/warp-shell"
zsh -c 'sleep 60; :' & OWN=$!; FAKES+=($OWN); sleep 0.3
print -r -- "$OWN	trap1" > "$TMP/.superset-recovery/warp-shell/$PU"
ck "live owner shell of this run -> stray (1)"   "$(python3 "$LIB" pane-owned-elsewhere $PU $$)" "1"
ck "asking as the owner itself -> not stray (0)" "$(python3 "$LIB" pane-owned-elsewhere $PU $OWN)" "0"
touch -t 202001010000 "$TMP/.superset-recovery/warp-shell/$PU"
ck "owner younger than its record (reused pid) -> 0" "$(python3 "$LIB" pane-owned-elsewhere $PU $$)" "0"
touch "$TMP/.superset-recovery/warp-shell/$PU"
perl -e '$0="notashell"; sleep 60' & NS=$!; FAKES+=($NS); sleep 0.3
print -r -- "$NS	trap1" > "$TMP/.superset-recovery/warp-shell/$PU"
ck "registered pid is not a shell (reused) -> 0" "$(python3 "$LIB" pane-owned-elsewhere $PU $$)" "0"
kill $NS 2>/dev/null; wait $NS 2>/dev/null
print -r -- "$NS	trap1" > "$TMP/.superset-recovery/warp-shell/$PU"
ck "registered owner dead -> 0"                 "$(python3 "$LIB" pane-owned-elsewhere $PU $$)" "0"
ck "no registration at all -> unknown (-1)"     "$(python3 "$LIB" pane-owned-elsewhere aaaa0000aaaa0000aaaa0000aaaa0000 $$)" "-1"
# the shipped hook, run as a real interactive shell under the stray's pane id
print -r -- "$OWN	trap1" > "$TMP/.superset-recovery/warp-shell/$PU"
mkdir -p "$TMP/.superset-recovery/warp-last"; print "/tmp\t$SID2" > "$TMP/.superset-recovery/warp-last/$PU"
hookrun() { env -i HOME="$TMP" PATH="$PATH" TERM_PROGRAM=WarpTerminal WARP_TERMINAL_SESSION_UUID=$PU \
  zsh -f -i -c "source ${(qq)1}" 2>&1 </dev/null; }
out=$(hookrun "$HOOK")
ck "stray shell: no tab title printed"           "$(print -r -- $out | grep -c 'outreach')" "0"
ck "stray shell: owner's registration kept"      "$(cut -f1 "$TMP/.superset-recovery/warp-shell/$PU")" "$OWN"
ck "stray shell: logged why it stayed silent"    "$(grep -c "pid=.* reason=stray-shell-pane-already-owned" "$TMP/.superset-recovery/resume.log")" "1"
kill $OWN 2>/dev/null; wait $OWN 2>/dev/null
out=$(hookrun "$HOOK")
ck "owner gone: same pane titles itself normally" "$(print -r -- $out | grep -c 'outreach')" "1"

# ---------------------------------------------------------------------------------------
print "mutants -- would the checks above catch each broken version?"
M="$TMP/mut"; mkdir -p $M
mutant() { python3 "${LIB:h}/tests/mutate.py" "$@" >/dev/null || { print "  FAIL mutant did not apply: $2"; fail=$((fail+1)); return 1; }; }
mutant "$SR" $M/sr5 '  [[ "$ts_cmd" =~ --parent-pid=([0-9]+) ]] || return 1' '  return 1'
r=$(freeslot; PANE_RESUME_TEST_SHELL_PPID=999 PANE_RESUME_TEST_TS_CMD="$TS" PANE_RESUME_TEST_LIVE_PIDS='' bash $M/sr5 wait-slot --epoch warp-x m5 </dev/null >/dev/null 2>&1; echo $?); freeslot
ck "M5 app-gone check removed -> A catches it (launches)" "$r" "0"


mutant "$SR" $M/sr1 '  if _pane_window_gone; then' '  if false; then'
r=$(freeslot; PANE_RESUME_TEST_SHELL_PPID=1 bash $M/sr1 wait-slot --epoch warp-x m1 </dev/null >/dev/null 2>&1; echo $?); freeslot
ck "M1 refusal gate removed -> A catches it (launches)" "$r" "0"
mutant "$SR" $M/sr2 '        if _refuse_if_window_gone; then _drain_tty; exit 3; fi' '        :'
freeslot; mkdir -p "$TMP/.superset-recovery/starting/0"
r=$(PANE_RESUME_TEST_SHELL_PPID=1 PANE_RESUME_TEST_BUDGET=0 bash $M/sr2 wait-slot --epoch warp-x m2 </dev/null >/dev/null 2>&1; echo $?); freeslot
ck "M2 give-up path unchecked -> A catches it (launches)" "$r" "0"
python3 "${LIB:h}/tests/mutate.py" "$HOOK" $M/hook6 '"( cd -- ${(q)_plan_parts[2]} && "' '"( cd -- ${(q)_plan_parts[2]} \\&\\& "' >/dev/null || { print "  FAIL M6 did not apply"; fail=$((fail+1)); }
pfx6=$(grep -m1 '_PANE_RESUME_PREFIX="( cd -- ' $M/hook6 | sed 's/^ *typeset -g //')
_plan_parts=( CD "$D" ); eval "$pfx6"
line6="${_PANE_RESUME_PREFIX}${(j: :)${(q)base[@]}}${_PANE_RESUME_SUFFIX}"
out6=$(zsh -c "eval ${(qq)line6}" 2>&1)
ck "M6 escaped && restored -> D catches it (cd error)" "$(print -r -- $out6 | grep -c 'too many arguments')" "1"
mutant "$LIB" $M/lib3.py '            if ppid == 1:
                return False' '            if ppid == 1:
                return True'
( WARP_TERMINAL_SESSION_UUID=aabbccddeeff00112233445566778899 env -i /usr/bin/perl -e '$0="claude --resume '$SID'"; sleep 60' & ); sleep 0.5
O3=$(pgrep -f "claude --resume $SID"); FAKES+=($O3)
ck "M3 launchd treated as window -> B catches it (1)" "$(python3 $M/lib3.py conversation-live $SID)" "1"
kill $O3 2>/dev/null
mutant "$LIB" $M/lib4.py '        elif not _sid_has_warp_record(sid):
            return True                        # env unreadable, no Warp record: not ours to judge' '        elif not _sid_has_warp_record(sid):
            return False'
( env -i /usr/bin/perl -e '$0="claude --resume '$SIDNW'"; sleep 60' & ); sleep 0.5
O4=$(pgrep -f "claude --resume $SIDNW"); FAKES+=($O4)
ck "M4 record guard inverted -> B catches it (0)" "$(python3 $M/lib4.py conversation-live $SIDNW)" "0"
kill $O4 2>/dev/null

cp "$LIB" $M/resume-lib.py
python3 "${LIB:h}/tests/mutate.py" "$LIB" $M/lib7.py '        if not mine or mine != theirs:
            return 0
    except Exception:
        return -1
    return 1' '        if not mine or mine != theirs:
            return 0
    except Exception:
        return -1
    return 0' >/dev/null || { print "  FAIL M7 did not apply"; fail=$((fail+1)); }
zsh -c 'sleep 60; :' & O7=$!; FAKES+=($O7); sleep 0.3
print -r -- "$O7	trap1" > "$TMP/.superset-recovery/warp-shell/$PU"
ck "M7 owner never detected -> F catches it (0)" "$(python3 $M/lib7.py pane-owned-elsewhere $PU $$)" "0"
python3 "${LIB:h}/tests/mutate.py" "$HOOK" $M/hook8 '  (( _pane_resume_stray_shell )) || () {' '  () {' >/dev/null || { print "  FAIL M8 did not apply"; fail=$((fail+1)); }
out8=$(hookrun $M/hook8)
ck "M8 hook ignores stray flag -> F catches it (title printed)" "$(print -r -- $out8 | grep -c 'outreach')" "1"
kill $O7 2>/dev/null

print "result: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
