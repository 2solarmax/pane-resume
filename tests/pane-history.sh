#!/bin/zsh
# A pane keeps a HISTORY of its recent sessions; when the bound session's transcript is
# gone, the resolver falls back to the pane's previous still-resumable session.
#
# Driver (2026-08-31): a seconds-old crash-debris session evicted the maxpool binding;
# its transcript was gone; the pane refused to resume; maxpool was hand-restored. With
# history, the pane would have fallen back to maxpool automatically.
#
# Both directions are covered, plus the mutants that would make these tests vacuous.
set -e
HOOK="${1:-$HOME/pane-resume/warp-session-hook.py}"
LIB="${2:-$HOME/pane-resume/resume-lib.py}"
pass=0; fail=0
ck() { if [[ "$2" == "$3"* ]]; then print "  ok   $1"; pass=$((pass+1)); else print "  FAIL $1: got '$2' want '$3'*"; fail=$((fail+1)); fi }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
export HOME="$TMP"
mkdir -p "$TMP/.superset-recovery" "$TMP/.claude/projects/-private-tmp"
PANE=aabbccddeeff00112233445566778899
MAXSID=11111111-2222-3333-4444-555555555555
DEBRIS=99999999-8888-7777-6666-555555555555
fire() {  # fire <event> <json>
  local ev="$1" js="$2"
  print -r -- "$js" | env HOME="$TMP" TERM_PROGRAM=WarpTerminal \
      WARP_TERMINAL_SESSION_UUID=$PANE python3 "$HOOK"
}
mktranscript() { print '{"type":"user"}' > "$TMP/.claude/projects/-private-tmp/$1.jsonl" }

print "history write (SC1, SC5)"
mktranscript $MAXSID
fire SessionStart "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$MAXSID\",\"cwd\":\"/tmp\"}"
H="$TMP/.superset-recovery/warp-history/$PANE"
ck "history created with 1 entry" "$(wc -l < $H | tr -d ' ')" "1"
fire SessionStart "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$DEBRIS\",\"cwd\":\"/tmp\"}"
ck "second session prepended, maxpool kept" "$(wc -l < $H | tr -d ' ')" "2"
ck "newest first" "$(head -1 $H | cut -f2 | cut -c1-8)" "99999999"
fire SessionStart "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$MAXSID\",\"cwd\":\"/tmp\"}"
ck "re-run dedups (SC5)" "$(wc -l < $H | tr -d ' ')" "2"
ck "re-run moves to front" "$(head -1 $H | cut -f2 | cut -c1-8)" "11111111"

print "fallback resolution (SC2, SC3, SC7 — the incident replay)"
# bind the pane to DEBRIS (whose transcript does NOT exist), keep MAXSID in history
print "/tmp\t$DEBRIS" > "$TMP/.superset-recovery/warp-bindings/$PANE"
rm -f "$TMP/.claude/projects/-private-tmp/$DEBRIS.jsonl"
r=$(env HOME=$TMP python3 "$LIB" resolve-warp $PANE 2>/dev/null | tail -1)
ck "incident replay: falls back to maxpool (SC7)" "$r" "claude	11111111-2222-3333-4444-555555555555"
grep -q "resuming ${MAXSID:0:8} from history" $TMP/.superset-recovery/resume.log && ck "fallback logged (SC2)" "yes" "yes" || ck "fallback logged (SC2)" "no" "yes"

print "no fallback available (SC3)"
rm -f "$TMP/.claude/projects/-private-tmp/$MAXSID.jsonl"
r=$(env HOME=$TMP python3 "$LIB" resolve-warp $PANE 2>/dev/null | tail -1)
ck "returns empty, no resume" "$r" ""

print "deliberate quit prunes history (SC4)"
mktranscript $MAXSID
print "/tmp\t$MAXSID" > "$TMP/.superset-recovery/warp-bindings/$PANE"
r=$(env HOME=$TMP python3 "$LIB" resolve-warp $PANE 2>/dev/null | tail -1)
# now the user quits MAXSID deliberately (empty sessions dir = no live twin)
fire SessionEnd "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$MAXSID\",\"reason\":\"prompt_input_exit\"}"
ck "history entry removed on quit" "$(grep -c $MAXSID $H)" "0"
# and a debris binding now finds nothing (quit sid is gone from history)
print "/tmp\t$DEBRIS" > "$TMP/.superset-recovery/warp-bindings/$PANE"
r=$(env HOME=$TMP python3 "$LIB" resolve-warp $PANE 2>/dev/null | tail -1)
ck "quit session not resurrected via fallback" "$r" ""

print "mutants — would these tests notice a broken implementation?"
SNAP="$TMP/hook.snap"; cp "$HOOK" "$SNAP"
python3 - "$HOOK" "$TMP/m1.py" <<'PY'
import sys; s=open(sys.argv[1]).read()
a='prev = prev[:10]'
assert a in s, "pattern missing"
open(sys.argv[2],"w").write(s.replace(a,'prev = prev[:1]',1))   # cap collapses history to nothing
PY
rm -rf "$TMP/.superset-recovery/warp-history"; fire2() { print -r -- "$2" | env HOME=$TMP TERM_PROGRAM=WarpTerminal WARP_TERMINAL_SESSION_UUID=$PANE python3 "$1"; }
fire2 "$TMP/m1.py" '{"hook_event_name":"SessionStart","session_id":"11111111-2222-3333-4444-555555555555","cwd":"/tmp"}'
fire2 "$TMP/m1.py" '{"hook_event_name":"SessionStart","session_id":"99999999-8888-7777-6666-555555555555","cwd":"/tmp"}'
ck "cap=1 mutant caught (eviction)" "$(wc -l < $H | tr -d ' ')" "1"   # healthy impl keeps 2

print ""; print "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
