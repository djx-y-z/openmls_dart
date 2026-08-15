---
name: update-template
description: Update copier template version. Use when checking for template updates, running copier update, or applying template changes to the project structure.
---

# Update Copier Template

Guide for updating the copier template used to generate this project's structure.

## Review the Automated PR (Most Common)

`check-template-updates.yml` runs daily and **applies** the update itself — it
does not merely announce one. The PR already contains the result of
`copier update`, an AI-written CHANGELOG entry, and a table of check results.
So the usual job is reviewing, not running anything.

### Step 1: Read the PR body

It states, up front:

- **Version comparison** and the template's changelog for the range
- **Conflicts** — if any, the PR is a **draft** and lists the files. Do not
  count on another gate to catch them. Conflicts are not confined to one file
  type — a single real update left them in `Makefile`, `pubspec.yaml`,
  `rust/Cargo.toml`, `rust/src/frb_generated.rs` and two Dart scripts — and the
  ones in `Makefile` and Markdown pass `format-check`, `rust-check` and
  `analyze` untouched, so a conflicted branch can look perfectly mergeable.
- **`_commit` bumped** — if this says NO, fix `.copier-answers.yml` before
  merging. Merging without it leaves the project looking un-updated and the
  workflow re-opens the same PR on every run.
- **Gate results** — `format-check`, `rust-check`, `analyze --fatal-infos`.
  Reported, never enforced: a template update that breaks a gate is exactly the
  one worth looking at.

### Step 2: Review the diff and the CHANGELOG entry

The entry is filed under `### For Contributors` → `#### Changed`, where every
prior adoption lives. **Move it to `### For Users`** if the release changes what
the published package does at build or run time — that call is yours, and the
entry is written only from the diff that actually landed.

Read the diff itself, not just the summary: a template release describes changes
for every project generated from it, and parts of it arrive here as a no-op.

### Step 3 (draft PRs only): resolve conflicts

Resolve the listed files, push to the same branch, then mark the PR ready. The
workflow will **not** regenerate the branch while its PR is open, so your commits
are safe; only a manual re-run with `force_update` would force-push over them.

---

## Applying an Update Manually

For a local update, or when the automation could not finish:

```bash
make update-template ARGS="--version vX.Y.Z"
```

This runs copier, reports what it could not merge, checks that `_commit` landed,
and writes the CHANGELOG entry (the entry needs `AI_MODELS_TOKEN`; without it the
update still applies). It refuses to start on a dirty tree and names the files —
copier rejects a dirty destination, **untracked files included**.

Or drive copier directly:

```bash
# Install/update copier (if not installed)
pip install copier jinja2-strcase

# Run copier update to the new version
copier update --trust --defaults --skip-tasks --vcs-ref=vX.Y.Z
```

**Flags:**
- `--trust` — required because the template declares `_jinja_extensions`, and because on an update copier also inspects the *old* template's `_tasks`. `--skip-tasks` does not waive it.
- `--defaults` — uses default values from `.copier-answers.yml` without prompting. Required in non-interactive environments (e.g., Claude Code), and recommended in general to avoid re-answering questions.
- `--skip-tasks` — the template's `_tasks` exist to *create* a project (`flutter create`, `dart create`, `dart pub get`, `dart format .`). On a project that already exists they only redo work, and copier runs them **three times** per update — once into a temp copy of the old version, once into your working tree, once into a temp copy of the new one. Measured on a freshly generated project this took the update from 22s to 7s. It also closes the one way an update can damage your tree. A task that fails the same way everywhere — `dart pub get` with no network — aborts in the first of the three renders, before your tree is reached, and leaves it clean. But a task whose trigger lives in **your project** passes that render and fails the next one, which is your tree: `dart format .` over a Dart file that is locally broken does exactly this. Measured, it leaves the template's version of your customized files in place of yours, your changes gone from the worktree, and `_commit` bumped as though the update had succeeded. The one thing skipping gives up is `dart format .` itself: if `format-check` fails on an update branch, run `make format` — that is formatting drift, not a conflict.
- `--vcs-ref=vX.Y.Z` — pins the exact version to update to.

