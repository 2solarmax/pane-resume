# superset-recovery resume hook (hardened) — sourced from ~/.zshrc in every shell.
#
# After a Mac restart, Superset (cold-restore) and Warp (session restoration) both bring
# back the pane + working directory but drop it into a bare shell instead of resuming the
# agent conversation that was running. This hook runs in that fresh shell and, if armed AND
# there is a verified prior conversation for THIS exact pane, resumes it. Otherwise it is a
# silent no-op that can NEVER break the shell or fork-bomb.
#
# Two terminals, one machinery:
#   Superset  pane id = SUPERSET_TERMINAL_ID (36-char UUID); session looked up in host.db.
#   Warp      pane id = WARP_TERMINAL_SESSION_UUID (32 hex); session looked up in a binding
#             our Claude SessionStart/SessionEnd hooks maintain (claude only). See resume-lib.
#
# Guards (fast, side-effect-free) before any work:
#   G1 armed flag present         default ABSENT -> instant no-op (`superset-resume on`)
#   G2 interactive shell          claude's `zsh -c` subshells skip
#   G3 NOT inside claude          CLAUDECODE set by claude -> its subshells skip (no fork bomb)
#   G4 a valid pane id            (Superset 36-char UUID, or Warp 32-hex) blocks lock-dir traversal
#   G5 this shell hasn't resumed  exported flag; children inherit -> skip
# The one-shot lock + the exported flag are committed ONLY once a real, existence-verified
# session is found — so a transient lookup failure or a no-binding pane is never permanently
# burned and can retry. The agent runs as a CHILD (never exec), so if it exits/fails the
# pane falls back to a normal shell rather than dying.

