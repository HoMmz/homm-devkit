#!/bin/bash
# homm-devkit test suite — run before every version bump:  tests/run.sh
# Builds throwaway git repos, feeds {"tool_input":{"file_path":...}} to the hooks, asserts exit code + stderr.
# Language-free: the engine is tested with a fake check script. Requires: git, jq, bash.

set -u
DK=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$DK/hooks/check.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; }

# run_hook <file> [env...] -> sets RC, ERR
run_hook() {
  local f=$1; shift
  ERR=$(printf '{"tool_input":{"file_path":"%s"}}' "$f" | env "$@" "$HOOK" 2>&1 >/dev/null); RC=$?
}
expect() {   # expect <name> <rc> [stderr-substring]
  local name=$1 want=$2 sub=${3:-}
  if [[ $RC != "$want" ]]; then bad "$name" "rc=$RC want=$want :: $(head -c 300 <<<"$ERR")"; return; fi
  if [[ -n "$sub" && "$ERR" != *"$sub"* ]]; then bad "$name" "stderr lacks '$sub' :: $(head -c 300 <<<"$ERR")"; return; fi
  ok "$name"
}
newrepo() { local d="$W/$1"; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t; realpath "$d"; }
commit() { git -C "$1" add -A && git -C "$1" commit -qm c; }

CFG="$W/repos.json"
mkcfg() { printf '%s' "$1" > "$CFG"; }

echo "== manifests (plugin.json, agents, skills frontmatter)"
# A broken agent frontmatter loads with ALL fields silently dropped (no model, no tool limits) — must fail here.
if command -v claude >/dev/null 2>&1; then
  vout=$(claude plugin validate "$DK/.claude-plugin/plugin.json" 2>&1); RC=$?; ERR=$vout
  expect "claude plugin validate passes" 0 "Validation passed"
else
  bad "claude plugin validate" "claude CLI not found"
fi

# Fake, language-free checks: a line containing BAD is a finding (exit 1); TOOLERR = tool problem (exit 2).
FAKE="$W/fake-check.sh"
cat > "$FAKE" <<'SH'
#!/bin/bash
grep -q TOOLERR "$1" && { echo "tool crashed"; exit 2; }
out=$(grep -n BAD "$1" | sed -E 's/^([0-9]+):(.*)/line \1: \2/')
[[ -n "$out" ]] && { echo "$out"; exit 1; }
exit 0
SH
chmod +x "$FAKE"
chk() {   # chk <name> <compare> [extra json] -> one check object
  printf '{"name":"%s","glob":["*.txt"],"run":"%s {file}","compare":"%s"%s}' "$1" "$FAKE" "$2" "${3:-}"
}

