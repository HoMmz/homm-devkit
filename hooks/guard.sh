#!/bin/bash
# homm-devkit — PreToolUse guard (Read | Grep | Bash). Exit 2 = deny the tool call (stderr goes to Claude).
#
# A speed bump against an agent's ACCIDENTAL mistakes — not a security boundary. A shell can always
# reach a file or a branch another way (globs, interpreters, $(...)). For real protection use Claude
# Code permissions/sandbox and server-side branch protection. Known limits are pinned in tests/run.sh.
#
# 1. Secrets: never read .env files (all repos) — Read/Grep on a .env path or glob, or a Bash command that
#    names one. Case-insensitive. Allowed: .env.example / .env.sample / .env.dist / .env.template
# 2. Protected branches (only repos with "guards.protectBranches" in ~/.claude/devkit/repos.json; a git
#    worktree uses its main repo's entry): every git commit / merge / cherry-pick / rebase / push in the
#    command is judged on the branch it will run on (following `git checkout|switch` earlier in the same
#    command). No write on a protected branch, no push that targets one. Explicit user approval: prefix the
#    git command with DEVKIT_ALLOW_MASTER=1 (visible in the transcript — only when the user asked).

set -u
export LC_ALL=C   # byte offsets from grep -b must match ${var:off} (multi-byte text in commands)
command -v jq >/dev/null 2>&1 || exit 0          # cannot inspect: don't break every tool call
input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input"); [[ -n "$cwd" && -d "$cwd" ]] || cwd=$PWD

deny() { echo "devkit guard: $1" >&2; exit 2; }

