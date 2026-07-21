# Multi-agent dev workflow — isolation design

**Date:** 2026-07-21
**Scope:** Personal tooling only. Nothing here touches the `samurai_cart_v3` repo — Component 1 edits a user-level Claude Code command (`~/.claude/commands/start-ticket.md`), Component 2 lives entirely in `~/scripts`.

## Problem

Running multiple concurrent Claude Code sessions against `samurai_cart_v3` (e.g. one tab on feature A, another on bug B) hits two collision points:

1. **Branch collisions.** `/start-ticket` creates branches with `git checkout -b` in place, in whatever directory it's run from. A fresh agent session has no way to know another session already owns the current checkout's branch, so it can start working directly on top of someone else's in-flight work unless manually told to use a worktree every time.
2. **Test DB collisions.** `backend/tests/conftest.py`'s `db` fixture runs `DROP SCHEMA public CASCADE` against a single shared `samurai_cart_test` database per test function. Two concurrent `pytest` runs (from two different agent sessions) race on that DROP/CREATE cycle and produce false failures — reproduced firsthand across two sessions working V3-295 and V3-1149 on 2026-07-19/20.

## Non-goals

- No changes to `backend/tests/conftest.py` or anything else in the `samurai_cart_v3` repo. The DB fix must not change behavior for sir Sat / sir Jo / sir Romeo or CI, which all rely on the current shared-DB default.
- No new custom "who owns what branch" registry file. `git worktree list` already answers that question once every ticket gets its own worktree.
- No automatic branch/worktree deletion. `/wrap-ticket` deliberately never touches branches today ("you clean up branches yourself") — this design preserves that: cleanup here is manual/opt-in, just combined into one step instead of two.

## Component 1 — `/start-ticket` worktree-by-default

**Change:** step 7 of `~/.claude/commands/start-ticket.md` moves from branching in the current checkout to creating an isolated worktree for every ticket, no exceptions (chosen over conditional/smart detection — simpler, no "is the main checkout busy" judgment call, main checkout stays parked on master permanently).

