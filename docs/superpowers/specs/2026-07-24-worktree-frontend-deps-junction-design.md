# Worktree frontend deps — junction instead of copy

**Date:** 2026-07-24
**Status:** Design approved, not yet implemented.
**Scope:** Personal tooling only. Rewrites `~/scripts/samurai-sync-frontend-deps.ps1`, edits `~/scripts/samurai-cleanup-ticket.ps1`, and syncs the hand-off wording in `~/.claude/commands/start-ticket.md`. Nothing here touches the `samurai_cart_v3` repo.

**Builds on:** `2026-07-21-multi-agent-workflow-design.md` (worktree-by-default) and `2026-07-23-ticket-pipeline-ci-guards-design.md`. Those made every ticket get its own worktree; this one fixes the cost that imposed on any worktree that has to build the frontend.

## Problem

`node_modules` is gitignored, so `git worktree add` never populates it. `samurai-sync-frontend-deps.ps1` currently fills that gap with `robocopy /E /MT:16` from the main checkout.

The main checkout's `frontend/node_modules` is **128,755 files / 0.66 GB** (measured 2026-07-24). Copying that on Windows, with Defender in the path, is dominated by 128k individual file creations — `/MT:16` is already the practical ceiling for that shape of work. No copy strategy gets meaningfully faster, because the cost *is* the file count.

That cost lands at the worst possible moment. `.git/hooks/pre-push` (lines 43–45) runs `npm run build` in `$REPO_ROOT/frontend` whenever the diff touches `frontend/` minus `browser_tests/`. Hooks live in the shared common dir, so this fires from every worktree and builds against **that worktree's** tree. So: create a worktree (often ad-hoc, e.g. to resolve a merge conflict) → touch frontend → `git push` → the guard needs `node_modules` → you wait out the copy before the guard can even start.

For scale: that frontend build measured **239 s**. The provisioning step was consuming time on the same order as the work it was blocking.

Two secondary problems fall out of the same design:

- **Disk.** 0.66 GB per worktree. Four are live today; two already carry full real copies (~1.3 GB duplicated).
- **A misleading failure.** If `node_modules` is simply absent, the hook doesn't report missing deps — it reports `FRONTEND BUILD FAILED — push blocked`, which misdiagnoses the problem.

## Non-goals

- **No pnpm migration.** A global content-addressable store with hardlinked installs is the real fix, but it changes `package.json`, CI, and the Dockerfile for the whole team. Not a solo call, and not something to slip into personal tooling.
- **No `pre-push` hook changes.** Deliberately out of scope (see Known seam).
- **No changes to `/wrap-ticket`'s teardown hand-off, the stray `Desktop\wt-V3-1151-*` worktree, or a wrong-tree guard.** Real issues, separately scoped.
- **Not preserving robocopy as an alternate mode.** It becomes dead code — see Component 1.

## Verified before designing

Every load-bearing assumption was tested on 2026-07-24, in a throwaway detached worktree, with the four live worktrees untouched:

| Assumption | Result |
|---|---|
| Junction creation is effectively free | **35 ms** |
| `next build` resolves through a junction | **exit 0**, full route table, no `externalDir` complaint (Next 15.5.12) |
| Next doesn't write into `node_modules` | Confirmed — `.next/cache` exists, `node_modules/.cache` does not |
| `[System.IO.Directory]::Delete(path, $false)` unlinks safely | Main store **128,755 → 128,755 files**, intact |
| `git worktree remove --force` doesn't delete *through* a junction | Target survived; git deregistered the worktree and left the junction as an empty shell |
| `Remove-Item -Recurse` on a junction (pwsh 7) | Target intact — but see Component 1 for why we don't rely on this |

Not measured: the actual wall-clock of the current robocopy. Treated as user-reported ("takes so long"), and the 128k-file count is sufficient justification on its own.

## Component 1 — `samurai-sync-frontend-deps.ps1` rewrite

The existing safety gate is kept **verbatim**, because it is already exactly the right precondition: it compares the **committed git blob hash** of `frontend/package-lock.json` between the main checkout and the worktree (not raw file bytes — a partial install can leave that file locally dirty), and checks the source store looks healthy via `frontend/node_modules/.package-lock.json`.

What changes: that gate no longer gates a single copy. It **selects a provisioning mode**.

| `{wt}\frontend\node_modules` | Lockfile blobs | Action |
|---|---|---|
| absent | match | **create junction** → main store |
| absent | differ | `npm ci` in the worktree (private store) |
| junction → main store | match | no-op |
| junction → main store | **differ** | **auto-swap:** unlink, then `npm ci` |
| junction → elsewhere | any | unlink, then re-provision per the match rule |
| real dir | match | no-op — already provisioned, don't churn |
| real dir | differ | `npm ci` in place to refresh it |

Additional guard: if the main checkout has no `node_modules` at all, or it fails the health check, the junction target doesn't exist — fall through to `npm ci`.

**Unlink before `npm ci` is load-bearing.** Running `npm ci` through a live junction writes into the main checkout's shared store. The ordering is not cosmetic.

**Unlink via `[System.IO.Directory]::Delete($path, $false)`.** Not `Remove-Item -Recurse`. The pwsh 7 test above showed `Remove-Item -Recurse` leaves the target intact, but Windows PowerShell 5.1 historically deleted *through* junctions. Since the target is the only good `node_modules` on the machine, use the non-recursive delete — it is structurally incapable of touching the target regardless of host version. Defensive by construction, not by version assumption.

**Robocopy is removed entirely.** In every branch of the table it is either unnecessary (lockfiles match → junction is strictly better) or wrong (lockfiles differ → copying a mismatched store produces a store that doesn't satisfy the worktree's lockfile). There is no remaining case it serves.

