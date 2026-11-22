#!/bin/bash
# homm-devkit — PostToolUse hook (Edit|Write|MultiEdit): run the checks configured for this repo on the
# edited file. Language-agnostic: every check is a command you configure; the engine only decides
# which checks apply, compares against git HEAD and maps exit codes.
#
# Hook exit codes:
#   0  ok, or nothing applies (no checks configured / file outside a git repo / excluded)
#   2  block — a regression introduced by this edit (stderr is fed back to Claude)
#   1  warning shown to the user — a check was SKIPPED, or a problem already existed at HEAD
#
# Config: ${DEVKIT_CONFIG:-~/.claude/devkit/repos.json}
#   .repos["<repo root realpath>"]   (a git worktree uses its main repo's entry; then .default; else no checks)
#     exclude : [glob]                       repo-wide, relative to repo root
#     checks  : [ {
#       name    : "lint"
#       glob    : ["*.js", "src/**"]         relative to repo root; * and ** both cross "/"
#       exclude : [glob]                     optional
#       run     : "eslint {file}"            bash command, cwd = repo root
#                 placeholders (shell-quoted): {file} {rel} {root} {head} (HEAD copy, empty file if new)
#                 compare findings/status re-run the command on the HEAD copy via {file}, so they need {file}
#       fail_exit : [1]                      exit codes that mean "findings"; 0 = pass;
#                                            any other code = tool problem -> SKIPPED (never a silent pass)
#       compare : "findings" (default) | "status" | "none"
#                 findings: block only output lines that are new vs the HEAD copy (one finding per line;
#                           file path and line/column numbers are ignored when comparing)
#                 status  : block if it fails now but passed at HEAD (or the file is new); else warn
#                 none    : any failure blocks (the tool keeps its own baseline, or reads {head} itself)
#       needs   : ["lint"]                   skip this check if a listed check failed on this file
#       timeout : 60                         seconds (needs `timeout`/`gtimeout`; otherwise unlimited)
#     } ]
#
# Other modes (used by stop-check.sh):
#   check.sh --filter <repo root>   reads repo-relative paths on stdin, prints those some check applies to
#                                   exit 0 ok · 3 config unusable (message on stderr)

user_lc_set=${LC_ALL+1}; user_lc=${LC_ALL-}   # checks run in the user's locale ...
export LC_ALL=C   # ... the engine's own text handling is byte-safe (tool output may not be valid UTF-8)
set -u -f   # -f: globs from config are patterns, never expanded against the cwd
shopt -u patsub_replacement 2>/dev/null || true   # bash >= 5.2: keep "&" literal in ${x//pat/rep}
command -v jq >/dev/null 2>&1 || { echo "devkit: checks SKIPPED — jq is not installed" >&2; exit 1; }
command -v realpath >/dev/null 2>&1 || { echo "devkit: checks SKIPPED — realpath is not installed" >&2; exit 1; }

cfgfile=${DEVKIT_CONFIG:-$HOME/.claude/devkit/repos.json}

