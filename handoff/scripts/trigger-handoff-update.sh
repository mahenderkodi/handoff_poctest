#!/usr/bin/env bash
# Turns the mechanical log from log-progress.sh into a real handoff update, by
# invoking Claude Code non-interactively (headless, `claude -p`) to run the
# handoff skill's pipeline and update the stable handoffs/handoff.md IN PLACE
# (per ref/pipeline.md step 5), archiving-and-compacting it first if it has
# grown past that step's size threshold, using the progress log as step 1's
# evidence -- a headless run has no tool history of its own to derive from.
#
# OPTIONAL add-on, same as log-progress.sh -- not part of the core skill.
#
# Fires from:
#   - a git post-commit hook (install below) -- one real milestone per commit
#   - optionally, .claude/settings.json's PreCompact hook, pointed at this
#     same script, for the skill's other existing "automatic" trigger
#
# handoffs/handoff.md is the one stable, always-current file -- this script
# updates it in place and never creates a new handoff-<timestamp>.md itself.
# That naming is now reserved for handoffs/.archive/ snapshots only, written
# when handoff.md crosses the size threshold documented in ref/pipeline.md
# step 5 -- that content is never deleted, only relocated into .archive/ once
# the live file would otherwise grow unbounded. (Dot-prefixed like .internal/
# so a plain `ls handoffs/` still shows just handoff.md -- unlike .internal/,
# this folder holds real project history: still a plain directory, never a
# zip, so it stays dependency-free, safe under concurrent writes, and
# readable with a plain `cat` -- just out of the way of a casual listing.)
# The one exception is
# handoffs/.internal/.progress.log itself: once a run successfully merges it
# into handoff.md, the log is deleted (not archived) -- see the delete-vs-
# rotate note further down, where the actual logic lives.
#
# Install the git hook once, from the repo root:
#   cat > .git/hooks/post-commit <<'EOF'
#   #!/usr/bin/env bash
#   exec "$(git rev-parse --show-toplevel)/handoff/scripts/trigger-handoff-update.sh"
#   EOF
#   chmod +x .git/hooks/post-commit
#
# IMPORTANT -- read before enabling:
# INCIDENT (2026-09-12): this script used to run Claude Code with
# --dangerously-skip-permissions -- a real, blanket, unsandboxed grant -- and
# on a real commit it went out of scope for real: the headless run deleted
# unrelated files and edited THIS SCRIPT ITSELF, well beyond reading a
# progress log and writing handoff.md. This was found and stopped by
# disabling the git hook (renaming .git/hooks/post-commit out of the way)
# before it could fire again. That flag is gone now -- see the actual
# invocation below, which uses --allowedTools scoped to Read/Edit under
# handoffs/** only. That scoping is what actually prevents a repeat: it
# can no longer touch handoff/scripts/ (this script's own home -- note the
# singular handoff/, not the plural handoffs/ it's scoped to), backend/, or
# anything else outside the runtime folder it's meant to update, and without
# Bash in the allowed list it cannot delete or shell out at all. An
# unattended background run still has no one present to approve a tool call
# outside that allowlist -- but now, instead of silently being granted
# anyway, it's denied outright, which is the point.
#
# BUG FOUND AND FIXED (2026-09-13), same flag, different mistake: the
# allowlist below originally read --allowedTools "Read(handoffs/**)"
# "Write(handoffs/**)". On a real run, Claude Code's own permission checker
# rejected that outright: "Write(...) is not matched by file permission
# checks -- only Edit(path) rules are. Use Edit(handoffs/**) instead (Edit
# rules cover all file-editing tools)." So the run composed a complete,
# correct handoff.md in memory, then couldn't save it at all (confirmed via
# handoffs/.internal/.last-auto-update.log) -- not a scope violation this
# time, just a rule the tool itself didn't recognize. "Write" was never a
# valid --allowedTools keyword; "Edit" is what actually governs file writes.
# The syntax below is now the CLI-confirmed-correct form.
#
# GAP FOUND AND FIXED (2026-09-13): this script's OWN evidence gate --
# `[ -s "$progress_log" ] || exit 0` -- used to be a hard requirement, not an
# optimization. That log is written exclusively by log-progress.sh, which is
# wired in as a Claude-Code-specific .claude/settings.json PostToolUse hook.
# So a commit made by any OTHER tool (GitHub Copilot CLI, a plain `git
# commit` from a terminal, an IDE's built-in git integration, ...) fires
# .git/hooks/post-commit correctly -- git hooks are tool-agnostic by design,
# they run on the commit itself, not on who made it -- but arrived here with
# an empty .progress.log, and this script silently exited before ever
# calling `claude -p`. Confirmed on a real repo: a Copilot-CLI-driven commit
# ("Add User and Role entities...") produced only .last-auto-update.log
# (stale, from a prior Claude Code run) with no .progress.log next to it at
# all -- proving the git hook fired but this script bailed out on the gate.
#
# Fixed by no longer treating .progress.log as the only source of evidence.
# git itself already knows exactly what changed in a commit, regardless of
# which tool made it -- `git log`, `git diff --stat`, `git show --stat` all
# work identically whether the commit came from Claude Code, Copilot CLI, or
# a bare `git commit` typed by hand. This script now always derives that
# git-based evidence itself (see gather_git_evidence() below) and passes it
# to the headless `claude -p` call as the baseline, tool-agnostic evidence
# for pipeline.md step 1. .progress.log, when present, is layered on top as
# supplementary per-tool-call detail (exact file paths edited, shell
# commands run) -- it enriches the git evidence but is no longer required
# for a run to happen at all. A new handoffs/.internal/.last-handled-commit
# file (just a SHA) tracks the last commit this script successfully
# synthesized, so a run after several tool-agnostic commits in a row (e.g.
# three plain `git commit`s before the next PostToolUse ever fires) still
# covers the full range, not just the latest one. The only remaining skip
# condition is truly nothing-to-do: current HEAD already matches
# .last-handled-commit AND .progress.log is empty (covers a hook re-fire
# with no new commit, and leaves the PreCompact-triggered case -- which can
# have progress-log content with no new commit at all -- still working).
#
# Runs synchronously, bounded by a timeout (see "RUN MADE SYNCHRONOUS
# (2026-09-13)" further down for why this changed from backgrounded) -- adds
# a few seconds to `git commit`, capped well below the timeout in the worst
# case, and logs its own output to handoffs/.internal/.last-auto-update.log
# for debugging.
#
# Everything this add-on writes for its own bookkeeping (.progress.log,
# .last-auto-update.log) lives under handoffs/.internal/, deliberately kept
# out of handoffs/ itself. handoffs/ is what a developer actually looks at
# day to day -- ideally just handoff.md, with .internal/ and .archive/ both
# dot-prefixed out of a plain listing -- and neither of these internal
# bookkeeping files has any standalone value there. On a run that completes
# successfully, .progress.log is deleted outright rather than rotated to a
# timestamped sibling, since its content has already been merged into
# handoff.md and keeping it around only piles up files nobody reads. A FAILED
# run still rotates it (into .internal/, or to .archive/ if it's huge)
# instead of deleting it, so that evidence isn't silently lost if something
# goes wrong.
#
# VERIFIED END-TO-END (2026-09-11): a real commit on the user's machine fired
# this script via .git/hooks/post-commit, which ran the headless `claude -p`
# call above to completion -- it read the progress log, merged that
# progress into handoffs/handoff.md in place (Done items preserved, new
# milestone appended, Generated: timestamp refreshed), then this script
# cleared the progress log and logged the full run to
# handoffs/.internal/.last-auto-update.log. One real gotcha hit during that
# test: the headless claude -p process can still be running (check with a
# process listing, e.g. Get-CimInstance Win32_Process on Windows) even after
# handoff.md already shows the fresh write -- the log/cleanup steps below it
# only complete once that process actually exits, so an empty
# .last-auto-update.log or a still-present .progress.log right after a
# commit does not mean it failed; give it time (tens of seconds) before
# concluding that. (Note: at verification time this script still rotated
# .progress.log to a timestamped sibling on every run, developer-visible
# clutter it produced was the reason the delete-on-success behavior below
# was added afterward -- the merge/archive logic itself is unchanged.)
# The one-time missing-dependency gap this surfaced (not a bug in this
# script): log-progress.sh silently no-ops if `jq` isn't installed, which
# means .progress.log never gets populated and this script's own `[ -s
# "$progress_log" ] || exit 0` guard then exits before ever reaching the
# `claude -p` call -- install `jq` first if the chain seems inert.
#
# PREREQUISITE, Windows especially -- set this ONCE before relying on the git
# hook, not after hitting the symptom: this script launches a *second*,
# background `claude.exe` process on every commit. If Claude Code's own
# self-updater tries to replace claude.exe while that background process (or
# any other `claude` session) is still running, it fails with an
# unrelated-looking "claude.exe in use" error -- that's this add-on's own
# background process holding the file lock, not a real problem with your
# install. Fix once, in a fresh terminal afterward:
#   setx DISABLE_AUTOUPDATER 1
# You can still update deliberately later (npm update -g @anthropic-ai/claude-code);
# this only stops the CLI from silently racing itself against this script.

