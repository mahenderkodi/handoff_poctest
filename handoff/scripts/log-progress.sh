#!/usr/bin/env bash
# PostToolUse hook: mechanically logs what changed, for the handoff skill's
# periodic-synthesis auto-update mode. Never blocks or fails the tool call
# it's watching -- always exits 0, writes nothing to stdout.
#
# This is OPTIONAL tooling on top of the handoff skill, not part of the
# skill's core pipeline -- the skill itself stays dependency-free. Only
# needed if you want handoffs/.internal/.progress.log to feed automatic
# updates (see trigger-handoff-update.sh and README.md's "Automatic
# updates" section).
#
# Writes to handoffs/.internal/ -- a dedicated, out-of-the-way subfolder --
# deliberately, not directly into handoffs/. handoffs/ itself should only
# ever show what a developer actually wants to see day to day (handoff.md,
# and Archive/ if it exists); this raw mechanical log has no standalone
# value to a developer and is purely internal fuel for trigger-handoff-update.sh.
#
# Requires: jq. If jq isn't installed, this silently no-ops (never fails
# the tool call it's attached to).
#
# Install, in the WORKING PROJECT's .claude/settings.json (not this skill's
# own settings -- this hook runs once per project that opts in), OR just let
# handoff/scripts/bootstrap-handoff.sh install this automatically (see
# README.md's "Setup -- automatic"):
#   "hooks": {
#     "PostToolUse": [
#       { "matcher": "Edit|Write|MultiEdit|Bash",
#         "hooks": [ { "type": "command", "command": "bash handoff/scripts/log-progress.sh" } ] }
#     ]
#   }
#
# NOTE the leading "bash " in that command -- DISCOVERED (2026-09-13): unlike
# a git hook (which git itself dispatches through an interpreter, honoring
# the #!/usr/bin/env bash line above), Claude Code's own PostToolUse hook
# launcher does not interpret shebangs on Windows. A bare
# "handoff/scripts/log-progress.sh" command fails there with "No such file
# or directory" even though the file exists and is executable -- always
# invoke it through bash explicitly instead of relying on the shebang.
#
# ALSO DISCOVERED (2026-09-13), same day: a *relative* path here
# ("handoff/scripts/log-progress.sh") still failed with the same "No such
# file or directory" even once wrapped in "bash", because Claude Code's
# PostToolUse hook launcher does not reliably run with cwd set to the
# project root on Windows the way a git hook does -- and separately, "bash"
# itself can resolve to an unrelated WSL bash.exe (if one is on PATH ahead
# of Git Bash's) whose filesystem view has no relation to the Windows
# project path at all. bootstrap-handoff.sh now installs this hook with
# fully absolute, machine-resolved paths for both the bash executable and
# this script (via cygpath -w at install time), plus the project root passed
# as $1 below -- see the accepted-argument fallback immediately after this
# comment block. That removes the dependency on both PATH and cwd entirely.
# If you're wiring this up by hand instead of via bootstrap-handoff.sh, pass
# the absolute repo root as the first argument for the same robustness:
#   "command": "\"C:\\path\\to\\bash.exe\" \"C:\\path\\to\\project\\handoff\\scripts\\log-progress.sh\" \"C:\\path\\to\\project\""
#
# Adjust the command path if the skill is installed somewhere other than
# ./handoff relative to the project root Claude Code runs hooks from.

set -uo pipefail

# Prefer an explicit repo root passed as $1 (what bootstrap-handoff.sh now
# installs) over deriving it from `git rev-parse`, which depends on cwd
# being inside the repo -- not guaranteed for every hook launcher/platform.
explicit_repo_root="${1:-}"

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
[ -z "$tool_name" ] && exit 0

detail=""
case "$tool_name" in
  Edit|Write|MultiEdit)
    detail="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    ;;
  Bash)
    detail="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null | head -c 200)"
    ;;
  *)
    exit 0   # only log tool calls that represent real work on the project
    ;;
esac
[ -z "$detail" ] && exit 0

repo_root="${explicit_repo_root:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
log_dir="$repo_root/handoffs/.internal"
mkdir -p "$log_dir" 2>/dev/null

ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '%s\t%s\t%s\n' "$ts" "$tool_name" "$detail" >> "$log_dir/.progress.log" 2>/dev/null

exit 0
