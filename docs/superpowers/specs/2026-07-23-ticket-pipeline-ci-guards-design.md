# Ticket-pipeline CI guards — wiring the DB fix in, and a pre-merge smoke mirror

**Date:** 2026-07-23
**Status (2026-07-24):** Component 1 proceeded as designed. **Component 2 was built, reviewed, and then scrapped** — `playwright.config.ts` hardcodes the frontend to `:3000` with no override support, so the "isolated from your dev session" premise could only ever be half-true (backend isolated, frontend not). Decided that wasn't worth shipping. See `docs/superpowers/plans/2026-07-23-ticket-pipeline-ci-guards.md` and its progress ledger for the full history — this spec is kept as a record of what was attempted and why it didn't ship, not as a description of what exists today.
**Scope:** Personal tooling only. Component 1 edits a user-level Claude Code command (`~/.claude/commands/ship-ticket.md`). Component 2 adds a new script to `~/scripts` and edits `~/.claude/commands/open-pr.md`. Nothing here touches the `samurai_cart_v3` repo itself.

**Builds on:** `2026-07-21-multi-agent-workflow-design.md` (worktree-by-default + `samurai-test.ps1`/`samurai-testdb-lib.ps1`). That design fixed test-DB collisions at the script level; this one closes two gaps that surfaced after living with it for two days.

## Problem

1. **The DB-isolation fix isn't wired into the automated pipeline.** `samurai-test.ps1` exists and works, but `/ship-ticket`'s TDD execution loop (RED/GREEN/REFACTOR) and its step-3.4 "tests pass" check just say "run them" / "re-run all tests," with no specified command. A subagent executing a plan has no instruction to reach for `samurai-test` over plain `pytest` — the fix only helps if a human remembers to invoke it by hand.
2. **No local mirror of what `samurai_cart_v3`'s real CI checks.** A PR to `master` runs 4 jobs across `pr-checks.yml` + `e2e-smoke.yml`: `pr-validation` (PR title format — hard gate; branch name/size/deps are warnings only), `backend-test-quality` (only its ruff-ratchet step is actually blocking today — pytest + coverage are `continue-on-error: true`, informational pending V3-837), `check-smoke` (self-never-fails, just gates the next job), and `e2e-smoke` (the real one: migrate, seed admin+tenant, start backend, jest auth-bypass-guard specs, a **production** Next.js build, then `npx playwright test --grep "@smoke"`). Only ruff-ratchet is currently mirrored locally (already in `/ship-ticket` step 3). A broken PR discovers that the hard way, burning CI minutes on the heaviest job in the list.

## Non-goals

- No changes to `samurai_cart_v3`'s actual workflow files. This mirrors CI; it doesn't replace or modify it.
- Not attempting to make `pytest`/coverage blocking locally ahead of CI — they're explicitly informational in CI today (V3-837 pending), so a local guard shouldn't be stricter than the thing it's mirroring.
- No port isolation between two simultaneous `samurai-e2e-guard` runs across worktrees. Accepted limitation (see Edge cases) — this is a deliberate, occasional, foreground "am I ready to PR" check, not a background service.
- Not touching `check-smoke`'s detection logic — it's a two-line grep, nothing to mirror.

## Component 1 — `samurai-test` wired into `/ship-ticket`

**Change:** `~/.claude/commands/ship-ticket.md`'s `## References` section gains an entry pointing at `samurai-test.ps1` (same treatment the ruff-ratchet script already gets). The RED/GREEN/REFACTOR steps under "Execute the plan" — currently "Write the failing test(s)... Run them," "Re-run all tests" — get the command made explicit: `samurai-test -Ticket {KEY} <pytest args>`, backend only. Step 3.4's "Tests pass" sanity check gets the same treatment.

**Fallback:** if `samurai-test` isn't reachable (e.g. a non-interactive execution context without PowerShell), fall back to plain `pytest` **and say so explicitly in the hand-off** — never silently swap without flagging it.

**Frontend unaffected:** Jest/vitest runs don't touch a shared Postgres DB, so there's nothing to isolate there.

## Component 2 — `samurai-e2e-guard.ps1`, wired into `/open-pr`

