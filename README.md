# homm-devkit

A language-agnostic starter for deterministic guardrails in [Claude Code](https://code.claude.com).

The idea: every time you have to correct an agent, turn the correction into a **check** instead of another line in a prompt. Checks are reproducible; prose rules drift.

The plugin is a structure, not a rule set. It ships a small engine, a guard, a reviewer agent and two skills. **You** tell it which commands to run for your languages, or ask Claude to work that out with `/add-check`.

## Structure

```
hooks/
  check.sh       PostToolUse (Edit/Write/MultiEdit): runs the checks configured for the edited file
  stop-check.sh  Stop / SubagentStop: re-runs them on every file changed vs git HEAD before an agent may finish
  guard.sh       PreToolUse (Read/Grep/Bash): denies .env reads; optional protected branches
agents/
  reviewer.md    homm-devkit:reviewer — independent read-only reviewer (Read/Grep/Glob only)
skills/
  add-check/     /add-check — research a tool, prove its exit codes, add + verify a new check
  reflect/       /reflect — end of session: lessons → check to build / narrow rule / drop
tests/run.sh     engine, stop-check and guard tests (language-free; uses a fake check)
```

Your checks and any wrapper scripts live **outside this plugin and outside your repos**, in `~/.claude/devkit/`. That way the plugin stays generic, and you can update it without losing your setup.

## How a check works

```
edit a file ──► which checks match? (glob / exclude)
                    │ none → done
                    ▼
               run "run" command ──► exit 0 → pass
                    │ exit in fail_exit
                    ▼
               compare with the git HEAD copy of the file
                    │ new problem → BLOCK (exit 2, message goes back to Claude)
                    │ already there at HEAD → don't block
               any other exit code → SKIPPED warning (never a silent pass)
```

Principles:
- **Block only regressions introduced by the edit.** Problems that already existed at HEAD don't block.
- **Never a silent pass.** A missing tool, a broken config or an unexpected exit code prints `devkit: <check> SKIPPED — <reason>`.
- **Prove it blocks.** A check counts only after it has been seen to block a real bad file (`/add-check` does this for you).

## Config

`~/.claude/devkit/repos.json` (override with `DEVKIT_CONFIG`). Key = realpath of the repo root; a git worktree uses its main repo's entry. `default` applies to repos without an entry. No config means no checks run. A malformed config or check entry is reported as SKIPPED, never ignored.

```json
{
  "default": { "checks": [] },
  "repos": {
    "/path/to/repo-a": {
      "exclude": ["vendor/**", "dist/**"],
      "checks": [
        { "name": "eslint", "glob": ["*.js", "*.ts"],
          "run": "npx --no-install eslint {file}", "compare": "status", "timeout": 60 },
        { "name": "ruff", "glob": ["*.py"], "run": "ruff check --quiet --output-format concise {file}" }
      ],
      "guards": { "protectBranches": ["main"] }
    }
  }
}
```

| Field | Meaning |
|---|---|
| `name` | Label in messages; used by `needs` |
| `glob`, `exclude` | Relative to repo root; `*` and `**` both match across `/` |
| `run` | bash command, cwd = repo root. Placeholders (shell-quoted): `{file}` `{rel}` `{root}` `{head}` (HEAD copy of the file, empty if new). `findings`/`status` re-run the command on the HEAD copy through `{file}`, so they require `{file}` |
| `fail_exit` | Exit codes that mean "findings" (default `[1]`). `0` = pass. Anything else = SKIPPED |
| `compare` | `findings` (default): block only output lines that are new vs HEAD; the block message lists only those · `status`: block if it passed at HEAD or the file is new · `none`: any failure blocks (tool keeps its own baseline, or reads `{head}`) |
| `needs` | Skip this check when a listed check failed on the same file (e.g. don't run a linter on a file that doesn't parse) |
| `timeout` | Seconds (needs `timeout`/`gtimeout`) |

**What `findings` needs from a tool.** One finding per line, without summary lines like "2 problems". When comparing, the engine ignores the file path (absolute, repo-relative or `./name`) and line/column numbers (`line 12`, `:12:5`, a leading `12:5`, `(12,5)`). The HEAD copy is checked from a temp directory **outside the repo**, so a tool that finds its config from the file's location may behave differently there. Before relying on `findings`, check it against a tracked file that already has a finding, after adding a line above that finding: it must not block. If a tool fails that test, use `status`, or a wrapper that prints clean lines and points the tool at the repo's config.

When a check fails but prints nothing, `findings` falls back to `status`.

When a tool's exit codes don't fit, write a small wrapper that prints findings and exits `0` (ok), `1` (findings) or `3` (tool unavailable → SKIPPED). Keep it in `~/.claude/devkit/checks/<name>/` with its own test.

### Guard

- Denies `Read` on `.env` / `.env.*` (any letter case), `Grep` with such a path or glob, and Bash commands that name one. `.env.example/.sample/.dist/.template` are allowed.
- `guards.protectBranches`: every git commit/merge/cherry-pick/rebase/push in the command is judged on the branch it will run on. The guard follows `git checkout|switch` (including `-b`, `-`, `--track`) earlier in the same command, so no write lands on those branches and no push targets them (`branch`, `x:branch`, `refs/heads/branch`, `+branch`, `HEAD` while on it, `--all`, `--mirror`). To go through on purpose, prefix the git command with `DEVKIT_ALLOW_MASTER=1`. Use the prefix only when the user asked for that merge/push. A git worktree uses its main repo's entry.
- The repo is taken from `git -C <dir>` / `--work-tree <dir>`, else from the last `cd|pushd <dir>` before the git command, else from cwd.

**Limits: the guard is a speed bump, not a security boundary.** It catches an agent's ordinary mistakes: typing the file name, merging into `master` in one command. A shell can always get around it. It does not catch:
- shell globs (`cat .en?`)
- recursive search (`grep -r`, or `Grep` over a whole folder)
- interpreters that build the name (`python -c …`)
- other secret files (`*.pem`, `id_rsa`, `secrets.json`)
- `$VAR` paths
- git commands outside the list (`reset`, `revert`, `pull`, `am`)
- git run indirectly (`bash -c '…'`, aliases)
- several repos in one command (judged by the repo of the first git write)
- option values containing spaces, line continuations, `push -o <value>`
- a missing `jq` (the guard then lets everything through)

These cases are pinned as "known limits" in `tests/run.sh`. For real protection, deny reads in Claude Code permissions (`"permissions": {"deny": ["Read(./.env)", "Read(./.env.*)"]}`) or enable the sandbox, keep secrets outside the working tree, and turn on branch protection on the git server.

## Extending

1. **New language or tool:** run `/add-check <tool or language>`. It finds the tool the project already uses, proves its exit codes, shows you the config change, then verifies the check on your repo.
2. **New kind of hook:** add a script under `hooks/`, register it in `.claude-plugin/plugin.json`, and add cases to `tests/run.sh`.
3. **After a long session:** run `/reflect`. It turns repeated corrections into checks to build.

## Requirements

`bash` (3.2+), `git`, `jq`, `realpath`, `awk`, `sed`, plus whatever tools your checks call.

## Install

```bash
claude plugin marketplace add HoMmz/homm-devkit
claude plugin install homm-devkit@homm-devkit --scope user
```

Restart the session to load hooks, the agent and the skills.

## Develop

Run `tests/run.sh` before every version bump. It builds throwaway git repos, checks each hook's exit code and message, and runs `claude plugin validate`.

## License

MIT
