#!/usr/bin/env bash
# Global SessionStart bootstrap for the handoff skill.
#
# Installed ONCE, globally, in ~/.claude/settings.json's SessionStart hook (a
# command that only calls this script when the CURRENT project has a handoff/
# folder -- see the one-line guard documented near the bottom of this header).
# From then on, EVERY project that uses the handoff skill gets its two pieces
# of one-time per-repo plumbing installed automatically, the moment a Claude
# Code session starts there after both handoff/ and a git repo exist -- no
# manual copy-paste step, ever, in any repo:
#
#   1. .git/hooks/post-commit  -> fires handoff/scripts/trigger-handoff-update.sh
#   2. .claude/settings.json   -> PostToolUse hook -> handoff/scripts/log-progress.sh
#
# Both were previously "install once, by hand, per project" steps documented
# in README.md -- fine for the first project this skill was ever set up in,
# but it broke the "developer only ever does two things: write code, commit +
# push" workflow every time a NEW repo started from scratch. Concretely, this
# is the exact gap that left handoffTest's first commit without a handoff.md:
# `git init` only creates *.sample hook files, never a real post-commit, and
# a fresh repo has no .claude/settings.json until something adds one. This
# script is that "something" -- run automatically, so the gap never recurs.
#
# Idempotent and additive ONLY:
#   - never overwrites an existing post-commit hook that doesn't already call
#     trigger-handoff-update.sh -- it APPENDS the call instead, so any other
#     hook logic already there keeps running
#   - never touches .claude/settings.json if the PostToolUse -> log-progress.sh
#     hook is already present (checked by content, not just file existence) --
#     merges it in via jq otherwise, preserving whatever else is in that file
#   - never runs at all if this isn't a git repo yet (nothing to hook into --
#     picked up automatically on the NEXT session start once `git init` has
#     run), or if handoff/scripts/trigger-handoff-update.sh doesn't exist
#     (this isn't a handoff-skill project)
#   - always exits 0 -- never blocks session start, same contract as
#     log-progress.sh and trigger-handoff-update.sh
#
# Install ONCE, globally, in ~/.claude/settings.json:
#   {
#     "hooks": {
#       "SessionStart": [
#         { "hooks": [ { "type": "command",
#             "command": "[ -f handoff/scripts/bootstrap-handoff.sh ] && bash handoff/scripts/bootstrap-handoff.sh || true" } ] }
#       ]
#     }
#   }
# The `[ -f ... ] &&` guard is what makes this safe to install globally: on
# any project that doesn't have this skill, it's just a path check, and
# nothing else happens.

set -uo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo_root" ] || exit 0          # not a git repo yet -- nothing to hook into
cd "$repo_root" || exit 0

[ -f "$repo_root/handoff/scripts/trigger-handoff-update.sh" ] || exit 0   # not a handoff-skill project

did_something=0

# --- 1. git post-commit hook -------------------------------------------------
hook_file="$repo_root/.git/hooks/post-commit"
hook_line='exec "$(git rev-parse --show-toplevel)/handoff/scripts/trigger-handoff-update.sh"'

if [ ! -f "$hook_file" ]; then
  {
    echo '#!/usr/bin/env bash'
    echo "$hook_line"
  } > "$hook_file"
  chmod +x "$hook_file"
  did_something=1
elif ! grep -q 'trigger-handoff-update.sh' "$hook_file" 2>/dev/null; then
  # An existing, unrelated post-commit hook is already here -- append rather
  # than replace, so whatever it already does keeps working.
  printf '\n# --- handoff skill: auto-installed by bootstrap-handoff.sh ---\n%s\n' "$hook_line" >> "$hook_file"
  chmod +x "$hook_file"
  did_something=1
fi

# --- 2. .claude/settings.json PostToolUse hook -------------------------------
settings_file="$repo_root/.claude/settings.json"
mkdir -p "$repo_root/.claude" 2>/dev/null

if command -v jq >/dev/null 2>&1; then
  if [ -f "$settings_file" ]; then
    already_present="$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command // ""] | any(test("log-progress.sh"))' "$settings_file" 2>/dev/null)"
  else
    already_present="false"
    echo '{}' > "$settings_file"
  fi

  if [ "$already_present" != "true" ]; then
    tmp_file="$settings_file.tmp.$$"

    # The command is built from fully absolute, machine-resolved paths, NOT
    # a bare relative one -- two Windows-specific failures discovered for
    # real on 2026-09-13, in order:
    #   1. A bare "handoff/scripts/log-progress.sh" failed with "No such
    #      file or directory": Claude Code's own PostToolUse hook launcher
    #      does not interpret the #!/usr/bin/env bash shebang the way git's
    #      hook invocation does (that's why .git/hooks/post-commit, run BY
    #      git rather than by Claude Code, is fine as a bare executable
    #      path) -- so it needs an explicit interpreter.
    #   2. Even "bash handoff/scripts/log-progress.sh" (relative path,
    #      relying on PATH to find "bash") ALSO failed with the identical
    #      error, because Claude Code's PostToolUse hook launcher does not
    #      reliably run with cwd set to the project root the way a git hook
    #      does, and separately "bash" itself can resolve to an unrelated
    #      WSL bash.exe (if one is on PATH ahead of Git Bash's) with no
    #      relation to the Windows project path at all.
    # Fix: resolve the bash executable and this script's path to absolute,
    # Windows-native form via `cygpath -w` right now, at install time (when
    # this script is provably running under the correct bash -- it just did
    # git/jq/mkdir work against this exact repo) -- removing all dependency
    # on PATH or cwd at the moment the hook actually fires later. The repo
    # root is also passed as an explicit argument ($1), which
    # log-progress.sh prefers over deriving it from `git rev-parse` for the
    # same reason. On non-Windows this degrades to the same paths unchanged
    # (no cygpath there, nothing to translate).
    bash_bin="$(command -v bash 2>/dev/null || echo bash)"
    if command -v cygpath >/dev/null 2>&1; then
      bash_bin_native="$(cygpath -w "$bash_bin" 2>/dev/null || echo "$bash_bin")"
      script_native="$(cygpath -w "$repo_root/handoff/scripts/log-progress.sh" 2>/dev/null || echo "$repo_root/handoff/scripts/log-progress.sh")"
      repo_root_native="$(cygpath -w "$repo_root" 2>/dev/null || echo "$repo_root")"
    else
      bash_bin_native="$bash_bin"
      script_native="$repo_root/handoff/scripts/log-progress.sh"
      repo_root_native="$repo_root"
    fi
    post_tool_use_cmd="\"$bash_bin_native\" \"$script_native\" \"$repo_root_native\""

    if jq --arg cmd "$post_tool_use_cmd" '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [
             { "matcher": "Edit|Write|MultiEdit|Bash",
               "hooks": [ { "type": "command", "command": $cmd } ] }
           ])' "$settings_file" > "$tmp_file" 2>/dev/null; then
      mv "$tmp_file" "$settings_file"
      did_something=1
    else
      rm -f "$tmp_file"   # malformed existing settings.json -- leave it alone, don't corrupt it
    fi
  fi
else
  # jq isn't installed -- log-progress.sh itself would silently no-op anyway
  # (same dependency), and hand-editing arbitrary JSON without jq isn't worth
  # the corruption risk, so skip this part rather than guess.
  :
fi

if [ "$did_something" -eq 1 ]; then
  echo "handoff: bootstrapped automatic pipeline for this repo (git post-commit hook + .claude/settings.json PostToolUse hook) -- no manual setup needed." >&2
fi

exit 0
