#!/bin/bash
# homm-devkit — PreToolUse guard (Read | Grep | Bash). Exit 2 = deny the tool call (stderr goes to Claude).
#
# 1. Secrets: never read .env files (all repos) — Read/Grep on a .env path, or a Bash command that names one.
#    Allowed: .env.example / .env.sample / .env.dist / .env.template
# 2. Protected branches (only repos with "guards.protectBranches" in ~/.claude/devkit/repos.json):
#    no `git commit` / `git merge` / `git cherry-pick` / `git rebase` while on a protected branch,
#    no `git push` that targets one. Explicit user approval: prefix the command with DEVKIT_ALLOW_MASTER=1
#    (visible in the transcript — use it only when the user asked for this merge/push).

set -u
command -v jq >/dev/null 2>&1 || exit 0          # cannot inspect: don't break every tool call
input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input"); [[ -n "$cwd" && -d "$cwd" ]] || cwd=$PWD

deny() { echo "devkit guard: $1" >&2; exit 2; }

# ---- 1. .env secrets ----
allowed_suffix='^\.env\.(example|sample|dist|template)$'
is_secret_env_path() {   # $1 = path
  local b; b=$(basename -- "$1")
  [[ "$b" =~ ^\.env(\..+)?$ ]] || return 1
  [[ "$b" =~ $allowed_suffix ]] && return 1
  return 0
}
case "$tool" in
  Read)
    p=$(jq -r '.tool_input.file_path // empty' <<<"$input")
    [[ -n "$p" ]] && is_secret_env_path "$p" && deny "reading $(basename -- "$p") is not allowed (secrets). Use getenv() in code, or ask the user for the specific non-secret value."
    ;;
  Grep)
    p=$(jq -r '.tool_input.path // empty' <<<"$input")
    [[ -n "$p" ]] && is_secret_env_path "$p" && deny "searching inside $(basename -- "$p") is not allowed (secrets)."
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
    # split the command into words (shell separators, quotes, redirects); a word whose basename is
    # .env or .env.<anything> is a secret file unless it is an allowed template name
    while IFS= read -r word; do
      [[ -z "$word" ]] && continue
      is_secret_env_path "$word" || continue
      deny "the command references $(basename -- "$word") (secrets). Don't read/print/copy .env files; use getenv() in code. If the user really needs this, they can run it themselves."
    done < <(tr -s " \t\n;&|<>()\"'\`=,:" '\n' <<<"$cmd")
    ;;
esac

# ---- 2. protected branches (Bash only) ----
[[ "$tool" == "Bash" ]] || exit 0
grep -qE '(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|merge|cherry-pick|rebase|push)([[:space:]]|$)' <<<"$cmd" || exit 0
[[ "$cmd" == *DEVKIT_ALLOW_MASTER=1* ]] && exit 0

# repo dir: `git -C <dir>`, else the LAST `cd <dir>` before the first git write command
# (handles `set -o pipefail; cd X && git commit`, `foo && cd X && git push`), else cwd
dir=$(grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' <<<"$cmd" | head -1 | awk '{print $3}')
if [[ -z "$dir" ]]; then
  off=$(grep -boE '(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|merge|cherry-pick|rebase|push)([[:space:]]|$)' <<<"$cmd" | head -1 | cut -d: -f1)
  prefix=${cmd:0:${off:-0}}
  dir=$(grep -oE '(^|[;&|(])[[:space:]]*cd[[:space:]]+[^[:space:];&|)]+' <<<"$prefix" | tail -1 | sed -E 's/^[;&|(]?[[:space:]]*cd[[:space:]]+//')
fi
dir=${dir/#\~/$HOME}; dir=${dir//\"/}; dir=${dir//\'/}
[[ -n "$dir" && "$dir" != /* ]] && dir="$cwd/$dir"
[[ -n "$dir" && -d "$dir" ]] || dir=$cwd
root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
root=$(realpath "$root")

cfgfile=${DEVKIT_CONFIG:-$HOME/.claude/devkit/repos.json}
[[ -f "$cfgfile" ]] || exit 0
protected=$(jq -r --arg r "$root" '(.repos[$r].guards.protectBranches // []) | .[]' "$cfgfile" 2>/dev/null)
[[ -n "$protected" ]] || exit 0

branch=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)
while IFS= read -r pb; do
  [[ -z "$pb" ]] && continue
  if grep -qE 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|merge|cherry-pick|rebase)([[:space:]]|$)' <<<"$cmd" && [[ "$branch" == "$pb" ]]; then
    # a `git switch -c/checkout -b` earlier in the same command moves off the protected branch
    grep -qE 'git[[:space:]]+(switch[[:space:]]+-c|checkout[[:space:]]+-b)[[:space:]]' <<<"$cmd" && continue
    deny "you are on protected branch '$pb' in $root — work on a task branch (git switch -c <name>). Merge into '$pb' only when the user asked; then prefix the command with DEVKIT_ALLOW_MASTER=1."
  fi
  if grep -qE "git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|\$)" <<<"$cmd"; then
    if grep -qE "push[^;&|]*[[:space:]:]$pb([[:space:];&|]|\$)" <<<"$cmd" || { [[ "$branch" == "$pb" ]] && ! grep -qE 'push[^;&|]*[[:space:]](origin|upstream)[[:space:]]+[^-[:space:]]' <<<"$cmd"; }; then
      deny "push to protected branch '$pb' in $root needs the user's explicit go-ahead; then prefix the command with DEVKIT_ALLOW_MASTER=1."
    fi
  fi
done <<<"$protected"
exit 0