echo "== engine: which files are checked"
RE=$(newrepo re)
printf 'ok\n' > "$RE/a.txt"; printf 'ok\n' > "$RE/a.md"; commit "$RE"
mkcfg '{"repos":{}}'
printf 'BAD\n' > "$RE/a.txt"
run_hook "$RE/a.txt" DEVKIT_CONFIG="$CFG"; expect "no checks configured -> nothing runs" 0
mkcfg "{\"repos\":{\"$RE\":{\"checks\":[$(chk fake findings)]}}}"
printf 'BAD\n' > "$RE/a.md"
run_hook "$RE/a.md" DEVKIT_CONFIG="$CFG"; expect "file not matching any glob -> not checked" 0
run_hook "$RE/a.txt" DEVKIT_CONFIG="$CFG"; expect "matching file with new finding -> block" 2 "[fake]"
mkcfg "{\"default\":{\"checks\":[$(chk fake findings)]},\"repos\":{}}"
run_hook "$RE/a.txt" DEVKIT_CONFIG="$CFG"; expect ".default applies to repos without an entry" 2 "[fake]"
mkcfg "{\"repos\":{\"$RE\":{\"exclude\":[\"skip/**\"],\"checks\":[$(chk fake findings ',"exclude":["gen/**"]')]}}}"
mkdir -p "$RE/skip" "$RE/gen"; printf 'BAD\n' > "$RE/skip/x.txt"; printf 'BAD\n' > "$RE/gen/y.txt"
run_hook "$RE/skip/x.txt" DEVKIT_CONFIG="$CFG"; expect "repo-wide exclude -> not checked" 0
run_hook "$RE/gen/y.txt" DEVKIT_CONFIG="$CFG"; expect "per-check exclude -> not checked" 0
printf 'BAD\n' > "$W/outside.txt"
run_hook "$W/outside.txt" DEVKIT_CONFIG="$CFG"; expect "file outside any git repo -> not checked" 0

echo "== engine: compare modes (regression vs git HEAD)"
RF=$(newrepo rf)
printf 'BAD old\nok\n' > "$RF/f.txt"; printf 'ok\n' > "$RF/g.txt"; commit "$RF"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[$(chk fake findings)]}}}"
printf 'new line on top\nBAD old\nok\n' > "$RF/f.txt"
run_hook "$RF/f.txt" DEVKIT_CONFIG="$CFG"; expect "findings: old finding moved to another line -> not blocked" 0
printf 'BAD old\nBAD old\nok\n' > "$RF/f.txt"
run_hook "$RF/f.txt" DEVKIT_CONFIG="$CFG"; expect "findings: one more copy of an existing finding -> block" 2 "[fake]"
printf 'BAD old\nBAD new\n' > "$RF/f.txt"
run_hook "$RF/f.txt" DEVKIT_CONFIG="$CFG"; expect "findings: new finding -> block" 2 "BAD new"
printf 'BAD\n' > "$RF/new.txt"
run_hook "$RF/new.txt" DEVKIT_CONFIG="$CFG"; expect "findings: new file with finding -> block" 2 "[fake]"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[$(chk fake status)]}}}"
printf 'BAD old\nBAD new\n' > "$RF/f.txt"
run_hook "$RF/f.txt" DEVKIT_CONFIG="$CFG"; expect "status: already failing at HEAD -> warn, not block" 1 "already failing at HEAD"
printf 'BAD\n' > "$RF/g.txt"
run_hook "$RF/g.txt" DEVKIT_CONFIG="$CFG"; expect "status: passed at HEAD, fails now -> block" 2 "[fake]"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[$(chk fake none)]}}}"
printf 'BAD old\nok\n' > "$RF/f.txt"
run_hook "$RF/f.txt" DEVKIT_CONFIG="$CFG"; expect "none: any failure blocks (tool keeps its own baseline)" 2 "[fake]"
git -C "$RF" checkout -q -- .

echo "== engine: tool problems are SKIPPED, never a silent pass"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[$(chk fake findings)]}}}"
printf 'TOOLERR\n' > "$RF/g.txt"
run_hook "$RF/g.txt" DEVKIT_CONFIG="$CFG"; expect "exit code not in fail_exit -> SKIPPED" 1 "fake SKIPPED"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[$(chk fake findings ',"fail_exit":[1,2]')]}}}"
run_hook "$RF/g.txt" DEVKIT_CONFIG="$CFG"; expect "fail_exit [1,2] -> exit 2 counts as finding" 2 "tool crashed"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[{\"name\":\"gone\",\"glob\":\"*.txt\",\"run\":\"/nonexistent/tool {file}\"}]}}}"
run_hook "$RF/g.txt" DEVKIT_CONFIG="$CFG"; expect "tool not installed (127) -> SKIPPED" 1 "gone SKIPPED"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[{\"name\":\"norun\",\"glob\":\"*.txt\"}]}}}"
run_hook "$RF/g.txt" DEVKIT_CONFIG="$CFG"; expect "check without run -> SKIPPED" 1 "norun SKIPPED"
printf 'not json' > "$CFG"
run_hook "$RF/g.txt" DEVKIT_CONFIG="$CFG"; expect "broken config -> SKIPPED" 1 "cannot parse"
NOJQ="$W/nojq-bin"; mkdir -p "$NOJQ"; ln -s "$(command -v dirname)" "$NOJQ/dirname"
run_hook "$RF/g.txt" PATH="$NOJQ" DEVKIT_CONFIG="$CFG"; expect "jq missing -> SKIPPED" 1 "jq is not installed"
git -C "$RF" checkout -q -- .

echo "== engine: needs, placeholders, file names with spaces"
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[$(chk first findings),{\"name\":\"second\",\"glob\":\"*.txt\",\"needs\":[\"first\"],\"run\":\"echo second-ran; exit 1\",\"compare\":\"none\"}]}}}"
printf 'BAD\n' > "$RF/g.txt"
run_hook "$RF/g.txt" DEVKIT_CONFIG="$CFG"
if [[ $RC == 2 && "$ERR" != *second-ran* ]]; then ok "needs: dependent check skipped when its dependency failed"; else bad "needs" "rc=$RC $ERR"; fi
git -C "$RF" checkout -q -- .
mkcfg "{\"repos\":{\"$RF\":{\"checks\":[{\"name\":\"ph\",\"glob\":\"*.txt\",\"run\":\"echo rel={rel}; test -f {head} && test -d {root} && test -f {file}; [ \$? = 0 ] && exit 1 || exit 2\",\"compare\":\"none\"}]}}}"
mkdir -p "$RF/sp ace"; printf 'x\n' > "$RF/sp ace/h i.txt"
run_hook "$RF/sp ace/h i.txt" DEVKIT_CONFIG="$CFG"; expect "placeholders resolve and survive spaces" 2 "rel=sp ace/h i.txt"

echo "== engine: review fixes (findings edge cases, config errors, worktrees, quoting)"
RX=$(newrepo rx)
# 1. findings mode with a failing check that prints nothing must not pass silently
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"quiet\",\"glob\":\"*.txt\",\"run\":\"! grep -q BAD {file}\"}]}}}"
printf 'ok\n' > "$RX/q.txt"; commit "$RX"
printf 'BAD\n' > "$RX/q.txt"
run_hook "$RX/q.txt" DEVKIT_CONFIG="$CFG"; expect "findings + no output, passed at HEAD -> block" 2 "[quiet]"
printf 'BAD\n' > "$RX/q2.txt"
run_hook "$RX/q2.txt" DEVKIT_CONFIG="$CFG"; expect "findings + no output, new file -> block" 2 "[quiet]"
rm -f "$RX/q2.txt"; git -C "$RX" checkout -q -- .
# 2. regex characters in the path
mkdir -p "$RX/app/(shop)/+x{id}"; P="$RX/app/(shop)/+x{id}/p.txt"
printf 'BAD old\n' > "$P"; commit "$RX"
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"abs\",\"glob\":\"*.txt\",\"run\":\"grep -n BAD {file} | sed 's#^#'{file}':#'; ! grep -q BAD {file}\"}]}}}"
printf 'top\nBAD old\n' > "$P"
run_hook "$P" DEVKIT_CONFIG="$CFG"; expect "path with ( ) + { }: moved finding -> not blocked" 0
printf 'BAD old\nBAD new\n' > "$P"
run_hook "$P" DEVKIT_CONFIG="$CFG"; expect "path with ( ) + { }: new finding -> block" 2 "BAD new"
# 9. the block message lists only the new findings
if [[ "$ERR" == *"BAD new"* && "$ERR" != *"BAD old"* ]]; then ok "block message shows only new findings"; else bad "only new findings" "$ERR"; fi
git -C "$RX" checkout -q -- .
# 6. tool printing a relative path / eslint-style "line:col" prefix
ESL="$W/eslint-like.sh"
cat > "$ESL" <<'SH'
#!/bin/bash
# prints like eslint's stylish formatter: relative path line, then "  L:C  error  msg", then a blank line
out=$(grep -n BAD "$1" | sed -E 's/^([0-9]+):(.*)/  \1:5  error  \2/')
[[ -z "$out" ]] && exit 0
printf './%s\n%s\n\n' "$(basename "$1")" "$out"; exit 1
SH
chmod +x "$ESL"
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"rel\",\"glob\":\"*.txt\",\"run\":\"$ESL {file}\"}]}}}"
printf 'BAD old\n' > "$RX/r.txt"; commit "$RX"
printf 'x\ny\nBAD old\n' > "$RX/r.txt"
run_hook "$RX/r.txt" DEVKIT_CONFIG="$CFG"; expect "relative path + 'L:C' prefix: moved finding -> not blocked" 0
git -C "$RX" checkout -q -- .
# globs must not expand against the hook's cwd (regression 2026-11-22: "*.php" became the cwd's files)
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[$(chk fake findings)]}}}"
CWDX="$W/cwd-with-matches"; mkdir -p "$CWDX"; printf 'x' > "$CWDX/zz.txt"
printf 'BAD cwd\n' > "$RX/c.txt"
ERR=$(cd "$CWDX" && printf '{"tool_input":{"file_path":"%s"}}' "$RX/c.txt" | env DEVKIT_CONFIG="$CFG" "$HOOK" 2>&1 >/dev/null); RC=$?
expect "cwd containing files that match the glob -> still checked" 2 "BAD cwd"
ERR=$(cd "$CWDX" && printf 'c.txt\n' | env DEVKIT_CONFIG="$CFG" "$HOOK" --filter "$RX" 2>&1); RC=$?
[[ "$ERR" == "c.txt" ]] && ok "--filter from such a cwd -> still lists the file" || bad "--filter cwd glob" "$ERR"
rm -f "$RX/c.txt"
# re-review: ./rel paths, bare "N:" line prefixes, non-UTF-8 output, ambiguous duplicates, locale of the tool
mkdir -p "$RX/src"; printf 'BAD old\n' > "$RX/src/g.txt"; commit "$RX"
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"dot\",\"glob\":\"*.txt\",\"run\":\"f={file}; r=\$(realpath --relative-to=. \\\"\$f\\\" 2>/dev/null || python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1]))' \\\"\$f\\\"); grep -n BAD \\\"\$f\\\" | sed \\\"s#^#./\$r:#\\\"; ! grep -q BAD \\\"\$f\\\"\"}]}}}"
printf 'top\nBAD old\n' > "$RX/src/g.txt"
run_hook "$RX/src/g.txt" DEVKIT_CONFIG="$CFG"; expect "tool printing ./src/g.txt:N: (HEAD copy prints another path) -> moved finding not blocked" 0
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"gn\",\"glob\":\"*.txt\",\"run\":\"grep -n BAD {file}; ! grep -q BAD {file}\"}]}}}"
run_hook "$RX/src/g.txt" DEVKIT_CONFIG="$CFG"; expect "grep -n style '12:text' -> moved finding not blocked" 0
git -C "$RX" checkout -q -- .
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"bin\",\"glob\":\"*.txt\",\"run\":\"printf 'k \\\\377\\\\376 old\\\\n'; grep BAD {file}; exit 1\"}]}}}"
printf 'ok\n' > "$RX/h.txt"; commit "$RX"; printf 'BAD after invalid bytes\n' > "$RX/h.txt"
run_hook "$RX/h.txt" LANG=en_US.UTF-8 DEVKIT_CONFIG="$CFG"; expect "non-UTF-8 tool output does not hide a later new finding" 2 "BAD after invalid bytes"
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"loc\",\"glob\":\"*.txt\",\"run\":\"echo LC=\${LC_ALL:-unset}; exit 1\",\"compare\":\"none\"}]}}}"
run_hook "$RX/h.txt" LC_ALL=en_US.UTF-8 DEVKIT_CONFIG="$CFG"; expect "checks run in the user's locale, not C" 2 "LC=en_US.UTF-8"
git -C "$RX" checkout -q -- .
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[$(chk fake findings)]}}}"
printf 'BAD t\nok\n' > "$RX/d.txt"; commit "$RX"; printf 'BAD t\nok\nBAD t\n' > "$RX/d.txt"
run_hook "$RX/d.txt" DEVKIT_CONFIG="$CFG"; expect "duplicate finding text -> says which copies, not just the old line" 2 "one of these lines is new"
git -C "$RX" checkout -q -- .
for bad in '{"repos":[]}' "{\"repos\":{\"$RX\":[1]}}" "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"x\",\"glob\":\"*.txt\",\"run\":\"true {file}\",\"compare\":\"finding\"}]}}}" "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"x\",\"glob\":5,\"run\":\"true {file}\"}]}}}"; do
  printf '%s' "$bad" > "$CFG"; run_hook "$RX/d.txt" DEVKIT_CONFIG="$CFG"
  [[ $RC == 1 && "$ERR" == *SKIPPED* ]] && ok "malformed config $(head -c 40 <<<"$bad")… -> SKIPPED" || bad "malformed config $bad" "rc=$RC $ERR"
done
# 3. findings/status without {file} cannot compare with HEAD
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[{\"name\":\"nofile\",\"glob\":\"*.txt\",\"run\":\"grep BAD {rel}\"}]}}}"
run_hook "$RX/r.txt" DEVKIT_CONFIG="$CFG"; expect "compare findings without {file} -> SKIPPED" 1 "add {file}"
# 5. malformed config is SKIPPED, in the hook and at Stop
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[\"lint\",\"dupkeys\"]}}}"
run_hook "$RX/r.txt" DEVKIT_CONFIG="$CFG"; expect "v1-style checks list -> SKIPPED" 1 "each check needs"
printf 'BAD\n' > "$RX/r.txt"
ERR=$(jq -n --arg c "$RX" '{cwd:$c}' | env DEVKIT_CONFIG="$CFG" "$DK/hooks/stop-check.sh" 2>&1 >/dev/null); RC=$?
expect "stop-check with malformed config -> SKIPPED" 1 "stop-check SKIPPED"
printf 'not json' > "$CFG"
ERR=$(jq -n --arg c "$RX" '{cwd:$c}' | env DEVKIT_CONFIG="$CFG" "$DK/hooks/stop-check.sh" 2>&1 >/dev/null); RC=$?
expect "stop-check with unparsable config -> SKIPPED" 1 "cannot parse"
git -C "$RX" checkout -q -- .
# 4. a git worktree uses its main repo's entry
mkcfg "{\"repos\":{\"$RX\":{\"checks\":[$(chk fake findings)]}}}"
git -C "$RX" worktree add -q "$W/rx-wt" -b wt 2>/dev/null
printf 'BAD wt\n' > "$W/rx-wt/w.txt"
run_hook "$W/rx-wt/w.txt" DEVKIT_CONFIG="$CFG"; expect "worktree -> main repo's checks run" 2 "BAD wt"
# 8. shell metacharacters in file names stay data
mkdir -p "$RX/R&D"; printf 'BAD\n' > "$RX/R&D/a;b \$(touch PWNED).txt"
run_hook "$RX/R&D/a;b \$(touch PWNED).txt" DEVKIT_CONFIG="$CFG"
if [[ $RC == 2 && ! -e "$RX/PWNED" && ! -e "$RX/D" ]]; then ok "file name with & ; \$( ) is not executed"; else bad "metachar file name" "rc=$RC $(ls "$RX")"; fi
# 7. hard cap before filtering at Stop
for i in 1 2 3 4 5; do printf 'x\n' > "$RX/u$i.bin"; done
ERR=$(jq -n --arg c "$RX" '{cwd:$c}' | env DEVKIT_CONFIG="$CFG" DEVKIT_STOP_MAX_CHANGED=3 "$DK/hooks/stop-check.sh" 2>&1 >/dev/null); RC=$?
expect "too many changed files overall -> SKIPPED before filtering" 1 "more than 3"
# non-ASCII file names reach the checks at Stop
rm -f "$RX"/u*.bin; rm -rf "$RX/R&D"; printf 'BAD\n' > "$RX/ไทย.txt"
ERR=$(jq -n --arg c "$RX" '{cwd:$c}' | env DEVKIT_CONFIG="$CFG" "$DK/hooks/stop-check.sh" 2>&1 >/dev/null); RC=$?
expect "stop-check sees non-ASCII file names" 2 "[fake]"

echo "== stop-check (Stop / SubagentStop)"
STOP="$DK/hooks/stop-check.sh"
run_stop() { ERR=$(jq -n --arg c "$1" --argjson a "${2:-false}" '{cwd:$c, stop_hook_active:$a}' | env DEVKIT_CONFIG="$CFG" "$STOP" 2>&1 >/dev/null); RC=$?; }
RS=$(newrepo rs)
mkcfg "{\"repos\":{\"$RS\":{\"checks\":[$(chk fake findings)]}}}"
printf 'ok\n' > "$RS/a.txt"; commit "$RS"
run_stop "$RS"; expect "clean tree -> 0" 0
printf 'BAD\n' > "$RS/a.txt"          # written by the shell, not Edit/Write
run_stop "$RS"; expect "regression made outside Edit/Write -> block" 2 "not done yet"
run_stop "$RS" true; expect "still failing after retry -> warn, no loop" 1 "not blocking again"
git -C "$RS" checkout -q -- a.txt
printf 'BAD\n' > "$RS/new_untracked.txt"
run_stop "$RS"; expect "untracked new file -> block" 2 "[fake]"
rm -f "$RS/new_untracked.txt"
for i in 1 2 3 4 5; do printf 'BAD\n' > "$RS/img$i.png"; done
run_stop "$RS"; expect "changed files no check applies to -> ignored" 0
run_stop "$W"; expect "not a git repo -> 0" 0
for i in 1 2 3; do printf 'ok %s\n' "$i" > "$RS/m$i.txt"; done
ERR=$(jq -n --arg c "$RS" '{cwd:$c}' | env DEVKIT_CONFIG="$CFG" DEVKIT_STOP_MAX_FILES=2 "$STOP" 2>&1 >/dev/null); RC=$?
expect "too many changed files with checks -> SKIPPED warn" 1 "stop-check SKIPPED"

echo "== guard (PreToolUse)"
GUARD="$DK/hooks/guard.sh"
run_guard() {   # run_guard <tool> <json tool_input> [cwd]
  ERR=$(jq -n --arg t "$1" --argjson ti "$2" --arg c "${3:-$W}" '{tool_name:$t, tool_input:$ti, cwd:$c}' | env DEVKIT_CONFIG="$CFG" "$GUARD" 2>&1 >/dev/null); RC=$?
}
# a guard script error falls through to "allow", so allow cases also assert a clean stderr
gexpect() {   # gexpect <name> <rc> [stderr-substring]
  if [[ $RC == 0 && -n "$ERR" ]]; then bad "$1" "allowed, but the guard printed: $(head -c 200 <<<"$ERR")"; return; fi
  expect "$@"
}
E=".env"   # built at runtime so this file itself never names a secret file literally in a command
run_guard Read "{\"file_path\":\"/x/app$E\"}"; gexpect "Read app$E is not .env -> allow" 0
run_guard Read "{\"file_path\":\"/x/$E\"}"; gexpect "Read $E -> deny" 2 "not allowed"
run_guard Read "{\"file_path\":\"/x/$E.production\"}"; gexpect "Read $E.production -> deny" 2 "not allowed"
run_guard Read "{\"file_path\":\"/x/application/$E.example\"}"; gexpect "Read $E.example -> allow" 0
run_guard Grep "{\"pattern\":\"DB_\",\"path\":\"/x/$E\"}"; gexpect "Grep inside $E -> deny" 2 "not allowed"
run_guard Bash "{\"command\":\"cat $E | head\"}"; gexpect "Bash cat $E -> deny" 2 "references"
run_guard Bash "{\"command\":\"cp $E.example $E.local.bak\"}"; gexpect "Bash naming $E.local -> deny" 2 "references"
run_guard Bash "{\"command\":\"diff $E.example $E.dist\"}"; gexpect "Bash with only template names -> allow" 0
run_guard Bash "{\"command\":\"grep -rn getenv app/\"}"; gexpect "Bash unrelated -> allow" 0

RG=$(newrepo rg)
printf '<?php\n' > "$RG/a.php"; commit "$RG"
git -C "$RG" branch -M master
mkcfg "{\"repos\":{\"$RG\":{\"guards\":{\"protectBranches\":[\"master\"]}}}}"
run_guard Bash '{"command":"git commit -m x"}' "$RG"; gexpect "commit on master -> deny" 2 "protected branch"
run_guard Bash '{"command":"git switch -c fix/x && git commit -m x"}' "$RG"; gexpect "switch -c then commit -> allow" 0
run_guard Bash '{"command":"git push origin master"}' "$RG"; gexpect "push origin master -> deny" 2 "push to protected"
run_guard Bash '{"command":"DEVKIT_ALLOW_MASTER=1 git push origin master"}' "$RG"; gexpect "explicit DEVKIT_ALLOW_MASTER=1 -> allow" 0
run_guard Bash "{\"command\":\"cd $RG && git merge --no-ff fix/x\"}" "$W"; gexpect "cd <repo> && merge on master -> deny" 2 "protected branch"
run_guard Bash "{\"command\":\"git -C $RG commit -m x\"}" "$W"; gexpect "git -C <repo> commit on master -> deny" 2 "protected branch"
# cwd is the protected repo, but the command cd's into another (unprotected) repo first
RO=$(newrepo ro); printf '<?php\n' > "$RO/b.php"; commit "$RO"; git -C "$RO" branch -M master
run_guard Bash "{\"command\":\"set -o pipefail; cd $RO && git add -A && git commit -m x\"}" "$RG"; gexpect "set -o pipefail; cd <other repo> && commit -> allow (regression 2026-11-22)" 0
run_guard Bash "{\"command\":\"echo hi && cd $RG && git push origin master\"}" "$RO"; gexpect "... && cd <protected> && push -> deny" 2 "push to protected"
run_guard Bash "{\"command\":\"cd $RG && echo x; cd $RO && git commit -m x\"}" "$W"; gexpect "last cd before git wins -> allow" 0
git -C "$RG" switch -q -c fix/y
run_guard Bash '{"command":"git commit -m x"}' "$RG"; gexpect "commit on task branch -> allow" 0
run_guard Bash '{"command":"git push -u origin fix/y"}' "$RG"; gexpect "push task branch -> allow" 0
mkcfg '{"repos":{}}'
git -C "$RG" switch -q master
run_guard Bash '{"command":"git commit -m x"}' "$RG"; gexpect "repo without guards config -> allow" 0

echo "== guard: evasions found in review 2026-11-23 (fixed -> deny)"
mkcfg "{\"repos\":{\"$RG\":{\"guards\":{\"protectBranches\":[\"master\"]}}}}"
git -C "$RG" switch -q fix/y     # on a task branch
run_guard Bash '{"command":"git checkout master && git merge fix/y"}' "$RG";   gexpect "checkout master && merge (same command) -> deny" 2 "protected branch"
run_guard Bash '{"command":"git switch master && git commit -m x"}' "$RG";      gexpect "switch master && commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git switch master && git switch -c fix/z && git commit -m x"}' "$RG"; gexpect "last switch wins (-c task branch) -> allow" 0
run_guard Bash '{"command":"git push origin fix/y:refs/heads/master"}' "$RG";  gexpect "push <x>:refs/heads/master -> deny" 2 "push to protected"
run_guard Bash '{"command":"git push origin +master"}' "$RG";                  gexpect "push +master -> deny" 2 "push to protected"
run_guard Bash "{\"command\":\"git push origin 'master'\"}" "$RG";            gexpect "push 'master' (quoted) -> deny" 2 "push to protected"
run_guard Bash '{"command":"git push --all origin"}' "$RG";                    gexpect "push --all -> deny" 2 "push --all"
run_guard Bash '{"command":"git push origin fix/y # not master"}' "$RG";       gexpect "push task branch with # comment -> allow" 0
run_guard Bash '{"command":"git push -u origin fix/push-ui"}' "$RG";           gexpect "branch name containing push -> allow" 0
git -C "$RG" switch -q master    # on the protected branch
run_guard Bash '{"command":"git -c user.name=x commit -m x"}' "$RG";           gexpect "git -c k=v commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git --no-pager commit -m x"}' "$RG";               gexpect "git --no-pager commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"/usr/bin/git commit -m x"}' "$RG";                 gexpect "/usr/bin/git commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git push origin HEAD"}' "$RG";                     gexpect "push origin HEAD from master -> deny" 2 "push to protected"
run_guard Bash '{"command":"git commit -m \"DEVKIT_ALLOW_MASTER=1\""}' "$RG";  gexpect "approval text inside a commit message -> deny" 2 "protected branch"
run_guard Bash '{"command":"echo git switch -c no ; git commit -m x"}' "$RG";  gexpect "switch -c only inside an echo -> deny" 2 "protected branch"
run_guard Bash '{"command":"git commit -m x; git switch -c later"}' "$RG";     gexpect "switch -c AFTER the commit -> deny" 2 "protected branch"
run_guard Bash "{\"command\":\"pushd $RG && git commit -m x\"}" "$W";         gexpect "pushd <repo> && commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"cd sub && DEVKIT_ALLOW_MASTER=1 git push origin master"}' "$RG"; gexpect "approval prefix after && -> allow" 0
git -C "$RG" worktree add -q --detach "$W/rg-wt" master 2>/dev/null
run_guard Bash '{"command":"git push origin master"}' "$W/rg-wt";             gexpect "worktree of a protected repo uses its entry -> deny" 2 "push to protected"
GE=".EN""V"; Ge=".En""v"
run_guard Read "{\"file_path\":\"/x/$GE\"}";                                  gexpect "Read $GE (case-insensitive FS) -> deny" 2 "not allowed"
run_guard Read "{\"file_path\":\"/x/$Ge.Local\"}";                            gexpect "Read $Ge.Local -> deny" 2 "not allowed"
run_guard Read "{\"file_path\":\"/x/$GE.EXAMPLE\"}";                          gexpect "Read $GE.EXAMPLE (template) -> allow" 0
run_guard Grep "{\"pattern\":\"X\",\"glob\":\"$E*\"}";                       gexpect "Grep glob $E* -> deny" 2 "glob"
run_guard Grep "{\"pattern\":\"X\",\"path\":\"/x\",\"glob\":\"**/$E\"}";     gexpect "Grep glob **/$E -> deny" 2 "glob"
run_guard Grep "{\"pattern\":\"X\",\"glob\":\"$E.example\"}";                gexpect "Grep glob $E.example -> allow" 0
run_guard Grep "{\"pattern\":\"X\",\"glob\":\"*.php\"}";                     gexpect "Grep glob *.php -> allow" 0