# ── PANE LABEL (runs ALWAYS — even disarmed, even when nothing is resumed) ────────
# Warp labels every pane with its working directory, which is identical across dozens of
# panes and tells you nothing. After a crash you get N restored panes and no way to know
# what each one held. So each pane re-labels itself from its own saved record: the topic
# of the conversation it was running. This is the half that must work even when the
# session is NOT auto-restored — you can then reopen it deliberately (`sess`).
# (_SUPERSET_RESUME_DONE excludes the senders' `zsh -ic` probes: they are not a pane and
# would emit a title escape into the probe's captured stdout.)
if [[ -o interactive ]] && [[ -z "$CLAUDECODE" ]] \
   && [[ -z "$_SUPERSET_RESUME_DONE" ]] \
   && [[ "$TERM_PROGRAM" == "WarpTerminal" ]] \
   && [[ "$WARP_TERMINAL_SESSION_UUID" =~ '^[0-9a-fA-F]{32}$' ]]; then
  () {
    emulate -L zsh
    local lbl
    lbl="$(command python3 "$HOME/.superset-recovery/resume-lib.py" pane-label "$WARP_TERMINAL_SESSION_UUID" 2>/dev/null)"
    # NO early return on an empty label. A brand-new tab has no record YET — the record is
    # written when a session STARTS in it, which is after this shell. Bailing here meant the
    # title hook was never registered for exactly those panes, so when you later quit that
    # session Warp reset the pane to its folder and it stayed nameless for the life of the
    # shell. That is the nameless pane in the sidebar, and it regenerated on every new tab.
    # Register unconditionally; the hook below decides each prompt whether it has anything
    # to say, and picks the label up the moment the record appears.
    # Printing this once is not enough, and that is why you could see the label in Superset
    # but never in Warp. Warp's own shell bootstrap registers `warp_set_title_idle_on_precmd`,
    # which sets the title to the working directory at EVERY prompt
    # (zsh_body.sh:1148, ZSH_THEME_TERM_TITLE_IDLE="%~" — present in the shipped binary).
    # So our title was overwritten before the first prompt was ever drawn, on every pane.
    #
    # Warp's own comment says a user's title hook registered from .zshrc is meant to win, and
    # it does: the bootstrap registers before rcfiles, so ours is appended after and runs last.
    # Re-asserting costs one `print` per prompt — no subprocess, nothing recomputed.
    _PANE_RESUME_TITLE="${lbl[1,60]}"
    _PANE_RESUME_BINDING="$HOME/.superset-recovery/warp-last/$WARP_TERMINAL_SESSION_UUID"
    zmodload -F zsh/stat b:zstat 2>/dev/null
    _pane_resume_stamp() {
      local -a s
      zstat -A s +mtime "$_PANE_RESUME_BINDING" 2>/dev/null && print -r -- "$s[1]"
    }
    _PANE_RESUME_STAMP="$(_pane_resume_stamp)"

    # Warp ships the switch for this: both of its title hooks return early when
    # WARP_DISABLE_AUTO_TITLE is true. Using it is better than out-ordering them — it also
    # covers the preexec hook, which owns the title for the whole duration of a command, and
    # it does not depend on Warp's bootstrap registration order, which is internal and can
    # change in any release. The precmd below stays as the belt-and-braces guarantee.
    #
    # Set ONLY once we actually have a name. A pane we cannot name must keep Warp's own
    # folder title — silencing Warp for a pane we have nothing to say about would leave it
    # blank, which is worse than the folder.
    [[ -n "$_PANE_RESUME_TITLE" ]] && export WARP_DISABLE_AUTO_TITLE=true

    _pane_resume_set_title() {
      # A label captured at shell start and re-asserted forever goes confidently WRONG: reopen
      # a different conversation in this pane and the header would keep naming the old one,
      # which is worse than showing nothing for a tool whose whole job is telling you what a
      # pane holds. So re-read only when the pane's binding actually changed. `zstat` is a
      # builtin — this costs no fork per prompt.
      local now="$(_pane_resume_stamp)"
      if [[ -n "$now" && "$now" != "$_PANE_RESUME_STAMP" ]]; then
        _PANE_RESUME_STAMP="$now"
        _PANE_RESUME_TITLE="$(command python3 "$HOME/.superset-recovery/resume-lib.py" \
          pane-label "$WARP_TERMINAL_SESSION_UUID" 2>/dev/null)"
        _PANE_RESUME_TITLE="${_PANE_RESUME_TITLE[1,60]}"
        # The record just appeared (a session started in this pane) — from here on we own
        # the title, so stop Warp resetting it to the folder when that session ends.
        [[ -n "$_PANE_RESUME_TITLE" ]] && export WARP_DISABLE_AUTO_TITLE=true
      fi
      # Nothing to say yet: leave Warp's folder title alone rather than blanking the pane.
      [[ -n "$_PANE_RESUME_TITLE" ]] || return 0
      # `print -r --`, NOT `print -P`: a conversation is named by the user's own prose, and a
      # title containing "100%" or "%~" would otherwise be expanded as prompt escapes.
      print -rn -- $'\033]0;'"$_PANE_RESUME_TITLE"$'\007'
    }
    typeset -ga precmd_functions
    (( ${precmd_functions[(I)_pane_resume_set_title]} )) \
      || precmd_functions+=(_pane_resume_set_title)
    _pane_resume_set_title
  }
fi