**New file:** `~/scripts/samurai-e2e-guard.ps1`, following the existing `samurai-*.ps1` convention. Dot-sources `samurai-testdb-lib.ps1` (already built for Component 1's predecessor) to derive an **isolated per-ticket e2e database**, `samurai_cart_e2e_{suffix}` — same key-derivation and idempotent create-if-missing helpers, reused rather than duplicated. This matters because this script seeds real state (admin user, tenant, product data) that the smoke tests depend on and mutate — sharing one e2e DB across worktrees would reintroduce exactly the collision problem Component 1 (and the 07-21 design) fixed, just one layer up the stack.

**Sequence, mirroring `e2e-smoke` step-for-step:**
1. `alembic upgrade head` against the isolated e2e DB.
2. `create_superuser.py` + `seed_default_tenant.py` (the same scripts CI runs) — skip if already seeded (idempotent, check-then-create).
3. `npm test -- __tests__/dev-bypass.test.ts components/auth/__tests__ components/providers/__tests__` — the auth-bypass guard jest specs.
4. `npm run build` with `NEXT_PUBLIC_E2E_AUTH_BYPASS=true`, then `next start` — the same **production** build CI tests. `next dev` does not substitute; CI deliberately exercises the build real users get, and dev-only code paths (test cards, swallowed 401s, debug UI) don't run under it.
5. `npx playwright test --grep "@smoke" --pass-with-no-tests`.

**Plus the cheap `pr-validation` gate**, run first since it's near-instant and should fail fast before any of the above spins up:
- Branch name against `^(feature|bugfix|hotfix|release|chore)/.+`.
- PR title against `^(feat|fix|docs|style|refactor|test|chore)(\(.+\))?: .+` — only checkable once a title exists, i.e. after `/open-pr` has drafted one.

Ruff-ratchet is deliberately **not** re-run here — `/ship-ticket` already covers it pre-push (Component 1's fallback note applies equally there).

**Wiring point:** a new step **1b** in `~/.claude/commands/open-pr.md`, immediately after "Resolve KEY and validate" (step 1) and before the Manual Test Plan / PR-body drafting (step 2). On any failure: stop, report exactly which check failed and why, and don't proceed to drafting — no point writing a PR body for something that's about to get blocked. Matches this pipeline's existing "stop and ask, never silently proceed" posture (same shape as `/ship-ticket` step 3's sanity checks).

## Edge cases / error handling

- **`samurai-test` unreachable:** fall back to plain `pytest`, flag it loudly in the hand-off (Component 1).
- **E2E DB creation race:** same idempotent check-then-create pattern as `samurai-testdb-lib.ps1` already uses — tolerates two near-simultaneous invocations without erroring.
- **Port collisions between two simultaneous `samurai-e2e-guard` runs** (backend :8000, frontend prod server) across different worktrees: not solved by this design. If it becomes a real problem in practice (not just theoretical), a follow-up could derive a port offset per ticket key the same way `docker-compose.beta.yml` already does ("Base + N") — deferred, not required for v1.
- **`@smoke` suite grows/shrinks:** the guard always runs `--grep "@smoke" --pass-with-no-tests` against whatever currently matches, same as CI — no hardcoded test list to go stale.
- **Guard fails on something CI would also informational-only skip (pytest/coverage):** guard must not fail on those either — only fail on what CI's `backend-test-quality` job would actually fail on (ruff, already covered elsewhere) and what `e2e-smoke` would actually fail on (steps 1–5 above).

## Validation plan

- Run `/ship-ticket` on a throwaway ticket; confirm the TDD loop's test invocations show the isolated DB name in output, not the shared default.
- Run `samurai-e2e-guard.ps1` standalone against a known-good branch; confirm all 5 steps pass and it reports the e2e DB name used.
- Deliberately break something CI's `e2e-smoke` would catch (e.g. a failing `@smoke` spec) and confirm the guard fails loudly with the same signal, before any PR is opened.
- Run `/open-pr` end-to-end on a throwaway ticket; confirm step 1b actually blocks PR-body drafting on a guard failure, and proceeds normally on success.