echo "== guard: second review round 2026-11-23"
git -C "$RG" switch -q master
run_guard Bash '{"command":"git checkout -- a.php && git commit -m x"}' "$RG";  gexpect "on master: checkout -- <path> (no switch) && commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git checkout . && git commit -m x"}' "$RG";         gexpect "on master: checkout . (no switch) && commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git push"}' "$RG";                                  gexpect "on master: bare git push -> deny" 2 "push from protected"
run_guard Bash '{"command":"git push origin 2>&1 | tail -3"}' "$RG";            gexpect "on master: push origin 2>&1 (redirect is not a refspec) -> deny" 2 "push from protected"
run_guard Bash '{"command":"git push origin $(git branch --show-current)"}' "$RG"; gexpect "on master: push origin \$(current) -> deny" 2 "push to protected"
run_guard Bash '{"command":"if ! git diff --cached --quiet; then git commit -m x; fi"}' "$RG"; gexpect "if ...; then git commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git diff --quiet || { git commit -m x; }"}' "$RG";  gexpect "|| { git commit; } -> deny" 2 "protected branch"
run_guard Bash '{"command":"for r in a; do git push origin master; done"}' "$RG"; gexpect "for ...; do git push -> deny" 2 "push to protected"
run_guard Bash '{"command":"timeout 60 git push origin master"}' "$RG";         gexpect "timeout 60 git push -> deny" 2 "push to protected"
run_guard Bash '{"command":"\\git commit -m x"}' "$RG";                         gexpect "\\git commit -> deny" 2 "protected branch"
run_guard Bash "{\"command\":\"git --git-dir=$RG/.git --work-tree=$RG commit -m x\"}" "$W"; gexpect "--git-dir/--work-tree commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git push origin @"}' "$RG";                         gexpect "push origin @ from master -> deny" 2 "push to protected"
run_guard Bash '{"command":"git push --mirror"}' "$RG";                         gexpect "push --mirror -> deny" 2 "push --all"
TH=$'\xe0\xb8\xa3\xe0\xb8\xb8\xe0\xb9\x88\xe0\xb8\x99'   # Thai word, multi-byte
run_guard Bash "{\"command\":\"echo $TH $TH $TH && git push origin master\"}" "$RG"; gexpect "multi-byte text before push (byte offsets) -> deny" 2 "push to protected"
run_guard Bash $'{"command":"echo ok\\n  DEVKIT_ALLOW_MASTER=1 git push origin master"}' "$RG"; gexpect "indented approval on a later line -> allow" 0
run_guard Bash '{"command":"DEVKIT_ALLOW_MASTER=1 GIT_MERGE_AUTOEDIT=no git merge fix/y"}' "$RG"; gexpect "approval with another VAR=x -> allow" 0
git -C "$RG" switch -q fix/y
run_guard Bash '{"command":"git add -A && git commit -m x && git checkout master && git merge fix/y && git push"}' "$RG"; gexpect "commit on task, then checkout master && merge (every write judged) -> deny" 2 "protected branch"
run_guard Bash "{\"command\":\"git checkout \\\"master\\\" && git merge fix/y\"}" "$RG"; gexpect "checkout \"master\" (quoted) && merge -> deny" 2 "protected branch"
run_guard Bash '{"command":"git checkout master && git pull && git checkout - && git rebase master"}' "$RG"; gexpect "checkout - back to task before rebase -> allow" 0
run_guard Bash '{"command":"git push"}' "$RG";                                  gexpect "on task: bare git push -> allow" 0
run_guard Bash '{"command":"git checkout --track origin/master && git commit -m x"}' "$RG"; gexpect "checkout --track origin/master && commit -> deny" 2 "protected branch"
git -C "$RG" switch -q master; git -C "$RG" switch -q fix/y   # previous branch = master
run_guard Bash '{"command":"git switch - && git commit -m x"}' "$RG";          gexpect "switch - to previous (master) && commit -> deny" 2 "protected branch"

