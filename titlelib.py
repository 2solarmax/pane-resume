#!/usr/bin/env python3
"""
titlelib — what to CALL a conversation.

A pane title and a restored tab title have to agree, and they have to agree with what
Claude Code itself calls the session — otherwise you are hunting for a conversation by a
name only one of the three tools knows. So the naming rule lives here once, and both
`pane-title.py` (live panes) and `restore-plan` (rebuilt tabs) read it from here.

The rule, in order:
  1. The session's own `ai-title` — this IS its name in Claude Code. Use it verbatim.
  2. No name yet: make the best readable thing out of the opening message.
  3. Nothing readable: say so, rather than inventing a name out of a paste.
"""
import re, json
from collections import namedtuple

# Openings that carry no information about what the conversation is FOR: markers we or the
# harness inject, and boilerplate the user never typed. Stripped from the front so whatever
# the conversation is actually about can surface behind them.
NOISE_PREFIX = re.compile(
    r"^(?:"
    r"\[Image #\d+\]"                          # a screenshot dropped in
    r"|Base directory for this skill:\s*\S+"   # a skill was invoked
    r"|Caveat:[^.]*\."
    r"|\[Request[^\]]*\]"
    r"|New-session handoff"
    r"|<[^>]{0,200}>"                          # a system/reminder tag
    r"|[\"'“”‘’⏺•\-–—>*\s]+"                   # quote/bullet/log-line punctuation
    r")+",
    re.IGNORECASE,
)

# A word — plain prose, the stuff a title is made of. Anything else leading the message
# (a pasted uuid, a dragged filename, a path, a bare id, stray log punctuation) is
# something typed *at* the assistant before the actual question, and gets skipped.
# "Letter" here means any script's letters, not A-Z: a conversation held in Russian is
# still a conversation, and matching only Latin would skip its every word as junk.
A_WORD = re.compile(r"^[^\W\d_][^\W\d_'’-]*[,.:;!?]?$")

# Some "user" messages were never typed by the user: a slash command's envelope, and the
# terminal's own output echoed back into the transcript. Both are wholly made of tags.
ENVELOPE_ONLY = re.compile(r"^\s*(?:<([a-z][a-z0-9-]*)>.*?</\1>\s*)+$", re.IGNORECASE | re.DOTALL)
# Inside a command envelope, what the user typed is the ARGUMENTS. The command name is the
# fallback when they passed none ("/effort") — and a poor one, see says_nothing().
COMMAND_PART = re.compile(r"<command-(args|name)>(.*?)</command-\1>", re.IGNORECASE | re.DOTALL)

# Titles are written to the terminal as an escape sequence, so a title carrying escapes of
# its own would be interpreted rather than displayed. Claude's own command output is full
# of them ("Set model to \x1b[1mFable 5\x1b[22m").
CONTROL = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|[\x00-\x1f\x7f]")


def clean(text):
    """Text safe to hand a terminal as a title: no escapes, no control bytes, one line."""
    return " ".join(CONTROL.sub(" ", text or "").split())


def command_args(text):
    """What the user actually typed inside a slash-command envelope, if anything."""
    parts = {k.lower(): v.strip() for k, v in COMMAND_PART.findall(text or "")}
    return parts.get("args", "")


def says_nothing(text):
    """True for a message the user did not actually say.

    Two kinds, both recorded as "user" messages: a bare slash command with no arguments
    ("/effort", "/model"), and the terminal's own reply to one, echoed back into the
    transcript ("Set model to Fable 5…"). Neither raises a subject — the subject is
    whatever the user says next. Naming sessions after these would file fifty different
    conversations under "Set model to Fable 5"."""
    raw = (text or "").strip()
    if not ENVELOPE_ONLY.match(raw):
        return False
    return not command_args(raw)


