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
if [[ -o interactive ]] && [[ -z "$CLAUDECODE" ]] \
   && [[ "$TERM_PROGRAM" == "WarpTerminal" ]] \
   && [[ "$WARP_TERMINAL_SESSION_UUID" =~ '^[0-9a-fA-F]{32}$' ]]; then
  () {
    emulate -L zsh
    local lbl
    lbl="$(command python3 "$HOME/.superset-recovery/resume-lib.py" pane-label "$WARP_TERMINAL_SESSION_UUID" 2>/dev/null)"
    [[ -n "$lbl" ]] && print -n -- $'\033]0;'"${lbl[1,60]}"$'\007'
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
    [[ -n "$plan" ]] || return 0
    IFS=$'\t' read -rA parts <<<"$plan"
    agent="$parts[1]"; sid="$parts[2]"
    [[ -n "$agent" && -n "$sid" && "$sid" =~ '^[0-9a-fA-F-]{36}$' ]] || return 0

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
    if [[ "$(command python3 "$lib" agent-running "$termid" 2>/dev/null)" == 1 ]]; then
      print -r -- "$(command date '+%F %T') agent already running in pane — skipped (dedup)" >> "$log" 2>/dev/null
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
    [[ -n "$bootid" ]] || return 0
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
         && [[ "$(command python3 "$lib" agent-running "$termid" 2>/dev/null)" != 1 ]]; then
        command rm -rf "$lockdir" 2>/dev/null
        print -r -- "$(command date '+%F %T') reclaimed stale lock (owner $lpid dead, no agent) term=$termid" >> "$log" 2>/dev/null
      fi
    fi
    command mkdir "$lockdir" 2>/dev/null || return 0   # atomic one-shot
    print -r -- "$$" > "$lockdir/pid" 2>/dev/null      # owner PID -> stale-lock reclaim above
    export _SUPERSET_RESUME_DONE=1
    print -r -- "$(command date '+%F %T') FIRED term=$termid $( (( is_warp )) && print -n warp || print -n "ws=$wsid" ) agent=$agent sid=$sid" >> "$log" 2>/dev/null

    # 3) Announce and resume IMMEDIATELY — no stagger. The deliberate delay proved worse
    #    than the thundering herd it guarded against (2026-07-14: panes frozen for minutes
    #    waiting on their slot); a full-workspace batch of concurrent resumes is fine on
    #    modern hardware, and dozens of live agents run side-by-side anyway.
    print -Pn "%F{cyan}▶ superset-recovery: resuming ${agent} %f"; print -r -- "${sid[1,8]}…"

    # 4) Rebuild the launcher. Superset supplies the user's preset command+args (parts[3..],
    #    e.g. a `cc all …` wrapper). Warp doesn't record the launcher, so prefer the user's
    #    `cc` wrapper if they define one (it sets up their env), else the bare agent. Append
    #    the agent-appropriate resume form; run as a CHILD so the pane always survives.
    base=( "${(@)parts[3,-1]}" )
    (( ${#base} )) || base=( "$agent" )
    if (( is_warp )) && [[ "$agent" == claude ]] && (( ${#base} == 1 )) && whence -w cc >/dev/null 2>&1; then
      base=( cc all )   # user wrapper; if it fails at cold boot -> non-zero -> lock released -> reopen retries
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
    typeset -g _SUPERSET_RESUME_CMD="${(j: :)${(q)base[@]}}"
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