Copier will:
1. Use existing answers from `.copier-answers.yml` (no interactive prompts)
2. Apply changes via 3-way merge (template old vs template new vs your project)
3. Update `.copier-answers.yml` with the new `_commit` value

> **If you just switched `enable_web` to `true`:** `example/web/` is produced by
> the `flutter create` task, not by any template file — so with `--skip-tasks`
> no update will create it. Make it once, explicitly:
>
> ```bash
> # --org has to repeat what generation used, which is `com.` followed by the
> # `package_name` recorded in .copier-answers.yml. Without it flutter aborts
> # with "Ambiguous organization in existing files", because it strips the
> # underscore out of the package name for the iOS and macOS bundle IDs and
> # then finds two candidate orgs in the tree. Every package name this
> # template mandates has an underscore, so this is not an edge case.
> cd example && flutter create . --platforms web --org com.<package_name>
> ```
>
> Use the command rather than making the directory by hand: it also records
> `platform: web` in `example/.metadata`, which a hand-made directory leaves
> wrong.

### Step 3: Review Changes

```bash
# Check what copier changed
git diff

# Conflicts, signal 1 — unmerged paths in the index
git status --porcelain | grep '^UU'

# Conflicts, signal 2 — markers left in tracked files. Needed because anything
# that stages the tree clears the index while leaving the markers in the file.
git grep -lI -e '^<<<<<<< '
```

Common things to review:
- **Makefile** — new targets, changed commands
- **Workflows** (`.github/workflows/`) — new steps, updated actions
- **Scripts** (`scripts/`) — new or updated scripts
- **Config files** — `pubspec.yaml`, `analysis_options.yaml`, etc.

### Step 4: Resolve Conflicts

**Do not go looking for `.rej` files.** In copier's default `--conflict=inline`
mode they are an internal step: copier writes them with `git apply --reject`,
converts each into an inline three-way merge, and deletes it again. By the time
the command returns there are none, so `find . -name "*.rej"` always comes back
empty and reads as "no conflicts" even when there are plenty. (They survive only
if you explicitly pass `--conflict=rej`.)

What copier actually leaves is the ordinary git conflict shape: the path
unmerged in the index, and markers in the file naming the two sides — your
version under `<<<<<<< before updating`, the template's under
`>>>>>>> after updating`, the two split by `=======`.

Check **both** signals; neither alone is enough:

```bash
# Signal 1 — the unmerged index. Authoritative immediately after an update...
git status --porcelain | grep '^UU'

# Signal 2 — ...but staging erases it while leaving the markers in the file, so
# on a branch the pull-request action has already staged, only this one fires.
git grep -lI -e '^<<<<<<< '
```

That is exactly the pair `findConflicts()` in `scripts/src/update_template.dart`
reports from, for the same reason.

Edit each file, delete the markers, then stage it to clear the unmerged state:

```bash
git add <resolved-file>
```

> Never leave a conflict marker at the start of a line in a **tracked** file —
> including in prose like this. `findConflicts()` greps tracked content for
> `^<<<<<<< `, so a literal example in column 1 makes every future update report
> a conflict that is not there. Keep them inline, as above.

### Step 5: Run Quality Checks

```bash
make analyze
make test
make format-check
```

### Step 6: Verify .copier-answers.yml

Copier should update `_commit` automatically, but may fail to do so when:
- There were merge conflicts during update
- The project files already match the new template version (no file changes)

**Always check** that `_commit` matches the target version, and update manually if needed:

```yaml
_commit: vX.Y.Z  # Must match the version you updated to
```

### Step 7: Commit Changes

```bash
# Stage the files the update touched, by name. `git add -A` is the wrong tool
# here: it also sweeps in whatever untracked local debris happens to be lying
# around — .DS_Store, editor scratch files, un-ignored build output — and files
# it under a commit message claiming they came from the template.
git status --porcelain
git add .copier-answers.yml <files-the-update-changed>
git commit -m "feat: adopt copier template for version vX.Y.Z"
```

