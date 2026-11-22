---
name: reflect
description: 'Run only when the user types /reflect, usually at the end of a long task. Reviews THIS conversation for durable lessons (user corrections, repeated mistakes, questions the agent had to ask, failed verifications) and sorts each into: a deterministic check to build, a narrow memory/CLAUDE.md rule, or drop. Proposes only — waits for approval before editing anything.'
disable-model-invocation: true
---

# /reflect — turn this session's lessons into structure

Idea borrowed from pstack `reflect` (single pass, approval-gated), with one change: lessons go to **checks first**, prose rules last — a written rule is the symptom; a check is the fix.

## 1. Collect (from this conversation only)
- Every time the user corrected you or said something was wrong / not wanted.
- Mistakes that happened twice, or that a check / reviewer / hook caught.
- Questions you had to ask that the repo or memory could have answered.
- Claims that turned out false when verified.

## 2. Filter — keep a lesson only if ALL are true
- Still true in 6 months (drop SHAs, versions, counts, one-off details).
- Would change what a future agent does.
- Not already covered: read `~/.claude/CLAUDE.md` and the project CLAUDE.md (including any rule ↔ enforcer table), the auto-memory `MEMORY.md` index and the memory files it points to, and this plugin's README. If it is covered but was still broken, that is a signal to **upgrade** it (prose → check), not to add a duplicate.

## 3. Route each kept lesson (in this order)
1. **Check backlog** — could a hook, lint, test, script or permission rule enforce it? Propose the concrete check: where it lives (a check entry for this plugin's engine — build it with `/add-check` / Stop hook / PreToolUse hook / `permissions.deny` / project test), what it blocks, false-positive risk. If you keep a rule ↔ enforcer table in CLAUDE.md, add it there as `none → candidate`.
2. **Rule** — only if it cannot be checked. Write it narrow, with the real example that triggered it.
   - project-specific → a memory file (memory format: frontmatter name/description/type, **Why:** / **How to apply:**) + one line in `MEMORY.md`
   - cross-project → `~/.claude/CLAUDE.md`
3. **Drop** — with a one-line reason.
Also propose **merging or deleting** existing memory entries that this session showed are stale or duplicated (memory bloat is a real cost).

## 4. Present, then stop
```
ACCEPTED   problem → proposal → destination (check / memory file / CLAUDE.md §)
CHECK BACKLOG   check → where → blocks what → risk
REJECTED   lesson → reason
CLEANUP    memory entry → merge/delete → why
```
Wait for the user's approval (they may accept some items). Never edit before approval. Never push, merge, or post to external services (tickets, chat) as part of /reflect.

## 5. After approval
Apply only the approved items. Building a check is real work: follow this plugin's rules (regression-vs-HEAD, SKIPPED instead of silent pass, `tests/run.sh` must pass, bump version). Report exactly what changed and where.