# NOUNSET DROPPED (2026-09-13) -- this used to be `set -uo pipefail`. Proven
# on a real test (a throwaway repo, sourcing a real, unmodified .bashrc) that
# `set -u` + sourcing an arbitrary third-party shell rc file is a landmine:
# if that rc file references ANY variable that happens to be unset in this
# non-interactive, hook-spawned shell -- extremely common, since .bashrc/
# .bash_profile/.profile are written for interactive terminals, not this
# context -- bash's nounset treats that as fatal and kills the ENTIRE
# script right there, silently: no error visible to whatever invoked git
# commit, and nothing written to handoffs/.internal/.last-auto-update.log,
# because that killed the process before even reaching the point where this
# script opens that log for writing. This exactly matches a real symptom:
# the git hook fires and works when Claude Code makes the commit, but two
# Copilot-CLI-driven commits in a row produced zero trace in
# .last-auto-update.log even after the tool-agnostic evidence fix below was
# already in place -- consistent with Copilot CLI spawning git's hook in a
# shell environment (different HOME/PATH/env than Claude Code's own shell)
# where sourcing the profile files below hits an unset variable and dies,
# while Claude Code's happens not to. `pipefail` alone carries none of that
# risk and is kept.
set -o pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" || exit 0

internal_dir="$repo_root/handoffs/.internal"
progress_log="$internal_dir/.progress.log"
update_log="$internal_dir/.last-auto-update.log"
last_handled_file="$internal_dir/.last-handled-commit"
mkdir -p "$internal_dir" 2>/dev/null