load_cfg() {   # $1 = repo root -> sets cfg (json) ; returns 3 when the config is unusable
  local main common
  cfg='{}'
  [[ -f "$cfgfile" ]] || return 0
  jq -e . "$cfgfile" >/dev/null 2>&1 || { cfgerr="cannot parse $cfgfile"; return 3; }
  main=""
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && [[ "$(basename -- "$common")" == ".git" ]] && main=$(realpath "$(dirname -- "$common")" 2>/dev/null)
  cfg=$(jq -c --arg r "$1" --arg m "$main" '.repos[$r] // (if $m != "" then .repos[$m] else null end) // .default // {}' "$cfgfile" 2>&1) \
    || { cfgerr="cannot read the entry for $1 from $cfgfile (\"repos\" must be an object keyed by repo path)"; return 3; }
  # malformed entries must not turn into a silent pass
  cfgerr=$(jq -r '
    if type != "object" then "repo entry must be an object"
    elif (.checks // []) | type != "array" then "\"checks\" must be an array of objects"
    else [ (.checks // [])[] | select(type != "object" or .name == null
             or ((.glob | type) as $t | ($t != "string" and $t != "array"))
             or ((.compare // "findings") | IN("findings", "status", "none") | not)) ] as $bad
      | if ($bad | length) > 0 then "each check needs name, glob (string or array) and compare findings|status|none (got: \($bad[0] | tojson | .[0:100]))" else empty end
    end' <<<"$cfg" 2>&1) || cfgerr="invalid entry in $cfgfile"

  [[ -z "$cfgerr" ]] || return 3
  return 0
}

globs_of() { jq -r '(. // []) | if type == "string" then [.] else . end | .[]' <<<"$1"; }
match_list() {   # $1 = rel path, rest = globs
  local r=$1 pat; shift
  for pat in "$@"; do
    [[ -z "$pat" ]] && continue
    pat=${pat//\*\*/*}
    # shellcheck disable=SC2053
    [[ "$r" == $pat ]] && return 0
  done
  return 1
}

# ---------- --filter mode ----------
if [[ "${1:-}" == "--filter" ]]; then
  root=$(realpath "${2:-.}" 2>/dev/null) || exit 0
  load_cfg "$root" || { echo "devkit: stop-check SKIPPED — $cfgerr" >&2; exit 3; }
  IFS=$'\n'
  rex=($(globs_of "$(jq -c '.exclude // []' <<<"$cfg")"))
  n=$(jq '(.checks // []) | length' <<<"$cfg")
  (( n > 0 )) || exit 0
  inc=(); exc=()
  for ((i = 0; i < n; i++)); do
    inc[$i]=$(globs_of "$(jq -c ".checks[$i].glob" <<<"$cfg")")
    exc[$i]=$(globs_of "$(jq -c ".checks[$i].exclude // []" <<<"$cfg")")
  done
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    (( ${#rex[@]} )) && match_list "$rel" "${rex[@]}" && continue
    for ((i = 0; i < n; i++)); do
      gi=(${inc[$i]}); ge=(${exc[$i]})
      (( ${#gi[@]} )) && match_list "$rel" "${gi[@]}" || continue
      (( ${#ge[@]} )) && match_list "$rel" "${ge[@]}" && continue
      printf '%s\n' "$rel"; break
    done
  done
  exit 0
fi

# ---------- hook mode ----------
input=$(cat)
file=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' <<<"$input" 2>/dev/null)
[[ -n "$file" && -f "$file" ]] || exit 0
file=$(realpath "$file")
root=$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null) || exit 0
root=$(realpath "$root")
rel=${file#"$root"/}
load_cfg "$root" || { echo "devkit: checks SKIPPED — $cfgerr" >&2; exit 1; }

IFS=$'\n' rex=($(globs_of "$(jq -c '.exclude // []' <<<"$cfg")")); unset IFS
(( ${#rex[@]} )) && match_list "$rel" "${rex[@]}" && exit 0

n=$(jq '(.checks // []) | length' <<<"$cfg")
applies=()
for ((i = 0; i < n; i++)); do
  c=$(jq -c ".checks[$i]" <<<"$cfg")
  IFS=$'\n' gi=($(globs_of "$(jq -c '.glob' <<<"$c")")) ge=($(globs_of "$(jq -c '.exclude // []' <<<"$c")")); unset IFS
  (( ${#gi[@]} )) && match_list "$rel" "${gi[@]}" || continue
  (( ${#ge[@]} )) && match_list "$rel" "${ge[@]}" && continue
  applies+=("$i")
done
(( ${#applies[@]} > 0 )) || exit 0

tmp=$(mktemp -d); tmp=$(realpath "$tmp"); trap 'rm -rf "$tmp"' EXIT
# HEAD copy keeps the file's basename (tools often decide the language from the extension)
mkdir -p "$tmp/head"; headcopy="$tmp/head/$(basename -- "$file")"; in_head=0
if git -C "$root" cat-file -e "HEAD:$rel" 2>/dev/null && git -C "$root" show "HEAD:$rel" >"$headcopy" 2>/dev/null; then
  in_head=1
else
  : >"$headcopy"
fi

tmo=$(command -v timeout || command -v gtimeout || true)
block=""; warn=""; failed=" "

q() { printf '%q' "$1"; }
run_check() {   # $1 = check json, $2 = path used for {file}; sets OUT, RC
  local cmd t
  cmd=$(jq -r '.run // empty' <<<"$1")
  cmd=${cmd//\{file\}/$(q "$2")}; cmd=${cmd//\{rel\}/$(q "$rel")}
  cmd=${cmd//\{root\}/$(q "$root")}; cmd=${cmd//\{head\}/$(q "$headcopy")}
  t=$(jq -r '.timeout // empty' <<<"$1")
  OUT=$(
    if [[ -n "$user_lc_set" ]]; then export LC_ALL="$user_lc"; else unset LC_ALL; fi
    cd "$root" || exit 3
    if [[ -n "$t" && -n "$tmo" ]]; then "$tmo" "$t" bash -c "$cmd" 2>&1 </dev/null; else bash -c "$cmd" 2>&1 </dev/null; fi
  ); RC=$?
}
is_fail() { jq -e --argjson rc "$2" '(.fail_exit // [1]) | index($rc) != null' <<<"$1" >/dev/null; }
ere_escape() { printf '%s' "$1" | sed -e 's,[][\.*^$+?(){}|/#],\\&,g'; }
base_re=$(ere_escape "$(basename -- "$file")")
normalize() {   # $1 = the path the tool was run on. One line in -> one line out.
  local s dot_rel="./$rel"   # (a literal "/" inside ${s//pattern/} would end the pattern on bash 3.2)
  while IFS= read -r s || [[ -n "$s" ]]; do
    s=${s//"$1"/}; s=${s//"$dot_rel"/}; s=${s//"$rel"/}   # literal removal (absolute, ./relative, relative)
    printf '%s\n' "$s"
  done | sed -E \
    -e "s#[^[:space:]:\"'(]*${base_re}([^[:alnum:]_]|\$)#\\1#g" \
    -e 's/(line|Line|LINE)[[:space:]]+[0-9]+/\1 N/g' \
    -e 's/^[[:space:]]*[0-9]+(:[0-9]+)?:/N:/' \
    -e 's/\([0-9]+(,[0-9]+)?\)/(N)/g' \
    -e 's/:[0-9]+(:[0-9]+)?/:N/g'
}
# print the raw lines of $1 whose normalized form ($2, same line order) is among the new ones ($3)
pick_new() {
  awk -v nf="$3" 'BEGIN { while ((getline l < nf) > 0) want[l]++ }
       FNR == NR { norm[FNR] = $0; next }
       { if (want[norm[FNR]] > 0) { want[norm[FNR]]--; print } }' "$2" "$1"
}

for i in "${applies[@]}"; do
  c=$(jq -c ".checks[$i]" <<<"$cfg")
  name=$(jq -r '.name' <<<"$c")
  skip_need=""
  while IFS= read -r need; do
    [[ -n "$need" && "$failed" == *" $need "* ]] && skip_need=$need
  done < <(jq -r '(.needs // []) | .[]' <<<"$c")
  [[ -n "$skip_need" ]] && continue
  runcmd=$(jq -r '.run // empty' <<<"$c")
  compare=$(jq -r '.compare // "findings"' <<<"$c")
  [[ -n "$runcmd" ]] || { warn+="devkit: $name SKIPPED — no \"run\" command in config"$'\n'; continue; }
  if [[ "$compare" != "none" && "$runcmd" != *"{file}"* ]]; then
    warn+="devkit: $name SKIPPED — compare \"$compare\" re-runs the command on the HEAD copy through {file}; add {file} to \"run\" or use compare \"none\""$'\n'
    continue
  fi

  run_check "$c" "$file"
  [[ $RC == 0 ]] && continue
  if ! is_fail "$c" "$RC"; then
    warn+="devkit: $name SKIPPED — exit $RC: $(head -c 300 <<<"$OUT" | tr '\n' ' ')"$'\n'
    continue
  fi
  failed+="$name "
  now=$OUT
  printf '%s\n' "$now" >"$tmp/now.raw"
  normalize "$file" <"$tmp/now.raw" >"$tmp/now.norm"
  # findings needs one finding per line; with no comparable output fall back to status
  if [[ "$compare" == "findings" ]] && ! grep -q '[^[:space:]]' "$tmp/now.norm"; then compare=status; fi

  case "$compare" in
    none)
      block+="[$name] $now"$'\n' ;;
    status)
      if [[ $in_head == 1 ]]; then
        run_check "$c" "$headcopy"
        if is_fail "$c" "$RC"; then
          warn+="devkit: $name — already failing at HEAD, not blocked: $(head -1 <<<"$now")"$'\n'
          continue
        fi
      fi
      block+="[$name] ${now:-(failed with exit code, no output)}"$'\n' ;;
    *)
      : >"$tmp/head.norm"
      if [[ $in_head == 1 ]]; then
        run_check "$c" "$headcopy"
        if is_fail "$c" "$RC"; then
          printf '%s\n' "$OUT" | normalize "$headcopy" >"$tmp/head.norm"
        elif [[ $RC != 0 ]]; then
          warn+="devkit: $name — could not run on the HEAD copy (exit $RC), comparing against nothing"$'\n'
        fi
      fi
      comm -23 <(grep '[^[:space:]]' "$tmp/now.norm" | sort) <(grep '[^[:space:]]' "$tmp/head.norm" | sort) >"$tmp/new.norm"
      if [[ -s "$tmp/new.norm" ]]; then
        newcount=$(wc -l <"$tmp/new.norm" | tr -d ' ')
        if [[ $(grep -cxF -f "$tmp/new.norm" "$tmp/now.norm") -gt $newcount ]]; then
          # same finding text exists more than once: can't tell which copy is new, show all copies
          block+="[$name] $newcount new vs HEAD (identical text also exists at HEAD — one of these lines is new):"$'\n'"$(grep -nxF -f "$tmp/new.norm" "$tmp/now.norm" | cut -d: -f1 | while read -r ln; do sed -n "${ln}p" "$tmp/now.raw"; done)"$'\n'
        else
          block+="[$name] new vs HEAD:"$'\n'"$(pick_new "$tmp/now.raw" "$tmp/now.norm" "$tmp/new.norm")"$'\n'
        fi
      fi ;;
  esac
done

if [[ -n "$block" ]]; then
  printf 'devkit check failed for %s:\n%s' "$rel" "$block" >&2
  [[ -n "$warn" ]] && printf '%s' "$warn" >&2
  echo "Fix the regression this edit introduced (problems that already existed at HEAD are not blocked)." >&2
  exit 2
fi
if [[ -n "$warn" ]]; then printf '%s' "$warn" >&2; exit 1; fi
exit 0
