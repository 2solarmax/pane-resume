# superset-recovery resume hook (hardened) — sourced from ~/.zshrc in every shell.
#
# When Superset cold-restores a pane after a Mac restart, the pane's fresh bare shell
# runs this. If armed AND there's a verified prior conversation for this exact pane, it
# resumes it. Otherwise it's a silent no-op that can NEVER break the shell or fork-bomb.
#
# Guards (fast, side-effect-free) before any work:
#   G1 armed flag present        default ABSENT -> instant no-op (`superset-resume on`)
#   G2 interactive shell          claude's `zsh -c` subshells skip
#   G3 NOT inside claude          CLAUDECODE set by claude -> its subshells skip (no fork bomb)
#   G4 SUPERSET_TERMINAL_ID is a valid UUID (blocks path-traversal via the lock dir)
#   G5 this shell hasn't resumed  exported flag; children inherit -> skip
# The one-shot lock + the exported flag are committed ONLY once a real, existence-verified
# session is found — so a transient host.db-busy or a no-binding pane is never permanently
# burned and can retry. The agent runs as a CHILD (never exec), so if it exits/fails the
# pane falls back to a normal shell rather than dying.

if [[ -o interactive ]] \
   && [[ -z "$CLAUDECODE" ]] \
   && [[ -z "$_SUPERSET_RESUME_DONE" ]] \
   && [[ -n "$SUPERSET_TERMINAL_ID" ]] \
   && [[ "$SUPERSET_TERMINAL_ID" =~ '^[0-9a-fA-F-]{36}$' ]] \
   && [[ -f "$HOME/.superset-recovery/armed" ]]; then
  () {
    emulate -L zsh
    local recov="$HOME/.superset-recovery" lib log plan agent sid bootid lockroot lockdir
    local -a parts base
    lib="$recov/resume-lib.py"; log="$recov/resume.log"
    [[ -f "$lib" ]] || return 0

    # 1) Resolve FIRST. resolve() is workspace-verified + confirms the worktree and the
    #    transcript still exist; a transient error returns empty (safe, retryable).
    #    Returns TAB-delimited: agent \t sid \t [launcher command + args...].
    plan="$(command python3 "$lib" resolve "$SUPERSET_TERMINAL_ID" "$SUPERSET_WORKSPACE_ID" 2>/dev/null)" || return 0
    [[ -n "$plan" ]] || return 0
    IFS=$'\t' read -rA parts <<<"$plan"
    agent="$parts[1]"; sid="$parts[2]"
    [[ -n "$agent" && -n "$sid" && "$sid" =~ '^[0-9a-fA-F-]{36}$' ]] || return 0

    # DE-DUP #1 (migration): once Superset ships native cold-restore auto-resume
    # (superset-sh/superset#5246), stand down and disarm so we never double-resume.
    if [[ "$(command python3 "$lib" native 2>/dev/null)" == 1 ]]; then
      command rm -f "$recov/armed" 2>/dev/null
      print -r -- "$(command date '+%F %T') NATIVE resume detected — standing down + disarmed" >> "$log" 2>/dev/null
      return 0
    fi
    # DE-DUP #2 (transition backstop): if an agent is already running in this pane
    # (native/manual beat us to it), skip — never start a second.
    if [[ "$(command python3 "$lib" agent-running "$SUPERSET_TERMINAL_ID" 2>/dev/null)" == 1 ]]; then
      print -r -- "$(command date '+%F %T') agent already running in pane — skipped (dedup)" >> "$log" 2>/dev/null
      return 0
    fi

    # 2) Only now commit the one-shot guards (this pane WILL resume).
    bootid="$(command python3 "$lib" bootid 2>/dev/null)"
    [[ -n "$bootid" ]] || return 0
    # opportunistically reap other-boot lock dirs (bounded on-disk state); slots/ is
    # legacy stagger state (removed 2026-07-14) — clear it entirely if still present
    command find "$recov/locks" -mindepth 1 -maxdepth 1 -type d ! -name "$bootid" -exec rm -rf {} + 2>/dev/null
    command rm -rf "$recov/slots" 2>/dev/null
    lockroot="$recov/locks/$bootid"
    command mkdir -p "$lockroot" 2>/dev/null || return 0
    lockdir="$lockroot/$SUPERSET_TERMINAL_ID"
    # Reclaim a STALE one-shot lock before claiming. A prior shell for THIS pane that
    # committed the lock then was killed before it ever launched never
    # released it -> without this, reopening the pane is silently burned for the rest of
    # the boot (the exact "sessions don't get restarted" symptom). Reclaim ONLY when the
    # owner PID is POSITIVELY dead (present in the pid file AND not alive) AND it never
    # reached launch (no `exec` marker) AND no agent is running in the pane. An ABSENT/empty
    # pid is deliberately NOT reclaimable: it's either a legacy lock from before this fix
    # (that pane already resumed -> never re-resume it) or a lock claimed microseconds ago
    # whose owner hasn't written its pid yet (protect it). Fails safe: worst case an owner
    # killed in that microsecond window stays burned (rare), never a double-resume.
    if [[ -d "$lockdir" && ! -e "$lockdir/exec" ]]; then
      local lpid="$(command cat "$lockdir/pid" 2>/dev/null)"
      if [[ -n "$lpid" ]] && ! command kill -0 "$lpid" 2>/dev/null \
         && [[ "$(command python3 "$lib" agent-running "$SUPERSET_TERMINAL_ID" 2>/dev/null)" != 1 ]]; then
        command rm -rf "$lockdir" 2>/dev/null
        print -r -- "$(command date '+%F %T') reclaimed stale lock (owner $lpid dead, no agent) term=$SUPERSET_TERMINAL_ID" >> "$log" 2>/dev/null
      fi
    fi
    command mkdir "$lockdir" 2>/dev/null || return 0   # atomic one-shot
    print -r -- "$$" > "$lockdir/pid" 2>/dev/null      # owner PID -> stale-lock reclaim above
    export _SUPERSET_RESUME_DONE=1
    print -r -- "$(command date '+%F %T') FIRED term=$SUPERSET_TERMINAL_ID ws=$SUPERSET_WORKSPACE_ID agent=$agent sid=$sid" >> "$log" 2>/dev/null

    # 3) Announce and resume IMMEDIATELY — no stagger. The deliberate delay proved worse
    #    than the thundering herd it guarded against (2026-07-14: panes frozen for
    #    minutes waiting on their slot); a full-workspace batch of concurrent resumes
    #    is fine on modern hardware, and dozens of live agents run side-by-side anyway.
    print -Pn "%F{cyan}▶ superset-recovery: resuming ${agent} %f"; print -r -- "${sid[1,8]}…"

    # 4) Rebuild the launcher (parts[3..] = the user's preset command+args, e.g.
    #    `cc all --dangerously-skip-permissions`) or fall back to the bare agent;
    #    append the agent-appropriate resume form; run as a CHILD so the pane always
    #    survives (even if the agent errors/exits, control returns to a shell).
    base=( "${(@)parts[3,-1]}" )
    (( ${#base} )) || base=( "$agent" )
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
    # Drain tty type-ahead before handing the pane to the agent. Superset re-sends the
    # pane's preset command text on restore; while zshrc runs it sits unread in the tty
    # buffer and would otherwise be delivered INTO the resumed agent as junk prompt input
    # (or execute as a surprise duplicate launch after the agent exits). Non-blocking
    # (-t with no num = only if input is already pending), silent, bounded.
    local -i _drained=0
    while (( _drained < 4096 )) && read -s -t -k 1 2>/dev/null; do (( _drained++ )); done
    (( _drained )) && print -r -- "$(command date '+%F %T')   -> drained ${_drained} type-ahead char(s)" >> "$log" 2>/dev/null
    print -r -- "$(command date '+%F %T')   -> exec: $base[*]" >> "$log" 2>/dev/null
    "$base[@]"
    local rc=$?
    # If the launcher never started the agent (e.g. a wrapper needs a backend/creds not
    # ready this early after a cold restart), it exits non-zero and the pane is a bare
    # shell. Release the whole one-shot lock so simply re-opening that pane retries the
    # resume (env is up by then) instead of permanently burning it for this boot.
    if (( rc != 0 )); then
      command rm -rf "$lockdir" 2>/dev/null
      print -r -- "$(command date '+%F %T')   -> launcher exit rc=$rc; released for retry" >> "$log" 2>/dev/null
    fi
    return 0
  }
  # NOTE: no block-level 2>/dev/null — the resumed agent must keep its stderr so a
  # failed resume is visible. Each internal helper suppresses its own stderr inline.
fi