**Naming convention** (mirrors the branch, prefix dropped since it's a redundant git-ref namespace):

| | Pattern | Example |
|---|---|---|
| Branch | `{prefix}/{KEY}-{slug}` | `bugfix/V3-1193-category-duplicate-name-guard` |
| Worktree | `C:\Users\John Patrick Mandal\Desktop\wt-{KEY}-{slug}` | `wt-V3-1193-category-duplicate-name-guard` |

Desktop is the base (not the session scratchpad) per the existing `windows_worktree_maxpath` finding — a short base clears Windows MAX_PATH even with the repo's deepest frontend paths.

**Step 7 becomes:**

```bash
git -c core.longpaths=true worktree add -b {prefix}/{KEY}-{slug} "C:/Users/John Patrick Mandal/Desktop/wt-{KEY}-{slug}" {base}
```

`{base}` is chosen by the existing step 6.3 logic (local master / origin/master), unchanged.

**Side effect — step 6.1 gets simpler.** The current "you have uncommitted changes in the working tree, abort/stash/proceed?" prompt exists because `git checkout -b` in place would carry those changes onto the new branch. `git worktree add` never touches the current checkout's working tree, so that prompt no longer applies to branch creation and can be dropped from the pre-flight sequence (the underlying "don't auto-stash intentional local hacks" preference is preserved — there's just nothing to stash anymore, since nothing in the current checkout is being touched).

**Duplicate protection.** Before creating, check `git worktree list` for a worktree already on `{prefix}/{KEY}-{slug}`. If found, report its path instead of creating a second one. This extends the existing step-1 re-run detection (which today only checks the vault overview + auto-memory cache) with a third signal.

**Hand-off.** Step 11's success message reports the new worktree path so the next action is obviously "open a Claude Code session there."

**Downstream commands unaffected.** `/work-ticket`, `/open-pr`, `/ship-ticket`, `/wrap-ticket`, `/review-mine`, etc. all operate relative to cwd already — no logic changes needed, since they'll simply be invoked from inside the worktree going forward. Validate with a grep pass for any hardcoded reference to the main checkout path before calling this done.

**Considered and rejected:** the native `EnterWorktree`/`ExitWorktree` tool pair (creates worktrees under `.claude/worktrees/`, tracks ownership automatically). Rejected for now because its schema exposes no explicit branch-name parameter — unverified whether it would produce the exact `{prefix}/{KEY}-{slug}` branch name the rest of the pipeline (PR titles, vault links) depends on. Worth revisiting later if that's confirmed to be controllable.

## Component 2 — personal per-worktree test-DB isolation

**New file:** `~/scripts/samurai-test.ps1`, exposed as a `samurai-test` function/alias alongside the existing `samurai` / `dash` commands. Not part of the `samurai_cart_v3` repo.

**Behavior:**

1. Derive the ticket key from cwd — parse it out of the `wt-{KEY}-{slug}` folder name (falls back to parsing the current git branch name if run somewhere that doesn't match, e.g. still inside the main checkout).
2. Sanitize into a DB-safe suffix: lowercase, `-` → `_` (e.g. `V3-1193` → `v3_1193`).
3. Ensure `samurai_cart_test_{suffix}` exists — a small check-then-`CREATE DATABASE` against the `db` container, the same idea as `conftest.py`'s own `_ensure_test_db_exists`, just parameterized instead of hardcoded to the literal `samurai_cart_test` name (confirmed `conftest.py` does NOT do this for arbitrary DB names today — its auto-create is hardcoded to the default, which is exactly why last session's manual override required a manual `CREATE DATABASE` first).
4. Run the actual `pytest` invocation inside the container with `TEST_DATABASE_URL` pointed at the derived DB (`postgresql+asyncpg://samurai:samurai_dev_password@db:5432/samurai_cart_test_{suffix}`), forwarding through whatever path/marker/`-k` args were passed to `samurai-test`.
5. Print which DB it used, so it's never a mystery which schema a run hit.

**Why a script over a CLAUDE.md convention:** a written instruction relies on every agent session remembering to compute and pass the override correctly each time. A script makes it the path of least resistance — the same reliability reasoning behind `samurai-dev.ps1`/`samurai-dash.ps1` already existing instead of a written checklist.

## Combined cleanup

**New file:** `~/scripts/samurai-cleanup-ticket.ps1` (or a function inside an existing script), invoked manually as `samurai-cleanup-ticket {KEY}` once a ticket is genuinely done (typically after `/wrap-ticket` has already flipped the vault status).

In one shot:
- `git worktree remove` the `wt-{KEY}-*` worktree (refuses on uncommitted/unmerged changes, same safety behavior as plain `git worktree remove`).
- Drop `samurai_cart_test_{suffix}` if it exists.
- Report what was removed.

Deliberately **not** wired into `/wrap-ticket` itself — that command's existing philosophy is merge-gated status flips only, hand-off reminders for everything manual (Jira, the release sheet, branch deletion). This preserves that split: `/wrap-ticket` still only writes the vault; cleanup stays a separate, explicit action you trigger when ready.

**Considered, not required for v1:** surfacing "worktree still present for a merged PR" as a reminder inside `/my-prs`'s dashboard. Nice-to-have, not blocking — can be added later without changing this design.

## Edge cases / error handling

- **MAX_PATH:** `-c core.longpaths=true` on every `git worktree add`, belt-and-suspenders per the existing memory finding.
- **DB creation race:** `samurai-test.ps1`'s check-then-create must tolerate "already exists" (idempotent) — two near-simultaneous runs against the same worktree shouldn't error.
- **Worktree already exists for KEY:** `/start-ticket` reports and reuses rather than erroring or duplicating.
- **`samurai-cleanup-ticket` on a worktree with uncommitted work:** refuse and report, same as `git worktree remove`'s own safety default — never force-remove silently.

## Validation plan

- Dry-run `/start-ticket` on a throwaway key; confirm the worktree lands at the right path, on the right branch name, and that `/open-pr`/`/review-mine` work unmodified from inside it.
- Run `samurai-test.ps1` from two different worktrees at the same time; confirm both pass without a shared-schema collision.
- Run `samurai-cleanup-ticket` against a finished throwaway ticket; confirm both the worktree and its test DB are gone afterward.
