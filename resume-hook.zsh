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
    local recov="$HOME/.superset-recovery" lib log plan agent sid bootid lockroot slot
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
    # opportunistically reap other-boot lock/slot dirs (bounded on-disk state)
    command find "$recov/locks" "$recov/slots" -mindepth 1 -maxdepth 1 -type d ! -name "$bootid" -exec rm -rf {} + 2>/dev/null
    lockroot="$recov/locks/$bootid"
    command mkdir -p "$lockroot" 2>/dev/null || return 0
    command mkdir "$lockroot/$SUPERSET_TERMINAL_ID" 2>/dev/null || return 0   # atomic one-shot
    export _SUPERSET_RESUME_DONE=1
    print -r -- "$(command date '+%F %T') FIRED term=$SUPERSET_TERMINAL_ID ws=$SUPERSET_WORKSPACE_ID agent=$agent sid=$sid" >> "$log" 2>/dev/null

    # 3) Stagger to avoid a thundering herd of heavy resumes (slot is atomically unique).
    slot="$(command python3 "$lib" slot 2>/dev/null)"
    if [[ -n "$slot" && "$slot" == <-> && "$slot" -gt 0 ]]; then
      local wait=$(( slot * 6 ))
      print -Pn "%F{cyan}▶ superset-recovery: resuming ${agent} %f"; print -rn -- "${sid[1,8]}…"; print -P "%F{cyan} in ${wait}s (staggered)%f"
      command sleep "$wait"
    else
      print -Pn "%F{cyan}▶ superset-recovery: resuming ${agent} %f"; print -r -- "${sid[1,8]}…"
    fi

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
    print -r -- "$(command date '+%F %T')   -> exec: $base[*]" >> "$log" 2>/dev/null
    "$base[@]"
    local rc=$?
    # If the launcher never started the agent (e.g. a wrapper needs a backend/creds
    # not ready this early after a cold restart), it exits non-zero and the pane is a
    # bare shell. Release the one-shot lock so simply re-opening that pane retries the
    # resume (env is up by then) instead of permanently burning it for this boot.
    if (( rc != 0 )); then
      command rmdir "$lockroot/$SUPERSET_TERMINAL_ID" 2>/dev/null
      print -r -- "$(command date '+%F %T')   -> launcher exit rc=$rc; released for retry" >> "$log" 2>/dev/null
    fi
    return 0
  }
  # NOTE: no block-level 2>/dev/null — the resumed agent must keep its stderr so a
  # failed resume is visible. Each internal helper suppresses its own stderr inline.
fi
