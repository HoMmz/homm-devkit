#!/bin/bash
# homm-devkit — Stop / SubagentStop hook: before an agent may finish, re-run check.sh on EVERY file
# that differs from git HEAD in the working repo (tracked changes + untracked files) and that at least
# one configured check applies to.
# Catches edits made outside Edit/Write (sed, heredoc, scripts) and work done in worktrees.
#
# Exit codes: 0 clean / not a repo · 2 block "done" (stderr goes back to Claude) · 1 warn the user only
# Loop guard: if Claude is already continuing because of a stop hook (stop_hook_active=true) and the
# problems remain, warn instead of blocking again — the user decides.
# Note: uncommitted changes are checked whoever made them (they may include the user's own edits).

set -u
here=$(cd "$(dirname "$0")" && pwd)

command -v jq >/dev/null 2>&1 || { echo "devkit: stop-check SKIPPED — jq is not installed" >&2; exit 1; }
input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null); [[ -n "$cwd" && -d "$cwd" ]] || cwd=$PWD
active=$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null)

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
git -C "$root" rev-parse --verify -q HEAD >/dev/null || exit 0   # no commits yet

changed=$( { git -C "$root" -c core.quotePath=false diff --name-only --diff-filter=ACMR HEAD
             git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard; } | sort -u )
[[ -n "$changed" ]] || exit 0
raw_max=${DEVKIT_STOP_MAX_CHANGED:-2000}
if (( $(wc -l <<<"$changed") > raw_max )); then
  echo "devkit: stop-check SKIPPED — more than $raw_max changed/untracked files (ignore build/upload dirs, or run checks manually)" >&2
  exit 1
fi
files=$("$here/check.sh" --filter "$root" <<<"$changed"); frc=$?
if [[ $frc == 3 ]]; then exit 1                # config unusable: check.sh already printed SKIPPED
elif [[ $frc != 0 ]]; then echo "devkit: stop-check SKIPPED — check.sh --filter failed (exit $frc)" >&2; exit 1; fi
[[ -n "$files" ]] || exit 0
max=${DEVKIT_STOP_MAX_FILES:-40}
count=$(wc -l <<<"$files" | tr -d ' ')
if (( count > max )); then
  echo "devkit: stop-check SKIPPED — $count changed files with checks (> $max); run checks manually" >&2
  exit 1
fi

blocked=""; warned=""
while IFS= read -r rel; do
  f="$root/$rel"
  [[ -f "$f" ]] || continue
  out=$(jq -n --arg f "$f" '{tool_input:{file_path:$f}}' | "$here/check.sh" 2>&1); rc=$?
  if [[ $rc == 2 ]]; then blocked+="$out"$'\n'
  elif [[ $rc == 1 ]]; then warned+="$out"$'\n'
  fi
done <<<"$files"

if [[ -n "$blocked" ]]; then
  if [[ "$active" == "true" ]]; then
    printf 'devkit: stop-check still failing after a retry — not blocking again, please review:\n%s%s' "$blocked" "$warned" >&2
    exit 1
  fi
  printf 'devkit: not done yet — changed files (vs git HEAD) have regressions:\n%s' "$blocked" >&2
  [[ -n "$warned" ]] && printf '%s' "$warned" >&2
  echo "Fix these before finishing (they may come from edits made with Bash or in another tool)." >&2
  exit 2
fi
if [[ -n "$warned" ]]; then printf '%s' "$warned" >&2; exit 1; fi
exit 0