# ── RESTORE INTO THE PANE YOU ARE ALREADY LOOKING AT ─────────────────────────────
# The other half of this file restores a conversation when a pane is FRESHLY OPENED. This
# half restores one into a pane that is ALREADY OPEN and sitting at a prompt — no reopening,
# no new tab, the conversation comes back exactly where it was.
#
# It works because an idle interactive zsh runs a signal trap the moment it is signalled
# from outside. Two facts only the shell itself knows are needed, and macOS will not reveal
# a shell's environment to `ps`, so the shell records them here:
#   which pane it is in ($WARP_TERMINAL_SESSION_UUID) and which process it is ($$).
#
# Safety, in order of how badly each one bites:
#   * the command is a CHILD, never `exec` — quit the agent and you are back at a normal
#     prompt in the same pane (an `exec` would close the pane on quit).
#   * the request is CONSUMED (deleted) before it runs, so it can fire at most once. This is
#     what stops the 2026-07-27 "cannot Ctrl-C out of it" loop from ever coming back.
#   * a request older than 2 minutes is ignored — a signal that arrived while the pane was
#     busy must not resurrect a conversation you quit ten minutes ago.
#   * the sender only ever signals a pane whose shell has NO child running, so a pane that
#     is mid-conversation is never disturbed.
#
# The _SUPERSET_RESUME_DONE guard is load-bearing, not defensive tidiness. This record must
# only ever be written by the pane's OWN long-lived shell. The senders (restore-in-place,
# restore-plan) probe a pane by running `zsh -ic` inside it, which sources this file; without
# the guard that transient subshell overwrote the record with its own pid and then exited,
# leaving the pane registered to a DEAD process — so running restore-in-place silently
# destroyed the restorability of the very pane you ran it from, and every later run skipped
# that pane as "no live shell registered". Reproduced 2026-07-27; both senders already
# set this variable in the probe's environment.
if [[ -o interactive ]] && [[ -z "$CLAUDECODE" ]] \
   && [[ -z "$_SUPERSET_RESUME_DONE" ]] \
   && [[ "$TERM_PROGRAM" == "WarpTerminal" ]] \
   && [[ "$WARP_TERMINAL_SESSION_UUID" =~ '^[0-9a-fA-F]{32}$' ]]; then
  # The registration file is also the PROOF that the trap below exists in this shell.
  # Without the trap, SIGUSR1 would KILL the shell (that is the default action), so the
  # sender must never signal a shell that has not written this. The marker is written in
  # the same block as the trap and names the trap's contract, so an older shell from
  # before this feature (no marker) or a future incompatible one is never signalled.
  command mkdir -p "$HOME/.superset-recovery/warp-shell" 2>/dev/null
  print -r -- "$$	trap1" > "$HOME/.superset-recovery/warp-shell/$WARP_TERMINAL_SESSION_UUID" 2>/dev/null
  TRAPUSR1() {
    emulate -L zsh
    local recov="$HOME/.superset-recovery" req cmd mtime now
    req="$recov/pending/$WARP_TERMINAL_SESSION_UUID"
    [[ -f "$req" ]] || return 0
    mtime="$(command stat -f %m "$req" 2>/dev/null)"   # read the age BEFORE consuming it
    cmd="$(command cat "$req" 2>/dev/null)"
    command rm -f "$req" 2>/dev/null            # consume first: can never fire twice
    [[ -n "$cmd" ]] || return 0
    now="$(command date +%s 2>/dev/null)"
    if [[ -n "$mtime" && -n "$now" ]] && (( now - mtime > 120 )); then
      return 0                                  # stale request — the pane was busy; drop it
    fi
    print -r -- "$(command date '+%F %T') IN-PLACE pane=$WARP_TERMINAL_SESSION_UUID -> $cmd" \
      >> "$recov/resume.log" 2>/dev/null
    zle -I 2>/dev/null                          # let the line editor repaint around us
    eval "$cmd"
  }
fi

