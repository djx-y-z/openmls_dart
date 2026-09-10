# Repository rulesets & release protection

This directory holds the GitHub **repository rulesets** as committed JSON — the
source of truth, visible and editable in-repo — plus this runbook. Apply them
with:

```bash
make setup-repo-protections
```

which reads every `*.json` here, creates it on GitHub (idempotent by ruleset
name — existing ones are skipped unless `--update`), and configures the
`native-build` environment with you as a required reviewer.

Rulesets and environments live **on GitHub**, not in a repo file — GitHub does
not apply this directory automatically. `make setup-repo-protections` (or the
manual `gh api` calls below) pushes them there, so run it **after the GitHub repo
exists** (first push). A wrong bypass actor can lock a maintainer out of
releasing, so review before applying. All commands assume the
[`gh`](https://cli.github.com) CLI authenticated as a repo **admin**; replace
`djx-y-z/openmls_dart` if you renamed the repo.

## Why this exists (the supply-chain gap)

The native binaries that every consumer downloads at build time
(`hook/build.dart` → GitHub Release `openmls_frb-<crate>`) are produced by
`.github/workflows/build-openmls.yml`, which publishes a release when
**either** a `openmls_frb-*` tag is pushed **or** it is started manually
(`workflow_dispatch`). Without protection, any collaborator with `write` could
push a `openmls_frb-*` / `v*` tag or dispatch the workflow and ship a native
binary to consumers with no review — a supply-chain risk for a native/crypto
library. By contrast the pub.dev publish (`publish.yml`) is gated by the `pub.dev`
environment's required reviewers. The rulesets + `native-build` environment below
bring the native build up to the same bar.

## The rulesets

Repository roles referenced by `actor_id`: Read = 1, Triage = 2, Write = 3,
Maintain = 4, **Admin = 5**.

| File | Ruleset | Target | Rules | Bypass |
|------|---------|--------|-------|--------|
| `protect-main.json` | Protect main branch | `~DEFAULT_BRANCH` | pull_request (0 approvals), required_status_checks, non_fast_forward, deletion | Admin (5) |
| `signing-commit.json` | Signing commit | `~ALL` branches except `dependabot/**/*` | required_signatures, non_fast_forward | none by default |
| `delete-branches.json` | Delete branches | `~ALL` branches except `dependabot/**/*` | deletion | Admin (5) |
| `protect-release-tags.json` | Protect release tags | all tags (`~ALL`) | creation, update, deletion, required_signatures | Admin (5), Maintain (4) |

The load-bearing one is **Protect release tags**. It targets **all tags**
(`~ALL`), so `creation` restricts creating *any* tag to Admin/Maintain — which
covers the release-triggering `openmls_frb-*` (native build) and `v*`
(pub.dev) tags and every other tag, so no `write` collaborator can mint a tag
that starts a publish. (Only `openmls_frb-*`/`v*` actually trigger a
workflow; the `~ALL` scope is defense-in-depth so the rule never lags behind a
new trigger pattern.) `update`+`deletion` make tags immutable;
`required_signatures` is belt-and-suspenders (`make release-frb` / `make release`
already sign tags). If GitHub ever rejects `required_signatures` on a tag target,
drop that one rule.

### Required status checks

`protect-main.json` requires twelve checks — **`FRB bindings were regenerated`**,
the job in `codegen-guard.yml`, plus the whole test matrix:

```
FRB bindings were regenerated
test / Test (Linux x86_64)
test / Test (Linux ARM64)
test / Test (macOS ARM64)
test / Test (Windows x86_64)
test / Security Audit (Rust)
test / Dependency Policy (cargo-deny)
test / MSRV (rust-version from Cargo.toml)
test / Workflow Lint (actionlint)
test / Cross-compile (Android arm64-v8a)
test / Cross-compile (Android armeabi-v7a)
test / Cross-compile (Android x86_64)
```

#### The asymmetry the list rests on

A required check is satisfied by a check run reporting on the pull request's head
commit. There are two ways a job can fail to run and they are **not** equivalent:

- a job excluded by a **job-level `if:`** still reports, as `skipped`, and that
  counts as satisfied;
- a workflow excluded by a **workflow-level `paths:`** reports **nothing**, and
  the pull request then waits for it forever — no setting reads a missing check
  as passed.

That is why `test.yml`'s `pull_request` trigger carries no `paths:` filter, and
why it must not regain one: every `test / …` leg above would otherwise block —
permanently, and with nothing to fix — exactly the pull requests that touch only
documentation. The filter stays on `push`, where it guards the cache scope rather
than a gate. If the whole matrix on a docs-only pull request ever becomes a real
cost, the fix is a job-level `if:` on the expensive legs, never the path filter
back. `codegen-guard.yml` has never had one, for the same reason, and no
job-level condition on the job that reports.

#### Drop any leg this project finds flaky

A required check that fails by itself teaches people to merge past required
checks, which costs more than the leg is worth. Remove such a leg from
`protect-main.json` — leaving it in the workflow, where it still reports — and
put it back the moment it is fixed, not before.

Two cautions before deciding which leg that is. **Count, do not rank on
reputation** — a flake gets attached to one leg early and stays attached; count
isolated failures (one leg red, the rest green) over recent runs instead. Expect
the count to be small and to prove less than it looks: three events spread over
four legs cannot tell a platform problem from chance, and the plausible
explanations are worth checking against the numbers rather than assumed — "the
slowest runner flakes" is the usual one, and in the project this comes from it
was false, the slowest leg by wall clock being the one that never flaked.

**Choose by what the absence costs**, which is knowable even when the cause is
not: a leg whose platform another required leg already covers is cheap to drop,
while the only leg covering its platform is not, however often it flakes.
Diagnosing the flake beats either exclusion.

`test / Update Coverage Badge` belongs in neither list — it is skipped on pull
requests, so it would be satisfied without asserting anything.

#### Field notes

The `test / ` prefix is part of the context and comes from the **job id** in
`test.yml` that calls the reusable workflow; the half after it is the called
job's `name:` in `test-reusable.yml`, matrix legs included. Rename either and
every context here stops matching silently, which surfaces as "waiting for
status" rather than as an error.

`Workflow Lint (actionlint)` is worth requiring for a reason the other legs do
not share: it is the only check that reads the workflows themselves, so it is the
one that can still report on a pull request whose other jobs never start because
the file that defines them does not parse.

The three `Cross-compile (Android …)` contexts are the easiest to forget, because
nothing else in a generated project cross-compiles Android: leaving them out is
how the gap they were added to close comes back with the ruleset saying CI is
required. They also run under `publish.yml`, which calls the same reusable
workflow — so they sit between "start publishing" and "published", not only on
pull requests.

`integration_id: 15368` is GitHub Actions. Without it the context is satisfied by
*any* status of that name, including one posted through the API by a token
holding `repo:status`.

`strict_required_status_checks_policy` is `false` deliberately: `true` requires
every open pull request to be re-tested against the tip of the default branch
after each merge, which against a weekly grouped Dependabot batch is a rebase
treadmill and not a safety property.

Read this rule together with `bypass_actors` above. Admin is `always`, so it
turns a red — or an unreported — check into something an admin has to click past
on purpose. Worth having, and worth knowing which way it cuts: this is not "red
CI can no longer merge", and a context that stops being reported is recoverable
rather than a lockout. `make release-frb` / `make release` push their commit to
`main` directly and pass on the same bypass.

#### Changing the list

Verify a context string against a real **pull request** before requiring it. A
name read off a push to `main` is not proof, because the two triggers do not
produce the same set of check runs — `test / Update Coverage Badge` is the
example, reporting on a push and `skipped` on a pull request — and it is the
pull-request set a merge gate is measured against.

```bash
SHA=$(gh api repos/djx-y-z/openmls_dart/pulls/<N> --jq .head.sha)
gh api "repos/djx-y-z/openmls_dart/commits/$SHA/check-runs" \
  --jq '.check_runs[].name' | sort
```

Then apply with `make setup-repo-protections ARGS="--update"`: plain
`make setup-repo-protections` **skips** a ruleset that already exists, so the
edit would land in the file and nowhere else. `--update` PUTs the whole ruleset,
so diff the live one against the file first (see *Verify / roll back* below) —
anything changed in the UI and not written back here is overwritten. GitHub adds
its own defaults to what it stores (`do_not_enforce_on_create`,
`require_extra_approval_for_unattributed_changes`, `required_reviewers`), so
expect those three back in the response; they are not UI edits.

### Why Dependabot branches are excluded

**Signing commit** and **Delete branches** target `~ALL` branches, and the former
has *no* bypass actors — so nothing, not even an admin, may force-push or delete
a branch. That silently breaks Dependabot: it refreshes an open PR by
force-pushing a rewritten commit, so `non_fast_forward` makes it impossible for a
grouped action-bump PR to ever be rebased onto a moved `main` (it comments
"because the branch … is protected it was unable to do so" and gives up), and
`deletion` blocks `@dependabot recreate` and post-merge branch cleanup.

Excluding `refs/heads/dependabot/**/*` costs nothing in practice: Dependabot's
commits carry a valid GitHub signature regardless of the rule, and the branches
still have to pass `~DEFAULT_BRANCH`'s `pull_request` gate plus `main`'s own
`required_signatures` to reach `main`. Scope this with `ref_name.exclude`, **not**
with a bypass actor — the rulesets target `~ALL`, so a bypass actor would also
be exempt on `main` itself, which is the opposite of what is wanted.

It is no longer only a convenience, though, and that matters when narrowing it.
`refresh-notices.yml` regenerates `THIRD_PARTY_NOTICES.txt` on Dependabot's
cargo pull requests and pushes an ordinary **unsigned** commit to those
branches — legal only because `required_signatures` does not reach them. Keeping
the force-push and deletion exclusions while requiring signatures again would
put every cargo pull request back to unmergeable with nothing saying why: the
workflow's push is rejected, and the stale inventory then fails
`test / Test (Linux x86_64)`, one of the required contexts above. If signatures
are ever wanted on these branches, that workflow has to create its commit
through the GitHub API — which signs — rather than with `git push`.

Mind the pattern's trailing `/*`. These are `fnmatch` patterns in pathname mode,
where a bare `**` does **not** cross a `/`: `refs/heads/dependabot/**` matches
`dependabot/foo` but *not* `dependabot/github_actions/github-actions-1f84650690`,
which is the shape Dependabot actually uses (and it goes deeper still when a
config scopes updates to a directory). Only `**/*` matches at any depth. Verify a
change to these patterns against the real branch name rather than by eye:

```bash
gh api repos/djx-y-z/openmls_dart/rules/branches/dependabot%2Fgithub_actions%2Fsome-branch \
  --jq '[.[] | .type] | join(", ")'    # expect empty
gh api repos/djx-y-z/openmls_dart/rules/branches/main \
  --jq '[.[] | .type] | join(", ")'    # expect the full set, unchanged
```

Branches from `peter-evans/create-pull-request`
(`update-openmls-*`, `update-template-*`) are deliberately *not*
excluded: those PRs are recreated per version rather than refreshed in place, so
the force-push path has never been exercised. If an update PR is ever seen
failing to refresh, extend the same `exclude` list rather than adding a bypass
actor.

## Apply

```bash
make setup-repo-protections                   # apply all (skips existing rulesets)
make setup-repo-protections ARGS="--update"   # overwrite existing rulesets (PUT)
make setup-repo-protections ARGS="--no-environment"   # rulesets only
```

Manual equivalent (per file), if you can't use the script:

```bash
gh api --method POST repos/djx-y-z/openmls_dart/rulesets \
  --input .github/rulesets/protect-release-tags.json
```

**Verify / roll back:**

```bash
gh api repos/djx-y-z/openmls_dart/rulesets --jq '.[] | "\(.id)\t\(.name)"'
gh api --method DELETE repos/djx-y-z/openmls_dart/rulesets/<ID>   # roll back one
```

Prefer a dry run? Set `"enforcement": "evaluate"` in a JSON file, apply, watch the
ruleset "insights", then flip back to `"active"` and re-run with `--update`.

## The `native-build` environment (approval gate)

A tag ruleset does **not** cover the `workflow_dispatch` path, so
`build-openmls.yml`'s `create-release` job runs in the `native-build`
environment. `make setup-repo-protections` creates that environment and adds you
as a required reviewer; until reviewers exist the gate is inactive (GitHub
auto-creates the environment unprotected, which is safe). To also forbid entering
it off an arbitrary ref, add a deployment-branch policy allowing only
`openmls_frb-*` (Settings → Environments → native-build).

> Environment protections (required reviewers, deployment-branch policy) are not
> expressible as a committed file, so the script sets them via the environments
> API and this runbook is their source of truth.

## Project-specific / optional fields

- **`signing-commit.json` bypass (empty by default).** If a GitHub App pushes
  commits (e.g. the `check-openmls-updates.yml` update bot), it needs
  a bypass entry only when it pushes *unsigned* refs. Find its Integration id and
  add it to `bypass_actors`:
  ```bash
  gh api repos/djx-y-z/openmls_dart/installations --jq '.installations[].app_id'
  ```
  ```json
  { "actor_id": <APP_ID>, "actor_type": "Integration", "bypass_mode": "always" }
  ```
  If the bot commits via the API with `sign-commits: true` (already signed), it
  needs no bypass — leave the array empty. And if what the bot actually needs is
  to *force-push* or *delete* its own branch, add its ref pattern to
  `ref_name.exclude` instead: this ruleset covers `~ALL` branches, so a bypass
  actor would be exempt on `main` too.

## Optional hardening (review, not required)

- **"Protect main" approvals.** With a solo maintainer, 0 required approvals is
  only a "use PRs" hygiene gate — the Admin bypasses it anyway. Once you add
  non-admin write collaborators, raise `required_approving_review_count` to 1 and
  enable `require_last_push_approval` in `protect-main.json`, then re-run with
  `--update`.

## Residual risks (out of scope for rulesets)

- **Build-time code execution.** On a `workflow_dispatch` run off an attacker's
  branch, their `build.rs` / proc-macros still *execute* in the build runners
  before the `create-release` approval gate. Keep those jobs free of secrets, so
  the blast radius is CPU, not credential theft.
- **Binary authenticity.** Every native release is now attested with SLSA build
  provenance (`actions/attest-build-provenance`), with an offline-verifiable
  Sigstore bundle attached to the release — see `SECURITY.md → Supply Chain
  Security → Authenticity`. Known limitation: `hook/build.dart` itself still
  verifies downloads by SHA256 only; attestation verification is manual
  (`gh attestation verify`).