# Unconditional heartbeat (2026-09-13) -- written before anything below that
# could still fail (profile sourcing, `command -v claude`, the claude call
# itself), so a run that dies partway through still leaves proof it got at
# least this far, and what its environment looked like at that point. This
# is what would have caught the nounset problem above immediately instead
# of needing forensic reconstruction after the fact.
{
  printf '%s hook fired (pid %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$"
  printf '  repo_root=%s\n' "$repo_root"
  printf '  HOME=%s  PWD=%s\n' "${HOME:-<unset>}" "$PWD"
  printf '  HEAD=%s\n' "$(git rev-parse HEAD 2>&1)"
} >> "$update_log" 2>&1

# Git hooks run in a minimal, non-interactive shell -- it does NOT source
# .bashrc / .bash_profile the way your normal terminal does, so PATH here can
# be missing whatever those files add. On most setups that's exactly how
# `claude` becomes findable (npm/nvm global bin dirs) -- so `command -v claude`
# below can fail here even though `claude --version` works fine when you type
# it yourself, and this whole script then exits silently on that line, before
# ever writing handoffs/.internal/.last-auto-update.log. Source the same
# profile files the interactive shell uses, if present, so resolution matches:
for rc in "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$rc" ] && . "$rc" >/dev/null 2>&1
done
# Belt-and-suspenders fallback: common global-install bin dirs, in case PATH
# is set some other way (a Windows env var, a shell config the above didn't
# cover) rather than through one of those profile files.
for extra in "$HOME/AppData/Roaming/npm" "$HOME/.npm-global/bin" "/usr/local/bin" "$HOME/.local/bin"; do
  [ -d "$extra" ] && PATH="$PATH:$extra"