echo "== guard: third review round 2026-11-23"
# still on fix/y
run_guard Bash "{\"command\":\"(cd $RG && git push origin master)\"}" "$W";    gexpect "(cd repo && git push origin master) -> deny" 2 "push to protected"
run_guard Bash '{"command":"(git checkout master) && git merge fix/y"}' "$RG";  gexpect "(git checkout master) && merge -> deny" 2 "protected branch"
run_guard Bash $'{"command":"git checkout master   # switch to master\\ngit merge fix/y"}' "$RG"; gexpect "checkout with # comment, merge on next line -> deny" 2 "protected branch"
run_guard Bash $'{"command":"echo a\\ngit checkout master\\ngit merge fix/y"}' "$RG"; gexpect "multi-line: checkout on line 2, merge on line 3 -> deny" 2 "protected branch"
run_guard Bash '{"command":"git checkout master a.php && git commit -m revert"}' "$RG"; gexpect "checkout master <file> restores, does not switch -> allow" 0
run_guard Bash '{"command":"git checkout master 2>&1 && git merge fix/y"}' "$RG"; gexpect "checkout master 2>&1 (redirect is not a path) && merge -> deny" 2 "protected branch"
git -C "$RG" switch -q master
run_guard Bash "{\"command\":\"(cd $RG && git push)\"}" "$W";                   gexpect "on master: (cd repo && git push) -> deny" 2 "push from protected"
run_guard Bash '{"command":"git push;git status"}' "$RG";                       gexpect "on master: git push;git status -> deny" 2 "push from protected"
run_guard Bash '{"command":"git checkout fix/y a.php && git commit -m x"}' "$RG"; gexpect "on master: checkout <branch> <file> (no switch) && commit -> deny" 2 "protected branch"
run_guard Bash '{"command":"git push origin --tags"}' "$RG";                    gexpect "on master: push --tags only -> allow" 0
run_guard Bash '{"command":"GIT_SSH_COMMAND=\"ssh -i k\" git push origin master"}' "$RG"; gexpect "quoted env value with spaces before git -> deny" 2 "push to protected"
run_guard Bash '{"command":"git switch -c feat2 && git push"}' "$RG";          gexpect "on master: switch -c && bare push (replay on push) -> allow" 0
git -C "$RG" switch -q fix/y
run_guard Bash '{"command":"git push origin \"$(git branch --show-current)\":master"}' "$RG"; gexpect "push \$(…):master -> deny" 2 "push to protected"
git -C "$RG" switch -q master
run_guard Bash $'{"command":"echo a\\ngit switch -c fix/n\\ngit commit -m x"}' "$RG"; gexpect "multi-line: switch -c on line 2, commit on line 3 -> allow" 0
run_guard Bash "{\"command\":\"echo $TH $TH $TH $TH; git commit -m x; git switch -c later\"}" "$RG"; gexpect "multi-byte text, commit before switch -c (proves byte offsets) -> deny" 2 "protected branch"

