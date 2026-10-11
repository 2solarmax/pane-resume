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
ck "windowless but BUSY (written <30s ago) -> stands down (1)" "$(python3 "$LIB" conversation-live $SID)" "1"
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

print "result: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