def title_from_first(text, limit=60):
    """Make the best title available from a conversation Claude has not named yet.

    Claude's own resume picker falls back to the opening message, so we do too — but that
    message usually opens with something that is not a name: a dragged-in screenshot, a
    pasted uuid, a skill preamble, a wall of log. Sixty characters of that tells you
    nothing about which of fifty tabs you are looking at.

    So: peel the machine-injected markers, take a leading markdown heading as the title if
    there is one (a skill body's heading IS its name), otherwise skip over leading tokens
    that are identifiers rather than words and title it by the first real sentence.
    Returns "" only when nothing readable is left."""
    raw = (text or "").strip()
    if ENVELOPE_ONLY.match(raw):
        raw = command_args(raw)                 # the only part of an envelope they typed
    prev = None
    while raw and raw != prev:                  # peel repeatedly: markers stack up
        prev = raw
        raw = NOISE_PREFIX.sub("", raw, count=1).strip()

    # A leading markdown heading names the thing that follows it — a skill body's heading
    # IS the skill's name. Except a slash command ("# /loop"), where the body is the point.
    m = re.match(r"^#{1,3}\s+(?!/)(.+)", raw)
    if m:
        head = re.sub(r"[*_`#]", "", m.group(1)).strip()
        if head:
            return head[:limit]

    t = re.sub(r"^#{1,3}\s*/\S*\s*", "", " ".join(raw.split()))
    # A dragged-in file arrives shell-escaped ("Screenshot\ 2026.png") — hold it together
    # as one token so it is skipped whole rather than shedding its name across three.
    words = t.replace("\\ ", "\x00").split(" ")
    skipped = 0
    while len(words) > 1 and skipped < 8 and not A_WORD.match(words[0]):
        words.pop(0)
        skipped += 1
    t = " ".join(words).replace("\x00", " ").strip()

    # Nothing but an identifier: name it by its last meaningful segment, not its protocol.
    if t and len(t.split(" ")) == 1 and not A_WORD.match(t):
        seg = [s for s in re.split(r"[/\\?#=]", t.split("://")[-1]) if s]
        named = next((s for s in reversed(seg)
                      if not re.fullmatch(r"[0-9a-f-]{8,}|\d+", s, re.IGNORECASE)), None)
        t = (named or (seg[-1] if seg else t)).replace("\\", "")

    if not t:
        return ""
    # Stop at the first sentence end, so a title is a title and not a paragraph.
    m = re.search(r"[.!?](?:\s|$)", t)
    if m and m.start() >= 20:
        t = t[:m.start()]
    return clean(t)[:limit].strip()


Transcript = namedtuple("Transcript", "named first cwd users")


def read_transcript(path):
    """One pass over a transcript for everything you need to decide what it is and whether
    it is worth reopening: the session's own name, its first real user message, the
    directory it was running in, and how many times the user actually said something.

    Reads to the end on purpose: Claude re-titles a session as it evolves, and the LAST
    `ai-title` is its current name. Stopping at the first one would pin a long conversation
    to whatever it was about in its opening minutes."""
    named = first = cwd = ""
    users = 0
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                if not cwd and '"cwd"' in line:
                    try: cwd = json.loads(line).get("cwd", "") or ""
                    except Exception: pass
                if '"ai-title"' in line:
                    try:
                        o = json.loads(line)
                        if o.get("type") == "ai-title":
                            named = o.get("aiTitle") or named   # last wins = most current
                    except Exception: pass
                    continue
                if '"user"' not in line:
                    continue
                try: o = json.loads(line)
                except Exception: continue
                if o.get("type") != "user" or o.get("isMeta"):
                    continue
                users += 1
                if first:
                    continue
                c = o.get("message", {}).get("content")
                t = ""
                if isinstance(c, list):
                    for p in c:
                        if isinstance(p, dict) and p.get("type") == "text":
                            t = p.get("text") or ""; break
                elif isinstance(c, str):
                    t = c
                if t.strip() and not says_nothing(t):
                    first = t
    except Exception:
        pass
    return Transcript(named, first, cwd, users)


def name_of(path, limit=60, fallback=""):
    """What to call the conversation in `path` — its real name if it has one."""
    return name_from(read_transcript(path), limit, fallback)


def name_from(tr, limit=60, fallback=""):
    """The naming rule itself, for a transcript you have already read.

    The `ai-title` IS what Claude Code calls this conversation, so it is used verbatim —
    that is the whole point: a tab and the app agree on the name. Only a session Claude has
    not named yet falls back to its opening message."""
    if tr.named:
        return clean(tr.named)[:limit]
    return title_from_first(tr.first, limit) or fallback