done
export PATH

printf '  claude resolves to: %s\n' "$(command -v claude 2>&1 || echo '<not found>')" >> "$update_log" 2>&1

current_head="$(git rev-parse HEAD 2>/dev/null || true)"
last_handled="$(cat "$last_handled_file" 2>/dev/null || true)"

# Truly nothing to do: no new commit since the last successful synthesis,
# AND no mechanical Claude-Code evidence waiting either. (Kept as two
# conditions, not one, so the PreCompact-triggered case -- progress-log
# content with no new commit at all -- still runs.)
if [ -n "$current_head" ] && [ "$current_head" = "$last_handled" ] && [ ! -s "$progress_log" ]; then
  exit 0
fi

command -v claude >/dev/null 2>&1 || exit 0   # Claude Code CLI not on PATH here -> skip silently

# Derive tool-agnostic evidence directly from git -- this is what makes a
# commit from Copilot CLI, a bare `git commit`, or any other tool produce a
# real handoff update, not just commits made through Claude Code itself. See
# the "GAP FOUND AND FIXED (2026-09-13)" note above for why this exists.
gather_git_evidence() {
  local base="$1" head="$2"
  if [ -n "$head" ] && [ "$base" = "$head" ]; then
    # Fired with no new commit at all -- e.g. the PreCompact hook, or a
    # progress log left over from mid-session work that hasn't been
    # committed yet. There is no commit range to describe; say so plainly
    # rather than printing a confusing empty "X..X" range.
    echo "No new commit since the last handoff update (HEAD is still $head)."
    echo "Any evidence for this run comes from the supplementary log below, if present."
  elif [ -n "$head" ] && [ -n "$base" ] && git rev-parse --verify "$base" >/dev/null 2>&1; then
    echo "Commit(s) since the last handoff update ($base..$head):"
    echo
    git log --format='- %h  %ad  %an: %s' --date=short "$base..$head" 2>/dev/null
    echo
    echo "Files changed:"
    git diff --stat "$base" "$head" 2>/dev/null
  elif [ -n "$head" ]; then
    # No usable base -- either this is the very first run (no
    # .last-handled-commit yet) or HEAD has no parent (initial commit).
    # Describe HEAD by itself instead of a range.
    echo "Most recent commit (no prior handled commit on record -- describing HEAD alone):"
    echo
    git log --format='- %h  %ad  %an: %s' --date=short -1 "$head" 2>/dev/null
    echo
    echo "Files in this commit:"
    git show --stat --format='' "$head" 2>/dev/null
  else
    echo "(no git evidence available -- not inside a resolvable git repo at run time)"
  fi
}

