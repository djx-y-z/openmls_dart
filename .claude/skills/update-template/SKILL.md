---
name: update-template
description: Update copier template version. Use when checking for template updates, running copier update, or applying template changes to the project structure.
---

# Update Copier Template

Guide for updating the copier template used to generate this project's structure.

## Review Automated PR (Most Common)

When the CI creates a notification PR for a template update, follow these steps:

### Step 1: Read the PR

The automated PR contains:
- **Version comparison** (current vs latest)
- **Changelog** between versions
- **Links** to full comparison and release notes

Review the changelog to understand what changed in the template.

### Step 2: Run copier update

```bash
# Install/update copier (if not installed)
pip install copier jinja2-strcase

# Run copier update to the new version
copier update --trust --defaults --vcs-ref=vX.Y.Z
```

**Flags:**
- `--trust` — required because the template has `_tasks` (post-generation commands). Without it, copier refuses to run or prompts for confirmation.
- `--defaults` — uses default values from `.copier-answers.yml` without prompting. Required in non-interactive environments (e.g., Claude Code), and recommended in general to avoid re-answering questions.
- `--vcs-ref=vX.Y.Z` — pins the exact version to update to.

Copier will:
1. Use existing answers from `.copier-answers.yml` (no interactive prompts)
2. Apply changes via 3-way merge (template old vs template new vs your project)
3. Run template `_tasks` (post-generation commands like `dart format`)
4. Update `.copier-answers.yml` with the new `_commit` value

### Step 3: Review Changes

```bash
# Check what copier changed
git diff

# Check for conflict markers
grep -r "<<<<<<" . --include="*.dart" --include="*.yml" --include="*.yaml" --include="*.md" --include="Makefile"
```

Common things to review:
- **Makefile** — new targets, changed commands
- **Workflows** (`.github/workflows/`) — new steps, updated actions
- **Scripts** (`scripts/`) — new or updated scripts
- **Config files** — `pubspec.yaml`, `analysis_options.yaml`, etc.

### Step 4: Resolve Conflicts

Copier creates `.rej` files for conflicts it couldn't resolve automatically:

```bash
# Find rejection files
find . -name "*.rej"

# Review and manually apply each one, then delete the .rej file
```

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
git add -A
git commit -m "feat: adopt copier template for version vX.Y.Z"
```

### Checklist Summary

- [ ] Read PR changelog — understand what changed
- [ ] `copier update --trust --defaults --vcs-ref=vX.Y.Z` — apply template changes
- [ ] Review diff — no unintended changes
- [ ] Resolve `.rej` files (if any)
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
_src_path: https://github.com/...
```

### Step 2: Check for Updates

```bash
make check-template-updates
```

### Step 3: Apply Update

```bash
copier update --trust --defaults --vcs-ref=vX.Y.Z
```

### Step 4: Review and Test

```bash
make analyze
make test
```

### Step 5: Commit

```bash
git add -A
git commit -m "feat: adopt copier template for version vX.Y.Z"
```

## What copier update Does

Copier compares the template at `_commit` (old version) with the target version and applies the diff to your project. It:

- **Updates** files that changed in the template
- **Preserves** your custom modifications (3-way merge)
- **Creates `.rej` files** for conflicts it can't auto-resolve
- **Adds new files** introduced in the template
- **Does NOT delete** files you added outside the template
- **Runs `_tasks`** (with `--trust`) — post-generation commands defined in the template
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
Copier creates `.rej` files — review each one and apply manually:
```bash
find . -name "*.rej"
# After resolving, delete the .rej files
find . -name "*.rej" -delete
```

### Template asks questions again
Use `--defaults` to skip prompts. Without it, press Enter to keep current values from `.copier-answers.yml`. Only change values if you need to.

### Update changed files I customized
This is expected. Copier does a 3-way merge. If your customizations conflict with template changes, you'll get `.rej` files to resolve manually.

## Resources

- [Copier Documentation](https://copier.readthedocs.io/)
