#!/bin/zsh
# Does the tool notice if Warp starts resuming sessions itself?
#
# It cannot answer that by reading Warp's schema and guessing which column means "resume" --
# nobody knows what their implementation will look like. So it watches for the BEHAVIOUR:
# panes coming back already occupied by an agent this tool did not launch. Plus a weak
# schema hint, which is poor evidence on its own but dates the change.
#
# Both arms are tested in BOTH directions, because a detector only ever seen NOT firing is
# indistinguishable from one that cannot fire.
set -e
LIB="${1:-$HOME/.superset-recovery/resume-lib.py}"
pass=0; fail=0
# note: (( x++ )) returns non-zero when x is 0, which under set -e ends the run on the
# FIRST passing check. Hence the explicit arithmetic form.
ck() {
  if [[ "$2" == "$3"* ]]; then print "  ok   $1"; pass=$((pass + 1))
  else print "  FAIL $1: got '$2' want '$3'*"; fail=$((fail + 1)); fi
}

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
export HOME="$TMP"; mkdir -p "$TMP/.superset-recovery"

print "behaviour -- panes coming back already occupied"
ck "quiet epoch is quiet"             "$(python3 $LIB warp-native-check ep1)" "none preoccupied=0"
for i in {1..4}; do python3 $LIB note-preoccupied ep1 >/dev/null; done
ck "4 hand-started sessions: quiet"   "$(python3 $LIB warp-native-check ep1)" "none preoccupied=4"
python3 $LIB note-preoccupied ep1 >/dev/null
ck "5th occupied pane: suspected"     "$(python3 $LIB warp-native-check ep1)" "SUSPECTED preoccupied=5"
ck "next restart starts clean"        "$(python3 $LIB warp-native-check ep2)" "none preoccupied=0"

print "schema -- a new column named like session restore"
DB="$TMP/fake.sqlite"; export PANE_RESUME_WARP_DB="$DB"
mk() { rm -f "$DB"; sqlite3 "$DB" "CREATE TABLE terminal_panes (id TEXT, uuid TEXT, cwd TEXT$1);"; }
mk ""                        ; ck "baseline recorded, no verdict" "$(python3 $LIB warp-native-check s1)" "none"
mk ", agent_session_id TEXT" ; ck "resume-ish column: suspected"  "$(python3 $LIB warp-native-check s2)" "SUSPECTED"
mk ", background_color TEXT" ; ck "unrelated column: quiet"       "$(python3 $LIB warp-native-check s3)" "none"

print "mutants -- would the checks above catch a broken detector?"
# Each mutant is isolated to the ONE arm it targets. Seeding occupied panes while testing
# the schema arm lets the behavioural arm answer instead, and the mutant then reads as
# survived when it was never exercised at all.
HERE="${0:A:h}"
SNAP="$TMP/lib.py"; cp "$LIB" "$SNAP"

# behavioural arm: no schema in play; 6 occupied panes must trip any sane threshold
unset PANE_RESUME_WARP_DB
python3 "$HERE/mutate.py" "$SNAP" "$TMP/m1.py" 'sig["preoccupied"] >= 5' 'sig["preoccupied"] >= 9999'
rm -rf "$TMP/.superset-recovery/preoccupied"
for i in {1..6}; do python3 "$TMP/m1.py" note-preoccupied mut1 >/dev/null; done
ck "threshold raised -> caught"       "$(python3 $TMP/m1.py warp-native-check mut1)" "none"

# schema arm: zero occupied panes, so only the schema arm can produce a verdict
python3 "$HERE/mutate.py" "$SNAP" "$TMP/m2.py" 'agent_session|resume|cli_agent|restored_agent' 'zzz_never_matches'
rm -rf "$TMP/.superset-recovery/preoccupied" "$TMP/.superset-recovery/warp-schema-baseline"
export PANE_RESUME_WARP_DB="$DB"
mk ""                        ; python3 "$TMP/m2.py" warp-native-check mut2 >/dev/null
mk ", agent_session_id TEXT"
ck "hint regex broken -> caught"      "$(python3 $TMP/m2.py warp-native-check mut3)" "none"
unset PANE_RESUME_WARP_DB

print ""; print "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