# SPEED (2026-09-13): the headless run used to figure all of this out for
# itself -- reading SKILL.md, then ref/pipeline.md, then a template file,
# then handoffs/handoff.md, then handoffs/.internal/.progress.log, each a
# separate Read tool round trip (model turn -> tool call -> permission check
# -> result -> next model turn), before it could even start composing. Worse,
# --allowedTools here has never included Bash (see the INCIDENT note near
# the top of this file for why), so it was NEVER able to run pipeline.md
# step 1's own git probes (branch, HEAD, status, author) itself -- this
# wrapper script has full git access and just... didn't hand any of that
# over as text, leaving a real gap independent of speed. Now this script
# gathers everything itself and embeds it as plain text in one prompt, so
# the run ideally needs zero Read calls and exactly one Edit call.
gather_git_metadata() {
  local branch head status author_raw author_slug
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  head="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  status="$(git status --porcelain 2>/dev/null)"
  # Author resolution mirrors ref/pipeline.md step 1 exactly: prefer the
  # GitHub login of whoever is actually authenticated to push (dynamic
  # across whichever developer/machine runs this), falling back through
  # local git identity, never asking or guessing.
  author_raw="$(command -v gh >/dev/null 2>&1 && gh api user --jq .login 2>/dev/null || true)"
  [ -z "$author_raw" ] && author_raw="$(git config user.name 2>/dev/null || true)"
  [ -z "$author_raw" ] && author_raw="$(git config user.email 2>/dev/null | cut -d@ -f1 || true)"
  [ -z "$author_raw" ] && author_raw="unknown"
  author_slug="$(printf '%s' "$author_raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -z "$author_slug" ] && author_slug="unknown"
  echo "Branch: $branch"
  echo "HEAD: $head"
  echo "Author (for Metadata / archive filename slug): $author_slug"
  if [ -n "$status" ]; then
    echo "Working tree: dirty --"
    printf '%s\n' "$status"
  else
    echo "Working tree: clean"
  fi
}
git_metadata="$(gather_git_metadata)"

# Current handoffs/handoff.md content, read directly here rather than making
# the headless run Read it itself.
handoff_file_preview=""
if [ -f "$repo_root/handoffs/handoff.md" ]; then
  handoff_file_preview="$(cat "$repo_root/handoffs/handoff.md" 2>/dev/null)"
fi

# Same for the progress log, when Claude Code did populate it -- cat it
# ourselves instead of telling the headless run to go Read the file.
progress_content=""
if [ -s "$progress_log" ]; then
  progress_content="$(cat "$progress_log" 2>/dev/null)"
fi

base_commit="$last_handled"
if [ -z "$base_commit" ] && [ -n "$current_head" ]; then
  # --verify matters here: plain `git rev-parse foo^` on a rev with no
  # parent doesn't fail quietly -- it prints the literal unresolved string
  # back to stdout (documented rev-parse behavior for filtering args in
  # scripts) while still exiting non-zero. Without --verify, base_commit
  # would end up holding that literal "<sha>^" text instead of staying
  # empty. gather_git_evidence() re-verifies its own "base" argument before
  # trusting it as a range, so that stray value was already harmless -- this
  # just makes base_commit itself correct too, instead of relying solely on
  # that inner guard.
  base_commit="$(git rev-parse --verify "$current_head^" 2>/dev/null || true)"
fi
git_evidence="$(gather_git_evidence "$base_commit" "$current_head")"

# See "RUN MADE SYNCHRONOUS (2026-09-13)" below run_update() for why this
# exists. `timeout` ships with Git for Windows' coreutils and with most
# Linux/macOS setups, but isn't guaranteed everywhere -- degrade to running
# unbounded rather than erroring out if it's genuinely missing.
#
# 240s, not 150s (2026-09-13): raised after noticing the observed "2-3
# minutes" (up to 180s) sat uncomfortably close to the original 150s bound
# -- a run at the slow end could have been killed by the timeout itself
# before finishing, silently dropping that update (harmlessly retried on the
# next commit, but still avoidable). The SPEED changes above this run_update
# call should make actual runs much faster now that the prompt is
# self-contained, but this margin is widened regardless, independent of
# whether that speedup lands as hoped.
timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd="timeout 240"
fi