# ---- 1. .env secrets ----
allowed_suffix='^\.env\.(example|sample|dist|template)$'
is_secret_env_path() {   # $1 = path or glob; case-insensitive (macOS file systems usually are)
  local b; b=$(basename -- "$1" | tr '[:upper:]' '[:lower:]')
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
    gl=$(jq -r '.tool_input.glob // empty' <<<"$input")
    # a glob aimed at .env files (".env", ".env*", "**/.env.local", "{.env,x}") — strip glob chars first
    gb=$(basename -- "${gl:-x}" | tr -d '*?[]{}' | tr '[:upper:]' '[:lower:]')
    if [[ -n "$gl" ]] && [[ "$gb" == ".env" || "$gb" == .env.* || "$gb" == .env,* ]] && ! [[ "$gb" =~ $allowed_suffix ]]; then
      deny "a Grep glob that targets .env files is not allowed (secrets)."
    fi
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
    # split the command into words (shell separators, quotes, redirects); a word whose basename is
    # .env or .env.<anything> is a secret file unless it is an allowed template name
    while IFS= read -r word; do
      [[ "$word" == *.[Ee][Nn][Vv]* ]] || continue       # cheap pre-filter: no subshell per word
      is_secret_env_path "$word" || continue
      deny "the command references $(basename -- "$word") (secrets). Don't read/print/copy .env files; use getenv() in code. If the user really needs this, they can run it themselves."
    done < <(tr -s " \t\n;&|<>()\"'\`=,:" '\n' <<<"$cmd")
    ;;
esac

# ---- 2. protected branches (Bash only) ----
[[ "$tool" == "Bash" ]] || exit 0
# a space before ; & | ) ` so "git push)", "git push;x", "(git checkout master)" parse like the spaced forms
cmd=$(sed -E 's/([;&|)`])/ \1/g' <<<"$cmd")

# a git invocation in command position: line start or after ; & | ( ` — optionally after VAR=x assignments,
# shell keywords (then/else/elif/do/!/{) or wrappers (command/env/sudo/time/nice/xargs/timeout N);
# optional path or "\" before git; then any global options; then the subcommand
gopt='([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|--(git-dir|work-tree|namespace|exec-path)[[:space:]]+[^[:space:];&|]+|--[a-z][a-z-]*(=[^[:space:];&|]+)?|-[pP]))*'
assign='[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+'   # VAR=x, VAR="a b", VAR='a b'
gstart='(^|[;&|(`])[[:space:]]*('"$assign"'|(command|env|sudo|time|nice|xargs|then|else|elif|do|!|\{)[[:space:]]+|timeout[[:space:]]+[0-9.]+[smhd]?[[:space:]]+)*([^[:space:];&|()`]*/)?\\?git'
WRITE_RE="${gstart}${gopt}[[:space:]]+(commit|merge|cherry-pick|rebase)([[:space:]]|$)"
PUSH_RE="${gstart}${gopt}[[:space:]]+push([[:space:]]|$)"
SWITCH_RE="${gstart}${gopt}[[:space:]]+(checkout|switch)([[:space:]][^;&|)\`]*)?"
grep -qE "$WRITE_RE|$PUSH_RE" <<<"$cmd" || exit 0
# explicit approval = env prefix of a git command (other VAR=x may surround it), not text anywhere
grep -qE "(^|[;&|(])[[:space:]]*(${assign})*DEVKIT_ALLOW_MASTER=1[[:space:]]+(${assign})*([^[:space:]]*/)?git([[:space:]]|$)" <<<"$cmd" && exit 0

# repo dir (from the first git write/push): `git -C <dir>` / `--work-tree <dir>`, else the LAST
# `cd|pushd <dir>` before it, else cwd
off0=$(grep -boE "$WRITE_RE|$PUSH_RE" <<<"$cmd" | head -1 | cut -d: -f1); off0=${off0:-0}
first=$(grep -oE "$WRITE_RE|$PUSH_RE" <<<"${cmd:off0}" | head -1)
dir=$(grep -oE -- '(-C|--work-tree)[[:space:]=]+[^[:space:];&|]+' <<<"$first" | head -1 | sed -E 's/^(-C|--work-tree)[[:space:]=]+//')
[[ -n "$dir" ]] || dir=$(grep -oE '(^|[;&|(])[[:space:]]*(cd|pushd)[[:space:]]+[^[:space:];&|)]+' <<<"${cmd:0:off0}" | tail -1 | sed -E 's/^[;&|(]?[[:space:]]*(cd|pushd)[[:space:]]+//')
dir=${dir/#\~/$HOME}; dir=${dir//\"/}; dir=${dir//\'/}
[[ -n "$dir" && "$dir" != /* ]] && dir="$cwd/$dir"
[[ -n "$dir" && -d "$dir" ]] || dir=$cwd
root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
root=$(realpath "$root")
main=""   # a worktree uses its main repo's config entry
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  && [[ "$(basename -- "$common")" == ".git" ]] && main=$(realpath "$(dirname -- "$common")" 2>/dev/null)

cfgfile=${DEVKIT_CONFIG:-$HOME/.claude/devkit/repos.json}
[[ -f "$cfgfile" ]] || exit 0
protected=$(jq -r --arg r "$root" --arg m "$main" \
  '((.repos[$r] // (if $m != "" then .repos[$m] else null end) // {}).guards.protectBranches // []) | .[]' "$cfgfile" 2>/dev/null)
[[ -n "$protected" ]] || exit 0

is_protected() { local b=$1 pb; while IFS= read -r pb; do [[ -n "$pb" && "$b" == "$pb" ]] && return 0; done <<<"$protected"; return 1; }
unquote() { local s=${1//\"/}; printf '%s' "${s//\'/}"; }

start_branch=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)
start_prev=$(git -C "$root" rev-parse --abbrev-ref '@{-1}' 2>/dev/null)
# branch at a byte offset: replay every `git checkout|switch` before it
#   -c/-b/-C/-B/--orphan <name> → name ; `-` / @{-1} → previous ; an existing local branch or a protected name
#   → that branch ; `<x> -- <path>` and plain paths restore files and do not switch
branch_at() {   # $1 = byte offset ; prints the branch
  local cur=$start_branch prev=$start_prev sw t take w new
  while IFS= read -r sw; do
    sw=${sw%%#*}                                   # a "# comment" is not an argument
    [[ -z "$sw" ]] && continue
    grep -qE '[[:space:]]--([[:space:]]|$)' <<<"$sw" && continue
    read -r -a ws <<<"$(sed -E 's/^.*[[:space:]](checkout|switch)([[:space:]]|$)//' <<<" $sw")"
    t=""; take=0; new=0; track=0; npos=0; skip=0
    for w in "${ws[@]+"${ws[@]}"}"; do
      if (( skip )); then skip=0; continue; fi
      if (( take )); then t=$w; new=1; break; fi
      if [[ "$w" =~ ^[0-9]*[\<\>] ]]; then [[ "$w" =~ [\<\>]$ ]] && skip=1; continue; fi   # redirection
      case "$w" in
        -c|-b|-C|-B|--create|--force-create|--orphan) take=1 ;;
        -t|--track) track=1 ;;
        -) t=-; npos=1; break ;;
        -*) ;;
        *) npos=$((npos + 1)); [[ -z "$t" ]] && t=$w ;;
      esac
    done
    (( ! new && npos > 1 )) && continue            # "checkout <x> <path>" restores files, no switch
    t=$(unquote "$t")
    (( track && ! new )) && { t=${t#*/}; new=1; }   # --track origin/x creates local branch x
    if [[ "$t" == "-"|| "$t" == "@{-1}" ]]; then w=$cur; cur=$prev; prev=$w; continue; fi
    [[ -n "$t" ]] || continue
    if (( new )) || is_protected "$t" || git -C "$root" show-ref --verify -q "refs/heads/$t"; then
      prev=$cur; cur=$t
    fi
  done < <(grep -oE "$SWITCH_RE" <<<"${cmd:0:$1}")
  printf '%s' "$cur"
}

# judge every git write / push in the command on the branch it will run on
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  o=${m%%:*}; seg=${m#*:}
  b=$(branch_at "$o")
  if grep -qE "$WRITE_RE" <<<"$seg"; then
    is_protected "$b" && deny "this command commits/merges on protected branch '$b' in $root (already on it, or switching to it earlier in the command) — work on a task branch (git switch -c <name>). Merge into '$b' only when the user asked; then prefix the git command with DEVKIT_ALLOW_MASTER=1."
    continue
  fi
  # push: arguments up to the next separator; drop a trailing "# comment" and redirections
  seg=${seg%%#*}
  seg=$(sed -E 's/^.*[[:space:]]push([[:space:]]|$)//' <<<" $seg")
  read -r -a words <<<"$seg"
  remote=""; refs=(); all=0; tags=0; skip=0
  for w in "${words[@]+"${words[@]}"}"; do
    if (( skip )); then skip=0; continue; fi
    if [[ "$w" =~ ^[0-9]*[\<\>] ]]; then [[ "$w" =~ [\<\>]$ ]] && skip=1; continue; fi
    w=$(unquote "$w")
    case "$w" in
      ")") ;;                                      # end of a ( … ) group, not a refspec
      --all|--mirror|--branches) all=1 ;;
      --tags) tags=1 ;;
      -*) ;;
      *) if [[ -z "$remote" ]]; then remote=$w; else refs+=("$w"); fi ;;
    esac
  done
  (( all )) && deny "push --all/--mirror would update protected branches in $root; push the task branch by name. If the user asked for it, prefix the git command with DEVKIT_ALLOW_MASTER=1."
  (( tags && ${#refs[@]} == 0 )) && continue     # "git push --tags" pushes tags only
  if (( ${#refs[@]} == 0 )); then
    is_protected "$b" && deny "push from protected branch '$b' in $root needs the user's explicit go-ahead; then prefix the git command with DEVKIT_ALLOW_MASTER=1."
    continue
  fi
  for r in "${refs[@]}"; do
    dst=${r##*:}; dst=${dst#+}; dst=${dst#refs/heads/}
    [[ "$dst" == "HEAD" || "$dst" == "@" || "$dst" == *'$'* || "$dst" == *'`'* ]] && dst=$b   # $(…) / HEAD → current
    is_protected "$dst" && deny "push to protected branch '$dst' in $root needs the user's explicit go-ahead; then prefix the git command with DEVKIT_ALLOW_MASTER=1."
  done
done < <(grep -boE "$WRITE_RE|${PUSH_RE}[^;&|\`]*" <<<"$cmd")
exit 0