**Accepted regression:** the `npm ci` path reintroduces a network install, which was the original motivation for copying (Windows installs getting interrupted mid-extraction by antivirus file-locking on large packages like `@mui/icons-material`). This is accepted because it only triggers on dependency-changing branches, and because no correct alternative exists — you cannot populate a worktree from a store that doesn't match its lockfile. The script should report clearly when it takes this path, so a long wait is never a surprise.

**Exit-code contract preserved:** 0 = provisioned OR a safe intentional skip; 1 = real error, kept explicit so a future caller can branch on it. Note: `/start-ticket` step 7b does NOT currently read this exit code — it infers the outcome from the script's console output. The contract is kept correct for when a consumer is wired, not because one exists.

## Component 2 — `samurai-cleanup-ticket.ps1` unlinks first

One new step in `Invoke-SamuraiCleanupTicket`, between locating the worktree and removing it:

1. Find worktree (unchanged)
2. **New:** if `{wt}\frontend\node_modules` is a junction, unlink it (same non-recursive delete as Component 1)
3. `git worktree remove` (unchanged)
4. Drop the isolated test DB (unchanged)

Unlinking *before* removal rather than cleaning up after: the test showed that removing a worktree with a live junction leaves a dangling junction shell behind and a leftover directory to chase. Unlinking first means `git worktree remove` completes cleanly with nothing orphaned.

If `git worktree remove` fails after the unlink, the worktree is left without `node_modules`. Acceptable — re-provisioning is now a 35 ms operation, which is precisely the point of this change.

## Component 3 — `-Reclaim` switch

An opt-in switch on `samurai-sync-frontend-deps.ps1` that converts an existing real-copy worktree to a junction (verify lockfile match → delete the real directory → create junction).

Note the asymmetry with Component 1: here the target genuinely **is** a real directory, so deletion must be `Remove-Item -Recurse`. The non-recursive `Directory::Delete` is correct only for unlinking junctions and will fail on a populated directory. The script must branch on `LinkType` and pick the matching deletion, not apply one uniformly. Also expect this delete to be slow — removing 128k files is the same order of cost as creating them, so `-Reclaim` is a one-time housekeeping operation, not something to run casually.

**Explicit, never implicit.** In the decision table, `real dir + match` is a deliberate no-op. Silently replacing a worktree's private store with one shared across every worktree is a meaningful change in isolation guarantees, and it should never happen as a side effect of a routine sync call. Someone must ask for it.

Immediate payoff: `wt-V3-1150-incoming-call-filter-jst-fix` and `wt-V3-630-conflict-resolve` both hold real copies with matching lockfiles — ~1.3 GB reclaimable today.

## Component 4 — hand-off wording sync

`~/.claude/commands/start-ticket.md` step 7b and both hand-off blocks (steps 11 and E4) currently say `Frontend deps: copied from main checkout (fast path, no npm install needed)`. With junctions that sentence is false. Update to reflect the three real outcomes: linked, installed (`npm ci`), or skipped-with-reason. Small, but a hand-off that misreports what happened on disk is worse than no hand-off.

## Edge cases / error handling

- **A worktree runs `npm install <pkg>` through a live junction.** It mutates the shared store for every worktree. Not fully preventable — the drift check catches lockfile changes, not ad-hoc installs. Mitigation is recoverability: the store is always reconstructible with `npm ci` in the main checkout. Documented, accepted.
- **Raw `git worktree remove` without the cleanup script.** Proven safe: target survives, worktree deregisters, a dangling junction shell is left behind. Recovery is one `Remove-Item` on the leftover directory.
- **Junctions require NTFS, same local volume, no elevation.** All true here (everything under `C:\Users\...\Desktop`). A junction across volumes or to a network path would fail — out of scope, but the script should surface the error rather than swallow it.
- **Concurrent builds from two junctioned worktrees.** Safe — both only read `node_modules`, and Next writes to each worktree's own `.next/cache`.
- **`git status` in a junctioned worktree.** Unaffected; `node_modules` is gitignored, so the junction is invisible to git.
- **Idempotency.** Re-running the script against an already-correct worktree is a no-op in both the junction and real-dir match rows. Safe to call repeatedly.

## Known seam

With `pre-push` out of scope, **drift is only detected when the script is invoked.** Junction a worktree, rebase onto a master that bumped `package-lock.json`, then go straight to `git push`, and the hook builds against a now-stale shared store. It will often still succeed — the store is usually a superset — but that is luck, not a guarantee.

Two ways to close it later without widening this change: have `/sync-branch` call the script after it rebases, or add the missing-deps check to the hook. Recorded deliberately rather than papered over.

## Validation plan

- Provision a fresh worktree with matching lockfiles; confirm a junction is created, `next build` succeeds, and the elapsed provisioning time is milliseconds.
- Provision a worktree whose branch changes `package-lock.json`; confirm it takes the `npm ci` path and produces a private real directory, not a junction.
- Force the auto-swap: junction a worktree, check out a lockfile-changing commit, re-run; confirm it unlinks then installs, and that the main store's file count is unchanged afterward.
- Run `samurai-cleanup-ticket` on a junctioned worktree; confirm the worktree is gone, no leftover directory remains, and the main store's file count is unchanged.
- Run `-Reclaim` against `wt-V3-1150`; confirm conversion to a junction, a successful build afterward, and ~0.66 GB freed.
- Confirm the exit-code contract still holds for every branch (0 on provision/skip, 1 only on real error) so `/start-ticket` step 7b's reporting stays correct.