run_update() {
  local handoff_file="$repo_root/handoffs/handoff.md"

  # Record handoff.md's mtime BEFORE the call, so success can be verified by
  # more than just claude's exit code -- see the note below on why exit code
  # alone is not trustworthy here.
  local before_mtime=""
  [ -f "$handoff_file" ] && before_mtime="$(stat -c %Y "$handoff_file" 2>/dev/null)"

  # --model haiku (2026-09-13): trading the default model for a faster one
  # here, since this task -- folding evidence into a fixed template -- is
  # mostly mechanical, not deeply creative. If handoff quality noticeably
  # degrades, drop this flag (falls back to the default model) or swap it
  # for --model sonnet.
  #
  # SPEED (2026-09-13), same date as the "SPEED" note above run_update():
  # this prompt used to say "Use the handoff skill" and rely on the headless
  # run to Read SKILL.md, ref/pipeline.md, handoffs/handoff.md and
  # handoffs/.internal/.progress.log itself -- several sequential tool round
  # trips (each: model turn, tool call, permission check, result, next model
  # turn) before composing anything, which is most of where the observed
  # 2-3 minutes went. Everything it would have Read is now handed over as
  # plain text below instead: git_metadata and git_evidence (gathered with
  # full git access this script has but the sandboxed headless run never
  # did -- it has no Bash in --allowedTools, so it could never have run
  # those probes itself even if told to), handoff_file_preview (the current
  # file, so no Read is needed to see what to merge into), and
  # progress_content (ditto for the progress log). The instructions below
  # are pipeline.md step 3/5's own rules, condensed to what's needed to act
  # on them, not a request to go re-read that file. Ideally this run now
  # makes zero Read calls and exactly one Edit call. Read(handoffs/**) stays
  # in --allowedTools as a safety net, not a requirement.
  $timeout_cmd claude -p "Update the stable handoff file at handoffs/handoff.md for this project, in place. Do not ask questions; there is no one present to answer them.

--- Git metadata (from pipeline.md step 1's own probes, run directly by the
calling script since a headless run can't run git itself -- use these
verbatim for the handoff's Metadata section, do not re-derive them) ---
$git_metadata
--- end git metadata ---

--- Git evidence for what changed (authoritative; derived directly from the
commit(s) themselves, so it holds regardless of which tool made them --
Claude Code, GitHub Copilot CLI, a bare git commit, or anything else) ---
$git_evidence
--- end git evidence ---
$([ -n "$progress_content" ] && printf '%s\n' "
--- Supplementary Claude-Code tool-call log (tab-separated: UTC timestamp,
tool name, then a file path or shell command -- extra per-call detail on top
of the git evidence above, only available for the portion of this work that
went through Claude Code itself) ---
$progress_content
--- end supplementary log ---")
$([ -n "$handoff_file_preview" ] && printf '%s\n' "
--- Current handoffs/handoff.md content (merge the evidence above into
this -- promote In Progress to Done, refresh the Immediate Next Step, drop
or update stale Open Questions; keep all still-relevant prior info. Do NOT
start a fresh timestamped file; this IS the file to update in place) ---
$handoff_file_preview
--- end current handoff.md ---")
$([ -z "$handoff_file_preview" ] && echo "handoffs/handoff.md does not exist yet -- create it, following ref/templates/handoff.md's structure if you have it available, otherwise a Metadata / Current State / Done / Immediate Next Step / Key Decisions / Open Questions structure.")

If the merged content would put handoffs/handoff.md at or over ~30KB, first
write the FULL merged draft, unabridged, to
handoffs/.archive/handoff-<UTC-timestamp>-<author-slug-from-git-metadata-above>.md
(create handoffs/.archive/ if missing; UTC timestamp like
2026-09-13T12-00-00-000Z), then write a COMPACT handoffs/handoff.md
containing only: Metadata, Current State, still-open Key Decisions, the
active blocker, the single Immediate Next Step, and any still-unanswered
Open Question -- plus a Handoff Chain -> Archived predecessor: line pointing
at the file you just archived. Never delete detail, only relocate it into
the archive. Write the updated handoff, then stop." \
    --allowedTools "Read(handoffs/**)" "Edit(handoffs/**)" \
    --model haiku \
    >> "$update_log" 2>&1
  local claude_exit=$?

  # DISCOVERED (2026-09-13): claude_exit alone is not proof anything was
  # written. Two real runs exited 0 while the model gave up mid-task on a
  # permission wall and wrote nothing at all (confirmed via
  # handoffs/.internal/.last-auto-update.log both times) -- a clean process
  # exit just means claude didn't crash, not that it finished the job. So
  # also require handoff.md to have actually changed: its mtime must differ
  # from before the call (or the file must be new), not just claude_exit==0.
  local after_mtime=""
  [ -f "$handoff_file" ] && after_mtime="$(stat -c %Y "$handoff_file" 2>/dev/null)"
  local wrote_handoff=0
  if [ -n "$after_mtime" ] && [ "$after_mtime" != "$before_mtime" ]; then
    wrote_handoff=1
  fi

  if [ "$claude_exit" -eq 0 ] && [ "$wrote_handoff" -eq 1 ]; then
    # Success: the progress log's content is now merged into handoff.md, so
    # it has no further value -- delete it rather than piling up rotated
    # copies nobody looks at. This is the one deliberate exception to the
    # skill's general "never delete, only relocate" rule, because this file
    # is internal working data (consumed input), not project history.
    rm -f "$progress_log"
    # Record the commit this run actually covered, so the NEXT run (from
    # whatever tool) knows where to start its git evidence range from,
    # rather than only ever looking at HEAD's immediate parent.
    [ -n "$current_head" ] && printf '%s\n' "$current_head" > "$last_handled_file"
  elif [ -s "$progress_log" ]; then
    # Failure: keep the evidence as a safety net instead of losing it, same
    # as before -- just relocated under .internal/ instead of handoffs/.
    if [ "$(wc -c < "$progress_log" 2>/dev/null || echo 0)" -ge 1048576 ]; then
      mkdir -p "$repo_root/handoffs/.archive"
      mv "$progress_log" "$repo_root/handoffs/.archive/progress-$(date -u +%Y-%m-%d).log"
    else
      mv "$progress_log" "$progress_log.$(date -u +%Y%m%dT%H%M%SZ)"
    fi
  fi
}

# RUN MADE SYNCHRONOUS (2026-09-13): this used to be `run_update & disown`,
# on the theory that backgrounding + disowning would let git commit return
# immediately while the (slower) claude call kept running independently.
# That held for Claude Code specifically -- its Bash tool keeps one
# persistent shell alive for the whole session, so a disowned child gets
# time to finish and gets reparented cleanly once the shell that spawned it
# is long-lived. It silently failed for Copilot CLI: confirmed on a real
# repo that the heartbeat above (proving the hook fired and even resolved
# `claude` on PATH correctly this time) got written, but nothing else ever
# followed it -- not even a failure trace -- for over three minutes, and
# handoff.md never changed. The likely mechanism: Copilot CLI (like most
# tools that just need to run one git command) spawns a short-lived
# process/console purely to run `git commit`, and tears down that whole
# process tree the instant it returns -- taking the disowned-but-still-
# attached `claude -p` child down with it before it can write anything,
# especially plausible on Windows where a parent process's console/job
# object killing its children on exit is a common default. `disown` only
# detaches a job from the CURRENT shell's job table; it does not make the
# process immune to its whole process tree being torn down.
#
# Fixed by no longer racing the invoking tool's process teardown at all:
# run_update now runs in the foreground, bounded by $timeout_cmd (150s) so
# a hung or unusually slow call still can't block `git commit` indefinitely.
# This does trade away the old "never blocks commit" property for a few
# (usually single-digit, with --model haiku) extra seconds on every commit
# -- a reasonable price for actually working across whatever tool made the
# commit, rather than working only for the one tool that happens to keep a
# long-lived shell around.
run_update
exit 0
