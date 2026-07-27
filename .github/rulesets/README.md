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
| `protect-main.json` | Protect main branch | `~DEFAULT_BRANCH` | pull_request (0 approvals), non_fast_forward, deletion | Admin (5) |
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

Branches from `peter-evans/create-pull-request` (`update-openmls-*`,
`update-template-*`) are deliberately *not* excluded: those PRs are recreated
per version rather than refreshed in place, so the force-push path has never been
exercised. If an update PR is ever seen failing to refresh, extend the same
`exclude` list rather than adding a bypass actor.

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
