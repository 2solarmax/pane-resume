#!/usr/bin/env bash
# Installer for pane-resume.
# Copies the tool to ~/.superset-recovery, wires a guarded block into ~/.zshrc,
# and leaves it DISARMED (opt-in). Idempotent — safe to re-run to update.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.superset-recovery"
ZSHRC="$HOME/.zshrc"
BEGIN="# >>> superset-recovery >>>"
END="# <<< superset-recovery <<<"

echo "Installing pane-resume → $DEST"
mkdir -p "$DEST"
cp "$SRC/resume-lib.py" "$SRC/resume-hook.zsh" "$SRC/superset-resume" \
   "$SRC/warp-session-hook.py" "$SRC/pane-title.py" "$SRC/titlelib.py" \
   "$SRC/restore-plan" "$SRC/restore-in-place" "$SRC/sess" "$DEST/"
# titlelib is imported by the others, not run, so it stays non-executable on purpose.
chmod +x "$DEST/superset-resume" "$DEST/resume-lib.py" "$DEST/warp-session-hook.py" \
         "$DEST/pane-title.py" "$DEST/restore-plan" "$DEST/restore-in-place" "$DEST/sess"

# Wire ~/.zshrc (idempotent: replace an existing managed block, else append).
BLOCK="$BEGIN
export PATH=\"\$PATH:\$HOME/.superset-recovery\"
[ -f \"\$HOME/.superset-recovery/resume-hook.zsh\" ] && source \"\$HOME/.superset-recovery/resume-hook.zsh\"
$END"

if [ -f "$ZSHRC" ] && grep -qF "$BEGIN" "$ZSHRC"; then
  # replace existing managed block
  tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" '
    $0==b {skip=1}
    skip==0 {print}
    $0==e {skip=0}
  ' "$ZSHRC" > "$tmp"
  printf '%s\n' "$BLOCK" >> "$tmp"
  mv "$tmp" "$ZSHRC"
  echo "Updated existing ~/.zshrc block."
else
  printf '\n%s\n' "$BLOCK" >> "$ZSHRC"
  echo "Added block to ~/.zshrc."
fi

echo
echo "For WARP: also register the session-binding hook in ~/.claude/settings.json"
echo "  (append a SessionStart + SessionEnd group running:"
echo "   python3 ~/.superset-recovery/warp-session-hook.py) — see README."
echo
echo "Done. It's installed but DISARMED (opt-in)."
echo "  superset-resume plan     # see what would resume"
echo "  superset-resume on       # arm it, so your NEXT restart auto-resumes panes"
echo
echo "Already restarted without it armed? Recover the panes you have open now:"
echo "  restore-in-place         # dry-run, then add --go"
echo "Open a new shell (or: source ~/.zshrc) to load the hook."