### Checklist Summary

- [ ] Read PR changelog — understand what changed
- [ ] `copier update --trust --defaults --skip-tasks --vcs-ref=vX.Y.Z` — apply template changes
- [ ] Review diff — no unintended changes
- [ ] Resolve conflicts — `git status --porcelain | grep '^UU'` (not `.rej`)
- [ ] `make analyze` — no issues
- [ ] `make test` — all tests pass
- [ ] `.copier-answers.yml` — verify `_commit` updated automatically
- [ ] Commit all changes

---

## Quick Check (No Changes)

```bash
# Check if a template update is available
make check-template-updates

# JSON output for scripting
make check-template-updates ARGS="--json"

# Check against specific version
make check-template-updates ARGS="--version v1.7.0"
```

## Manual Update Process

### Step 1: Check Current Version

Check `.copier-answers.yml`:
```yaml
_commit: v1.6.0
_src_path: https://github.com/djx-y-z/copier-dart-frb-wrapper.git
```

### Step 2: Check for Updates

```bash
make check-template-updates
```

### Step 3: Apply Update

```bash
copier update --trust --defaults --skip-tasks --vcs-ref=vX.Y.Z
```

### Step 4: Review and Test

```bash
make analyze
make test
```

### Step 5: Commit

```bash
# Stage the files the update touched, by name. `git add -A` is the wrong tool
# here: it also sweeps in whatever untracked local debris happens to be lying
# around — .DS_Store, editor scratch files, un-ignored build output — and files
# it under a commit message claiming they came from the template.
git status --porcelain
git add .copier-answers.yml <files-the-update-changed>
git commit -m "feat: adopt copier template for version vX.Y.Z"
```

## What copier update Does

Copier compares the template at `_commit` (old version) with the target version and applies the diff to your project. It:

- **Updates** files that changed in the template
- **Preserves** your custom modifications (3-way merge)
- **Marks conflicts inline** it can't auto-resolve — markers in the file, path `UU` in the index. No `.rej` files survive in the default `--conflict=inline` mode
- **Adds new files** introduced in the template
- **Does NOT delete** files you added outside the template
- **Runs `_tasks`** unless you pass `--skip-tasks` — and runs them three times, once per render (old temp copy, your tree, new temp copy). Skip them; see the flag notes above
- **Updates `.copier-answers.yml`** — sets `_commit` to the new version

## Common Template Changes

| Category | Examples |
|----------|----------|
| **Workflows** | New CI steps, updated action versions, new workflows |
| **Makefile** | New targets, changed commands, new setup steps |
| **Scripts** | New utility scripts, updated check scripts |
| **Config** | Analysis options, pubspec changes, gitignore updates |
| **Documentation** | CLAUDE.md, CONTRIBUTING.md, README template |

## Troubleshooting

### "copier: command not found"
```bash
pip install copier jinja2-strcase
```

### Conflicts during update
Copier leaves inline conflict markers and an unmerged index entry — not `.rej`
files. List them, resolve, then stage:
```bash
git status --porcelain | grep '^UU'
# edit each file, removing the <<<<<<< / ======= / >>>>>>> markers
git add <resolved-file>
```

### Template asks questions again
Use `--defaults` to skip prompts. Without it, press Enter to keep current values from `.copier-answers.yml`. Only change values if you need to.

### Update changed files I customized
This is expected. Copier does a 3-way merge. Where your customizations collide
with template changes you get an inline conflict to resolve by hand, with your
side under `<<<<<<< before updating` and the template's under
`>>>>>>> after updating`.

## Resources

- [Template repository](https://github.com/djx-y-z/copier-dart-frb-wrapper)
- [Template CHANGELOG](https://github.com/djx-y-z/copier-dart-frb-wrapper/blob/main/CHANGELOG.md) — read this before running `copier update`
- [Copier Documentation](https://copier.readthedocs.io/)