if [[ -o interactive ]] \
   && [[ -z "$CLAUDECODE" ]] \
   && [[ -z "$_SUPERSET_RESUME_DONE" ]] \
   && [[ -f "$HOME/.superset-recovery/armed" ]] \
   && { { [[ -n "$SUPERSET_TERMINAL_ID" ]] && [[ "$SUPERSET_TERMINAL_ID" =~ '^[0-9a-fA-F-]{36}$' ]] } \
        || { [[ "$TERM_PROGRAM" == "WarpTerminal" ]] && [[ "$WARP_TERMINAL_SESSION_UUID" =~ '^[0-9a-fA-F]{32}$' ]] } }; then
  () {
    emulate -L zsh
    local recov="$HOME/.superset-recovery" lib log plan agent sid bootid lockroot lockdir
    local termid wsid is_warp=0
    local -a parts base
    lib="$recov/resume-lib.py"; log="$recov/resume.log"
    [[ -f "$lib" ]] || return 0

    # 1) Detect the terminal + resolve FIRST. Each resolver is existence-checked (the
    #    transcript must still exist) and returns empty on any transient/absent case, so a
    #    no-binding pane or a hiccup is a safe no-op the next shell can retry. Both return
    #    TAB-delimited: agent \t sid \t [launcher command + args...].
    if [[ -n "$SUPERSET_TERMINAL_ID" && "$SUPERSET_TERMINAL_ID" =~ '^[0-9a-fA-F-]{36}$' ]]; then
      termid="$SUPERSET_TERMINAL_ID"; wsid="$SUPERSET_WORKSPACE_ID"
      plan="$(command python3 "$lib" resolve "$termid" "$wsid" 2>/dev/null)" || return 0
    elif [[ "$TERM_PROGRAM" == "WarpTerminal" && "$WARP_TERMINAL_SESSION_UUID" =~ '^[0-9a-fA-F]{32}$' ]]; then
      is_warp=1; termid="$WARP_TERMINAL_SESSION_UUID"
      plan="$(command python3 "$lib" resolve-warp "$termid" 2>/dev/null)" || return 0
    else
      return 0
    fi
    if [[ -z "$plan" ]]; then
      # resolve returned nothing: no binding, transcript gone, or a fresh pane. resolve_warp
      # logs its own reason for the cases it can name; this catches the rest so no pane can
      # exit this block without an account of why.
      print -r -- "$(command date '+%F %T') SKIP term=$termid reason=no-resolvable-conversation" >> "$log" 2>/dev/null
      return 0
    fi
    IFS=$'\t' read -rA parts <<<"$plan"
    agent="$parts[1]"; sid="$parts[2]"
    if [[ -z "$agent" || -z "$sid" ]] || [[ ! "$sid" =~ '^[0-9a-fA-F-]{36}$' ]]; then
      print -r -- "$(command date '+%F %T') SKIP term=$termid reason=malformed-plan" >> "$log" 2>/dev/null
      return 0
    fi

    # DE-DUP #1 (Superset migration): once Superset ships native cold-restore auto-resume
    # (superset-sh/superset#5246), stand down and disarm so we never double-resume. Warp
    # has no native equivalent, so this only applies to the Superset path.
    if (( ! is_warp )) && [[ "$(command python3 "$lib" native 2>/dev/null)" == 1 ]]; then
      command rm -f "$recov/armed" 2>/dev/null
      print -r -- "$(command date '+%F %T') NATIVE resume detected — standing down + disarmed" >> "$log" 2>/dev/null
      return 0
    fi
    # DE-DUP #2 (backstop): if an agent is already running in this pane (manual/native beat
    # us to it), skip — never start a second. Matches both pane-id env vars.
    # Ask about THIS SHELL, not about the pane uuid. Warp reuses pane uuids across a restart,
    # so "is an agent bound to this pane?" is answered TRUE by the pane's own dying agent from
    # the previous run — which on 2026-08-23 silently skipped 22 of 56 panes while the old
    # agents took 19 seconds to exit. A new shell's process tree cannot contain the old
    # generation, so this question is immune to it by construction, and ~17x cheaper.
    if [[ "$(command python3 "$lib" agent-descendant $$ 2>/dev/null)" == 1 ]]; then
      print -r -- "$(command date '+%F %T') SKIP term=$termid sid=$sid reason=agent-already-under-this-shell" >> "$log" 2>/dev/null
      # Tally it. If Warp ever ships native session resume, this is what it will look like
      # from in here: pane after pane coming back already occupied. `warp-native-check`
      # reports the count so the tool can be retired deliberately rather than by surprise.
      local n="$(command python3 "$lib" note-preoccupied "$(command python3 "$lib" warp-epoch 2>/dev/null)" 2>/dev/null)"
      if [[ "$n" -ge 5 ]] && [[ ! -f "$recov/native-suspect-announced-$(command python3 "$lib" warp-epoch 2>/dev/null)" ]]; then
        command touch "$recov/native-suspect-announced-$(command python3 "$lib" warp-epoch 2>/dev/null)" 2>/dev/null
        print -r -- $'\033[33m'"pane-resume: ${n} panes came back already occupied this restart -- if you did not start those by hand, Warp may have shipped native session resume. Check: pane-resume status"$'\033[0m' >&2
      fi
      return 0
    fi

    # 2) Only now commit the one-shot guards (this pane WILL resume).
    #    SCOPE OF THE ONE-SHOT — this is the load-bearing bit:
    #    Warp  -> the current WARP RUN (pid+start). A crash/relaunch is a new epoch, so every
    #             pane restores once; inside one run a pane resumes at most once, so when you
    #             quit a session it STAYS quit (the 2026-07-27 "can't Ctrl-C out" loop).
    #    Superset -> the boot (unchanged).
    if (( is_warp )); then
      bootid="$(command python3 "$lib" warp-epoch 2>/dev/null)"
      [[ -n "$bootid" ]] || bootid="$(command python3 "$lib" bootid 2>/dev/null)"
    else
      bootid="$(command python3 "$lib" bootid 2>/dev/null)"
    fi
    if [[ -z "$bootid" ]]; then
      print -r -- "$(command date '+%F %T') SKIP term=$termid sid=$sid reason=no-epoch-id" >> "$log" 2>/dev/null
      return 0
    fi
    # opportunistically reap other-boot lock dirs (bounded on-disk state); slots/ is
    # legacy stagger state (removed 2026-07-14) — clear it entirely if still present
    command find "$recov/locks" -mindepth 1 -maxdepth 1 -type d ! -name "$bootid" -exec rm -rf {} + 2>/dev/null
    command rm -rf "$recov/slots" 2>/dev/null
    lockroot="$recov/locks/$bootid"
    command mkdir -p "$lockroot" 2>/dev/null || return 0
    lockdir="$lockroot/$termid"
    # Reclaim a STALE one-shot lock before claiming. A prior shell for THIS pane that
    # committed the lock then was killed before it ever launched never released it -> without
    # this, reopening the pane is silently burned for the rest of the boot (the exact
    # "sessions don't get restarted" symptom). Reclaim ONLY when the owner PID is POSITIVELY
    # dead (present in the pid file AND not alive) AND it never reached launch (no `exec`
    # marker) AND no agent is running in the pane. An ABSENT/empty pid is deliberately NOT
    # reclaimable: either a legacy lock from before this fix (that pane already resumed) or a
    # lock claimed microseconds ago whose owner hasn't written its pid yet. Fails safe.
    if [[ -d "$lockdir" && ! -e "$lockdir/exec" ]]; then
      local lpid="$(command cat "$lockdir/pid" 2>/dev/null)"
      if [[ -n "$lpid" ]] && ! command kill -0 "$lpid" 2>/dev/null \
         && [[ "$(command python3 "$lib" agent-descendant $$ 2>/dev/null)" != 1 ]]; then
        command rm -rf "$lockdir" 2>/dev/null
        print -r -- "$(command date '+%F %T') reclaimed stale lock (owner $lpid dead, no agent) term=$termid" >> "$log" 2>/dev/null
      fi
    fi
    if ! command mkdir "$lockdir" 2>/dev/null; then   # atomic one-shot
      # Already resumed once in this terminal run. Expected on a re-sourced .zshrc; logged so
      # a pane that "did nothing" is never unexplained.
      print -r -- "$(command date '+%F %T') SKIP term=$termid sid=$sid reason=already-resumed-this-run" >> "$log" 2>/dev/null
      return 0
    fi
    print -r -- "$$" > "$lockdir/pid" 2>/dev/null      # owner PID -> stale-lock reclaim above

    # ── ONE PANE PER CONVERSATION ────────────────────────────────────────────────────
    # The pane lock above stops this PANE resuming twice. It cannot stop two DIFFERENT panes
    # resuming the SAME conversation — and they do: a conversation lives in several panes over
    # its life, every one keeps a durable record, and after a crash they all fire at once.
    # 2026-07-27: two panes resumed one conversation in the same second; its transcript took
    # 571 forked parent chains before anyone noticed. Two writers, one file.
    #
    # Order matters: pane lock FIRST, then the conversation claim. Reversed, a pane that loses
    # the pane-lock race would leak a conversation claim and block the pane that should win.
    if [[ -n "$sid" ]]; then
      if [[ "$(command python3 "$lib" conversation-live "$sid" 2>/dev/null)" == 1 ]]; then
        print -r -- "$(command date '+%F %T') STAND-DOWN term=$termid sid=$sid reason=already-running-elsewhere" >> "$log" 2>/dev/null
        export _SUPERSET_RESUME_DONE=1
        return 0
      fi
      # `== 0`, not `!= 1`. The library prints 0 ONLY when another pane already holds this
      # conversation; every other outcome — including no output at all because python3 died
      # or was starved during a 40-pane restore — must PROCEED. Testing for "not 1" turns
      # every such failure into a refused restore, with the pane's one-shot lock already
      # burned, which is the opposite of what this file promises everywhere else.
      if [[ "$(command python3 "$lib" claim "$sid" "$bootid" 2>/dev/null)" == 0 ]]; then
        print -r -- "$(command date '+%F %T') STAND-DOWN term=$termid sid=$sid reason=another-pane-claimed-it" >> "$log" 2>/dev/null
        export _SUPERSET_RESUME_DONE=1
        return 0
      fi
    fi

    export _SUPERSET_RESUME_DONE=1
    print -r -- "$(command date '+%F %T') FIRED term=$termid $( (( is_warp )) && print -n warp || print -n "ws=$wsid" ) agent=$agent sid=$sid" >> "$log" 2>/dev/null

    # 3) Resume IMMEDIATELY — no stagger. The deliberate delay proved worse than the
    #    thundering herd it guarded against (2026-07-14: panes frozen for minutes waiting on
    #    their slot); a full-workspace batch of concurrent resumes is fine on modern hardware,
    #    and dozens of live agents run side-by-side anyway.
    #
    #    There is deliberately NO "resuming …" banner here. It printed before the launch was
    #    even assembled, so a launch that never happened — Ctrl-C during the throttle wait, a
    #    missing launcher, an agent that exits at once — left the pane asserting it had
    #    resumed. Redundant when it was right (the command itself is typed onto the prompt a
    #    few lines below, and the shell's own error is a truer report), and false in exactly
    #    the case where it was the only thing on screen. It also named the conversation by
    #    eight hex characters, which is the useless-id form this tool exists to replace.
    #    What a pane holds is answered by its TITLE, which is a fact and survives.

    # 4) Rebuild the launcher. Superset supplies the user's preset command+args (parts[3..],
    #    e.g. a `cc all …` wrapper). Warp doesn't record the launcher, so prefer the user's
    #    `cc` wrapper if they define one (it sets up their env), else the bare agent. Append
    #    the agent-appropriate resume form; run as a CHILD so the pane always survives.
    base=( "${(@)parts[3,-1]}" )
    (( ${#base} )) || base=( "$agent" )
    # Prefer the user's own `cc` wrapper (it sets up their env/routing). It must be a
    # FUNCTION or ALIAS they defined — every Mac with Xcode has a `cc` on PATH that is the C
    # compiler, so a bare "does cc exist" test passes on machines with no wrapper at all and
    # would hand the pane to clang instead of the agent.
    local _ccw
    if (( is_warp )) && [[ "$agent" == claude ]] && (( ${#base} == 1 )); then
      _ccw="$(whence -w cc 2>/dev/null)"
      if [[ "$_ccw" == *": function" || "$_ccw" == *": alias" ]]; then
        base=( cc all )
      fi
    fi
    case "$agent" in
      claude|gemini) base+=( --resume "$sid" ) ;;
      codex)         base+=( resume "$sid" ) ;;
      *) return 0 ;;
    esac
    if ! whence -- "$base[1]" >/dev/null 2>&1; then            # launcher missing -> bare agent
      base=( "$agent" )
      case "$agent" in claude|gemini) base+=( --resume "$sid" ) ;; codex) base+=( resume "$sid" ) ;; esac
    fi
    if ! whence -- "$base[1]" >/dev/null 2>&1; then            # still nothing runnable
      print -r -- "$(command date '+%F %T')   -> $agent not found; left as shell" >> "$log" 2>/dev/null
      return 0
    fi
    # ── CAN `--resume` ACTUALLY FIND IT FROM HERE? ───────────────────────────────────
    # `claude --resume <id>` looks the conversation up under the project folder for the
    # CURRENT directory, not globally. Every check before this one only proved a transcript
    # existed SOMEWHERE — so a pane restored into a different folder than its conversation
    # belongs to passed everything and then died with "No conversation found with session
    # ID", leaving a pane that looks restored and holds nothing (2 of 57 on 2026-08-03).
    local -a _plan_parts
    local _plan="$(command python3 "$lib" launch-plan "$sid" "$PWD" 2>/dev/null)"
    _plan_parts=( ${(s.	.)_plan} )
    case "$_plan_parts[1]" in
      NO)
        # Say so IN the pane. This is a fact about what was here, not a promise about a
        # launch — the pane's title already names the conversation, and a pane that explains
        # itself beats one showing a raw session id it cannot act on.
        print -r -- ""
        print -Pn "%F{yellow}▸ not resumed:%f "
        print -r -- "${_plan_parts[2]:-reason unavailable}"
        print -r -- "$(command date '+%F %T')   -> NOT RESUMED sid=$sid reason=${_plan_parts[2]}" >> "$log" 2>/dev/null
        return 0
        ;;
      CD)
        # Only reached when that directory is verified to resolve this conversation. A
        # SUBSHELL, so a failed cd cannot swallow the launch (`cd x && cmd` losing a session
        # is a mistake this repo has already made) and the pane keeps its own directory.
        if [[ -n "$_plan_parts[2]" && -d "$_plan_parts[2]" ]]; then
          base=( "(" cd -- "${(q)_plan_parts[2]}" "&&" "${(@)base}" ")" )
          print -r -- "$(command date '+%F %T')   -> launching from ${_plan_parts[2]}" >> "$log" 2>/dev/null
        fi
        ;;
    esac
    command : > "$lockdir/exec" 2>/dev/null   # mark: reached launch -> one-shot honored, NOT reclaimable
    # Drain tty type-ahead before handing the pane to the agent. A terminal may re-send the
    # pane's preset command text on restore; while zshrc runs it sits unread in the tty buffer
    # and would otherwise be delivered INTO the resumed agent as junk prompt input (or execute
    # as a surprise duplicate launch after the agent exits). Non-blocking, silent, bounded.
    local -i _drained=0
    while (( _drained < 4096 )) && read -s -t -k 1 2>/dev/null; do (( _drained++ )); done
    (( _drained )) && print -r -- "$(command date '+%F %T')   -> drained ${_drained} type-ahead char(s)" >> "$log" 2>/dev/null
    print -r -- "$(command date '+%F %T')   -> queued: $base[*]" >> "$log" 2>/dev/null

    # Hand the pane to the agent only AFTER the shell has finished starting up.
    #
    # Running it here instead is the obvious thing to do and it is wrong: .zshrc would then
    # never return for as long as the session lives, so zsh never reaches its first prompt
    # and the terminal keeps reporting the shell as still starting — Warp shows a permanent
    # "Starting zsh …" on every restored pane, plus "your shell is taking a while to start",
    # and treats the pane as not-yet-ready. Measured on a pty: launching inline, the prompt
    # appears only once the child EXITS; deferred to the first prompt, it appears in 0.02s.
    #
    # So we let startup finish, then type the command at the first prompt exactly as you
    # would have. The pane becomes a normal prompt running a normal command.
    # Wait for a start slot first, so restoring 30 panes brings a few agents up at a time
    # instead of all of them at once. This belongs on the command LINE, not inside the widget
    # below: a widget that blocks freezes the line editor, which is the same class of bug as
    # the inline launch described above. As a normal foreground command it is interruptible —
    # Ctrl-C returns 130 and `&&` then simply skips the launch, leaving a plain shell.
    #
    # Absolute path, and only when it is really there: resolving this through PATH would mean
    # a PATH hiccup returns "command not found", `&&` swallows the launch, and NOTHING resumes.
    # A throttle must never be able to fail closed.
    local _wait=""
    [[ -x "$recov/superset-resume" ]] && _wait="${(q)recov}/superset-resume wait-slot && "
    typeset -g _SUPERSET_RESUME_CMD="${_wait}${(j: :)${(q)base[@]}}"
    # A copy the widget compares against, so a corrupted line is caught with its bytes.
    typeset -g _SUPERSET_RESUME_EXPECT="$_SUPERSET_RESUME_CMD"
    _superset_resume_kick() {
      emulate -L zsh
      # one-shot: never fire again in this shell, even if the launch fails
      if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget -d line-init _superset_resume_kick 2>/dev/null
      else
        zle -D zle-line-init 2>/dev/null
      fi
      [[ -n "$_SUPERSET_RESUME_CMD" ]] || return 0
      BUFFER="$_SUPERSET_RESUME_CMD"
      unset _SUPERSET_RESUME_CMD
      # Record what is ACTUALLY about to be submitted, not what we intended. Panes have been
      # seen carrying escape fragments (`^[i`) on the resume line, which makes the whole line
      # a bogus command and leaves the pane dead for the run — but every measurement so far
      # says the line is clean at THIS point (196 of 196 accepted commands in history, 62 of
      # 62 on the last restore storm, 20 of 20 under deliberate injection). So the garbage
      # arrives somewhere after here, most likely while `wait-slot` holds the tty in echo
      # mode for minutes. Rather than guess again, capture the bytes: if BUFFER ever differs
      # from the command we built, the next occurrence arrives with evidence instead of a
      # recollection. Costs one comparison and writes nothing in the normal case.
      if [[ "$BUFFER" != "$_SUPERSET_RESUME_EXPECT" ]]; then
        print -r -- "$(command date '+%F %T')   -> BUFFER DIFFERS at submit: ${(qqq)BUFFER}" \
          >> "$HOME/.superset-recovery/resume.log" 2>/dev/null
      fi
      unset _SUPERSET_RESUME_EXPECT
      zle accept-line
    }
    # Prefer the composing hook so a plugin's own line-init widget still runs; fall back to
    # defining the widget directly on shells without it.
    autoload -Uz add-zle-hook-widget 2>/dev/null
    if (( $+functions[add-zle-hook-widget] )) \
       && add-zle-hook-widget line-init _superset_resume_kick 2>/dev/null; then
      :
    else
      zle -N zle-line-init _superset_resume_kick
    fi
    # The lock is deliberately NOT released if the launch fails. Releasing it created a tight
    # relaunch loop (2026-07-27): launcher fails -> lock released -> the pane's next shell
    # resumes -> fails -> ... and it re-launched a session the user had just quit. The
    # one-shot holds for the whole Warp run; a failed launch leaves a normal shell.
    return 0
  }
  # NOTE: no block-level 2>/dev/null — the resumed agent must keep its stderr so a failed
  # resume is visible. Each internal helper suppresses its own stderr inline.
fi
