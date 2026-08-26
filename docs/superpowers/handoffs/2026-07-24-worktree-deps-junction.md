---
topic: worktree-frontend-deps-junction
type: handoff
repo: ~/scripts
branch: feature/worktree-deps-junction
updated_at: 2026-07-27
---

# 🤝 Handoff — Worktree frontend-deps junction

## 2026-07-27

**Status:** Implementation + all reviews complete. 8 commits on feature/worktree-deps-junction, every one reviewed (incl. the final-review fix a05114d, re-reviewed and Approved). Unpushed, unmerged; master untouched at 563071b. Findings #3/#4/#5 fixed; #6 and branch disposition are the only open items, both awaiting your decision.
**Next move:** Answer the two batched decisions in Open questions, then optionally merge feature/worktree-deps-junction into local master so the junction tooling goes live for the next /start-ticket.
**Working state:**
- Repo: C:\Users\John Patrick Mandal\scripts (no remote; history is all direct-to-master)
- Branch: feature/worktree-deps-junction, from master @ 563071b (untouched)
- Last commit: 6ca6e9a docs(scripts): correct the exit-code contract claim (no consumer reads it yet)
- Uncommitted (this plan's files): clean. The start-ticket.md edits are out-of-repo (not in ~/scripts git), so they live only on disk, committed nowhere.
- Tests: 39 passing (junction-lib 11, sync-frontend-deps 11, cleanup-ticket 9, testdb-lib 8), incl. under a hostile 8.3 short-path TEMP. Store intact at 128,755.
**Open questions / blockers:**
- #6 (plan-mandated, undecided): realdir+match noop never health-checks the destination, so a half-installed private store reports "already provisioned, nothing to do" with exit 0. One-line fix (Test-Path "$destStore\.package-lock.json", else fall through to npm ci) vs. leave as the plan specified.
- Branch disposition (undecided): merge to local master now / leave on the branch / squash-then-merge. Not a V3 PR; personal tooling, no remote, so merging is your normal call.
- Optional: squash the 2 fixups (4ac2ad9 into 0f38741; 50b20ae's test half into 196dc44).
- Optional: -Reclaim wt-V3-1150 + wt-V3-630 (~1.3 GB, lockfiles match). Live worktrees, confirm first.
**Don't repeat:**
- The a05114d re-review is DONE (Approved). That was the previous entry's next move; do not re-run it.
- (carried) Don't speed up the copy (cost is 128k file creations), don't reach for symlinks (need admin here; junctions don't), don't re-diagnose the EPERM next-build-traces warning (pre-existing Windows; build still exits 0), don't propose pnpm, don't introduce Pester, don't aim -Reclaim or verification at the 4 live worktrees.
**Mental context:**
- Both Criticals the final review caught shared one root cause: the never-write-through-a-junction invariant was enforced per call site, not at a choke point. The fix made it structural (unlink lives inside Invoke-NpmCi; -Reclaim compares GetFullPath of source vs. dest).
- #3 resolution was "drop the false claim": the exit codes are correct and kept, but nothing reads them (start-ticket step 7b infers from console text). Do not re-add "step 7b depends on this" wording.
- DATE WART: spec/plan/handoff filenames and the earlier ledger entries read 2026-07-24, but today is 2026-07-27. Content correct; only the date labels are wrong. Rename only if it bothers you.
**Links:** spec docs/superpowers/specs/2026-07-24-worktree-frontend-deps-junction-design.md · plan docs/superpowers/plans/2026-07-24-worktree-frontend-deps-junction.md · ledger .superpowers/sdd/progress.md · no PR · no Jira

## 2026-07-24

**Status:** All 6 tasks implemented and reviewed; 7 commits on `feature/worktree-deps-junction`, unpushed and unmerged. Final whole-branch review found 2 store-destroying Criticals — both fixed.
**Next move:** Re-review commit `a05114d` — it is the only commit on the branch that never passed a task-reviewer gate (it was the final-review fix wave).
**Working state:**
- Repo: `C:\Users\John Patrick Mandal\scripts` (no remote; purely local)
- Branch: `feature/worktree-deps-junction`, branched from `master` @ `563071b` (master untouched)
- Last commit: `a05114d` fix(scripts): guard the shared store against self-targeted reclaim and npm ci through a junction
- Uncommitted: this plan's 6 files are clean. Repo has unrelated pre-existing dirty state (`agent-hook.js`, `samurai-alembic.ps1`, `samurai-dashboard-autostart.ps1`, `autostart-test*.log`, deleted `agent-heartbeat.ps1`) — intentional prior work, never stage with `git add -A`
- Tests: 39 passing — junction-lib 11, sync-frontend-deps 11, cleanup-ticket 9, testdb-lib 8
- Shared store verified intact at 128,755 files; all 4 live worktrees untouched
**Open questions / blockers:**
- **Exit-code contract has no consumer.** Three places (script, spec, plan) claim `/start-ticket` step 7b reads it, but that file never mentions `$LASTEXITCODE` — it tells the agent to infer the outcome from console text. Either wire step 7b to branch on 0/1, or stop claiming it does.
- **Hand-off never warns the store is shared.** `start-ticket.md:257/375` say "linked … no copy"; the `npm install <pkg>` mutates-every-worktree hazard sits 150 lines away at `:411`. This is the one hazard the design concedes is unpreventable and mitigates *only* by documentation.
- **Known seam undocumented in shipped surfaces.** Drift is detected only when the script runs; `:411`'s wording implies it is continuous.
- **`realdir + match → noop` never health-checks the destination** (plan-mandated). A half-installed private store reports "already provisioned — nothing to do", exit 0 — a false all-clear, not a skip-with-reason.
- Optional: squash `4ac2ad9` into `0f38741`, and `50b20ae`'s test half into `196dc44`.
**Don't repeat:**
- Don't try to make the copy faster — `robocopy /MT:16` was already there; the cost is 128k file creations, not bytes. No copy strategy wins.
- Don't reach for symlinks — `New-Item -ItemType SymbolicLink` fails "Administrator privilege required" on this machine; junctions need no elevation. That asymmetry is why junctions were chosen.
- Don't re-investigate the `EPERM: symlink` warning in `next build` — proven pre-existing Windows behavior (same root cause as above), not caused by the junction. Build still exits 0; CI is Linux.
- Don't propose pnpm — considered, rejected: it changes `package.json`/CI/Dockerfile for the whole team, not a solo call.
- Don't introduce Pester. A reviewer suggested it; the repo forbids it. Use the hand-rolled `Assert` harness.
- Don't point `-Reclaim` or any verification at the 4 live worktrees — other agent sessions run in them.
**Mental context:**
- The real trigger was the `pre-push` hook: it runs `npm run build` on any frontend-touching push, so the copy blocked the guard. Junction = 35 ms vs. minutes. Measured `next build` through a junction: exit 0, no `externalDir` issue.
- The safety gate did not need inventing — the pre-existing committed-blob-hash comparison already proved exactly when sharing one store is safe. The change reuses it to *select a mode* rather than gate a copy.
- **Both Criticals had the same root cause:** the never-write-through-a-junction invariant was enforced per call site instead of at a choke point. `-Reclaim` never compared `$destStore` to `$sourceStore` (and `…\samurai_cart_v3` is a tab-completion prefix of `…\samurai_cart_v3 worktrees\`), and the blob-hash bail-out reached `npm ci` before `$destState` was even computed. The fix moved the unlink *into* `Invoke-NpmCi` so it is structural, matching how `Remove-JunctionLink` is already safe by API choice rather than by guard.
- The `exit (Invoke-NpmCi …)` bug is worth remembering as a PowerShell shape, not a one-off: an unredirected native command's stdout joins the function's output stream, so `exit` receives an array and yields 0. The deleted `robocopy` line had `| Out-Null` guarding exactly this; the replacement dropped it. There is now a regression test pinning the scalar return.
**Links:** spec `docs/superpowers/specs/2026-07-24-worktree-frontend-deps-junction-design.md` · plan `docs/superpowers/plans/2026-07-24-worktree-frontend-deps-junction.md` · ledger `.superpowers/sdd/progress.md` (full per-task history) · no PR · no Jira