echo "== guard: everyday commands stay allowed (no false positives)"
git -C "$RG" switch -q master
run_guard Bash '{"command":"git checkout -b fix/q origin/master"}' "$RG";      gexpect "on master: checkout -b x origin/master -> allow" 0
run_guard Bash '{"command":"git switch -c feat && git push -u origin feat"}' "$RG"; gexpect "on master: switch -c && push new branch -> allow" 0
git -C "$RG" switch -q fix/y
run_guard Bash '{"command":"git checkout master -- a.php && git commit -m x"}' "$RG"; gexpect "checkout master -- <file> restores, does not switch -> allow" 0
run_guard Bash "{\"command\":\"git commit -m 'push to master after review'\"}" "$RG"; gexpect "commit message mentioning push/master -> allow" 0
run_guard Bash '{"command":"git rebase master && git push origin fix/y"}' "$RG"; gexpect "rebase onto master + push task branch -> allow" 0
git -C "$RG" switch -q master

echo "== guard: known limits (pinned — the guard is a speed bump, not a security boundary)"
# These pass the guard on purpose. If one starts failing, update the README Limits section too.
run_guard Bash "{\"command\":\"cat .en?\"}";                                  gexpect "LIMIT shell glob .en? is not expanded" 0
run_guard Bash '{"command":"grep -r DB_PASS ."}';                              gexpect "LIMIT recursive grep of a folder" 0
run_guard Grep '{"pattern":"DB_PASS","path":"/x"}';                            gexpect "LIMIT Grep over a whole folder" 0
run_guard Bash "{\"command\":\"python3 -c 'open(\\\".e\\\"+\\\"nv\\\")'\"}"; gexpect "LIMIT interpreter building the name" 0
run_guard Bash "{\"command\":\"D=$RG; cd \$D && git commit -m x\"}" "$RO";     gexpect "LIMIT \$VAR repo path (resolved as cwd, an unprotected repo)" 0
run_guard Read '{"file_path":"/x/id_rsa"}';                                    gexpect "LIMIT other secret files (id_rsa, *.pem) are not watched" 0
NOJQG="$W/nojq-guard"; mkdir -p "$NOJQG"; ln -sf "$(command -v cat)" "$NOJQG/cat"
ERR=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/x/%s"}}' "$E" | env PATH="$NOJQG" /bin/bash "$GUARD" 2>&1 >/dev/null); RC=$?
gexpect "LIMIT without jq the guard lets everything through" 0
run_guard Bash '{"command":"git reset --hard HEAD~1"}' "$RG";                  gexpect "LIMIT reset/revert/pull/am are not watched" 0
run_guard Bash "{\"command\":\"bash -c 'git commit -m x'\"}" "$RG";            gexpect "LIMIT git run through bash -c" 0
run_guard Bash "{\"command\":\"git -C $RO commit -m x && git -C $RG commit -m y\"}" "$W"; gexpect "LIMIT several repos in one command (first git write decides)" 0

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
