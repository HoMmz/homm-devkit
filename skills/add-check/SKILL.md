---
name: add-check
description: "Add a new devkit check for a language, tool or recurring mistake (e.g. /add-check eslint for this repo, /add-check python). Researches the tool the project already uses, proves its exit codes on a good and a bad file, writes the check entry into the per-repo config outside the repo, and verifies it blocks a real regression before it counts as done. Use when the user wants devkit to support a new language or to turn a correction into a check."
argument-hint: "<language, tool or mistake to catch>"
---

# /add-check — teach devkit a new check

devkit's engine (`hooks/check.sh`) knows no languages. A check is one entry in
`~/.claude/devkit/repos.json` (or `$DEVKIT_CONFIG`) under the repo's realpath:

```json
{ "name": "eslint", "glob": ["*.js", "*.ts"], "exclude": ["dist/**"],
  "run": "npx --no-install eslint --no-warn-ignored {file}",
  "fail_exit": [1], "compare": "status", "needs": [], "timeout": 60 }
```

Placeholders (shell-quoted by the engine): `{file}` `{rel}` `{root}` `{head}` (the HEAD copy, empty if new).
Exit codes: `0` pass, `fail_exit` (default `[1]`) findings, anything else = tool problem → **SKIPPED** (never a silent pass).
`compare`: `findings` blocks only new output lines vs HEAD (line numbers ignored) · `status` blocks if it passed at HEAD ·
`none` any failure blocks (tool keeps its own baseline or reads `{head}`).

## Steps

1. **Pick the target.** What should be caught, in which repo (`git rev-parse --show-toplevel`, then `realpath`)?
   If the request comes from a correction ("you broke X again"), the check is for X, not a general linter.
2. **Use what the project already has.** Look for the project's own tool and config first
   (package.json scripts/devDependencies, pyproject/ruff/flake8, go vet, rubocop, phpcs, composer scripts…).
   Prefer a per-file command that runs in a few seconds. Avoid whole-project tools (tsc on the full
   project, full test suites) in an edit hook — note them as a manual step instead.
   If the tool is not installed, say so and stop; don't install anything without asking.
3. **Prove the exit codes — never assume them.** In a scratch directory, run the exact `run` command on
   a file that is clean and on one with the mistake. Write down: exit code clean, exit code with finding,
   exit code when the tool itself breaks (bad config / missing binary). Set `fail_exit` from that.
   If the tool's codes can't be mapped (e.g. findings and crashes share a code), write a small wrapper
   that prints findings and exits `0` / `1` / `3`, and keep it **outside the repo**
   (`~/.claude/devkit/checks/<name>/`) with its own `test.sh`. Never add AI/tooling files to the project.
4. **Choose `compare`.** Output lists findings one per line with no summary line → `findings`
   (the HEAD copy runs from a temp dir outside the repo — the tool must give the same kind of output there). Pass/fail only (syntax/lint gate) → `status`.
   Tool has a baseline file or needs `{head}` itself → `none`. Use `needs: ["lint"]` for checks that are
   meaningless on a file that doesn't parse.
5. **Show the config change and get approval** before writing it (it changes what blocks the user's agents).
   Back up the config file first.
6. **Verify on the real repo**, then clean up:
   - pipe `{"tool_input":{"file_path":"<file>"}}` into `hooks/check.sh` (the plugin's path)
   - an untouched existing file → exit `0` (else the check blocks on old problems: fix `compare`/`exclude`)
   - a throwaway untracked file with the mistake → exit `2` and a readable message
   - for `findings`/`status`: a **tracked** file that already has a finding, with a line inserted above it
     (in a scratch clone or a throwaway commit, never in the user's working tree) → exit `0`; then add a new
     finding → exit `2` listing only the new one; then remove one old finding → exit `0` (summary lines like
     "3 problems" break this — switch to `status`). Untracked files never exercise the HEAD comparison.
   - the tool made unavailable (e.g. wrong binary path in a copy of the config via `DEVKIT_CONFIG`) → exit `1` `SKIPPED`
   - delete the throwaway file; `git status` must be as before
7. **Report**: the entry added, the three verification results, timing per file, and anything left manual.

## Rules

- A check that has not been seen to block a real bad file is not done.
- Don't loosen a check (exclude, `fail_exit`, `compare: findings`) just to make an existing file pass —
  existing problems are already non-blocking; if they block, the setup is wrong. Find out why.
- Keep project-specific scripts and term lists out of this plugin; they belong in the user's local config.
