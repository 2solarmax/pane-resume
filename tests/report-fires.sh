#!/bin/zsh
# report-fires.sh — the post-restore report must actually WRITE (2026-10-31 defect).
#
# Shipped 790137d had `command : > "$_lf" 2>/dev/null || return 0` inside
# _pane_resume_report_if_last. In zsh, `:` is a builtin and `command :` fails with
# 127 ("command not found: :"), so the guard aborted the function AFTER the stamp
# file had been created by the redirection side-effect — leaving every natural
# restore pass silently report-less while looking fired. The production fire at
# 2026-10-31 18:10:15 (stamp created, zero REPORT lines in resume.log) is the
# real-world RED for this test.
#
# This test fails on BOTH halves of the defect class:
#   1. any `command <shell-builtin>` in resume-hook.zsh (static grep — catches the
#      next builtin someone wraps in `command` for "safety")
#   2. the extracted function, run under a sandbox HOME with a stub report, must
#      write last-report.txt AND a REPORT line (a fix that only creates the stamp
#      is exactly the bug).

set -u
here="${0:A:h}"
hook="$here/../resume-hook.zsh"
fails=0; tests=0
ok()   { tests=$((tests+1)); echo "  ok   $1" }
bad()  { tests=$((tests+1)); fails=$((fails+1)); echo "  FAIL $1" }

# -- 1) no builtin may hide behind `command` ------------------------------------
if command grep -qn 'command [a-z]*:' "$hook" 2>/dev/null || command grep -qnE 'command (print|typeset|local|setopt|emulate|return|builtin|:)\b' "$hook"; then
  bad "resume-hook.zsh still wraps a shell builtin in 'command' (zsh: 127, not a safety wrap)"
else
  ok "no 'command <builtin>' in resume-hook.zsh"
fi

# -- 2) the function must write the report, not just the stamp ------------------
box="$(mktemp -d "${TMPDIR:-/tmp}/report-fires.XXXXXX")"
mkdir -p "$box/home/.superset-recovery/locks/warp-test"
: > "$box/stub-lib.py"
print -r -- '#!/usr/bin/env python3' > "$box/home/.superset-recovery/resume-lib.py"
print -r -- 'print("# 3 conversation(s) active in the last 48h are NOT running now")' >> "$box/home/.superset-recovery/resume-lib.py"

# Extract the function verbatim from the hook (4-space indented block). If the
# function moves or is renamed, extraction fails loudly -> this test fails.
sed -n '/^    _pane_resume_report_if_last() {/,/^    }$/p' "$hook" | sed 's/^    //' > "$box/fn.zsh"
if command grep -q '_pane_resume_report_if_last' "$box/fn.zsh"; then
  ok "extracted _pane_resume_report_if_last from resume-hook.zsh"
else
  bad "could not extract _pane_resume_report_if_last from resume-hook.zsh"
fi
{ print -r -- 'recov=$HOME/.superset-recovery; lib=$recov/resume-lib.py; log=$recov/resume.log; bootid=warp-test'
  cat "$box/fn.zsh"
  print -r -- '_pane_resume_report_if_last'
} > "$box/run.zsh"

env HOME="$box/home" zsh "$box/run.zsh" >/dev/null 2>&1

[[ -e "$box/home/.superset-recovery/locks/warp-test/.report-stamp" ]] \
  && ok "stamp created" || bad "stamp not created"
[[ -s "$box/home/.superset-recovery/last-report.txt" ]] \
  && ok "last-report.txt written (the 790137d defect: stamp yes, report MISSING)" \
  || bad "last-report.txt MISSING — stamp-without-report is the exact 2026-10-31 defect"
command grep -q "^# 3 conversation" "$box/home/.superset-recovery/last-report.txt" 2>/dev/null \
  && ok "report content matches the resolver output" || bad "report content wrong/empty"
command grep -q " REPORT " "$box/home/.superset-recovery/resume.log" 2>/dev/null \
  && ok "REPORT line appended to resume.log" || bad "no REPORT line in resume.log"

command rm -rf "$box"
echo "result: $((tests - fails)) passed, $fails failed"
exit $(( fails > 0 ))
