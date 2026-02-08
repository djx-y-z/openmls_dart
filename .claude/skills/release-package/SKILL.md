---
name: release-package
description: Prepare a new version of openmls for publication to pub.dev. Use when user wants to release, publish, or tag a new version of the package.
---

# Release Package

Guide for preparing and publishing new versions of openmls.

## Quick Release Checklist

```bash
# 1. Run quality checks
make analyze
make test
make format-check
make rust-check
make rust-audit

# 2. Update version in pubspec.yaml
# 3. Update CHANGELOG.md (move [Unreleased] to new version)

# 4. Dry run
make publish-dry-run

# 5. Commit release
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: prepare release vX.Y.Z"

# 6. Create annotated tag and push (CI publishes automatically)
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main
git push origin vX.Y.Z
```

## Versioning Rules

Use [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`

| Change Type | Version Bump | Examples |
|-------------|--------------|----------|
| Breaking API changes | MAJOR | Removed/renamed public APIs, changed function signatures |
| New features | MINOR | New public APIs, new platform support |
| Bug fixes | PATCH | Bug fixes, dependency updates, documentation |

**Pre-1.0.0 convention:**
- `0.Y.Z` — initial development, anything may change
- `0.1.0` → `0.2.0` — breaking changes during initial development
- `0.1.0` → `0.1.1` — bug fixes during initial development

## CHANGELOG.md Format

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/):

```markdown
## [Unreleased]

## [X.Y.Z] - YYYY-MM-DD

### Added
- New features

### Changed
- Changes in existing functionality

### Fixed
- Bug fixes

### Security
- Security-related changes
```

### CHANGELOG Rules

1. **Keep `[Unreleased]` at the top** — all in-progress changes go here
2. **Use today's date** when releasing (format: `YYYY-MM-DD`)
3. **Only include sections that have entries** (don't add empty sections)
4. **Released versions are immutable** — never edit entries for versions that already have a git tag

### Comparison Links

Every version entry needs a comparison link at the bottom of `CHANGELOG.md`:

```markdown
[Unreleased]: https://github.com/djx-y-z/openmls_dart/compare/vX.Y.Z...HEAD
[X.Y.Z]: https://github.com/djx-y-z/openmls_dart/compare/vX.Y-1.Z...vX.Y.Z
```

- `[Unreleased]` compares from the latest tag to HEAD
- Each version compares from the previous version tag to the current one
- The first version uses `/releases/tag/vX.Y.Z` (no comparison)

## Pre-Release Validation

### 1. Quality Checks

```bash
make analyze                  # Dart static analysis
make test                     # Run all tests
make format-check             # Check formatting
make rust-check               # Rust type check
make rust-audit               # Security audit
```

### 2. Dry Run

```bash
make publish-dry-run          # Validate pub.dev publishing
```

This checks:
- `pubspec.yaml` is valid
- All required files are present
- Package meets pub.dev requirements
- No oversized files

### 3. Verify Versions Match

Ensure consistency across:
- `pubspec.yaml` — `version:` field
- `CHANGELOG.md` — latest version entry
- Git tag — `vX.Y.Z` (created after commit)

## Publishing Flow

This project uses **tag-triggered CI** for publishing:

1. Push a git tag matching `vX.Y.Z`
2. The `publish.yml` workflow triggers automatically
3. CI publishes to pub.dev using OIDC authentication
4. CI creates a GitHub Release with the tag

**You do NOT run `dart pub publish` manually.** The CI handles it.

### Step-by-Step

```bash
# 1. Update pubspec.yaml version
# 2. Update CHANGELOG.md

# 3. Validate
make publish-dry-run

# 4. Commit
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: prepare release vX.Y.Z"

# 5. Create annotated tag
git tag -a vX.Y.Z -m "Release vX.Y.Z"

# 6. Push commit and tag
git push origin main
git push origin vX.Y.Z
```

### Annotated Tags

Always use **annotated tags** (`git tag -a`) instead of lightweight tags (`git tag`):

- Annotated tags store the tagger name, date, and message
- GitHub Releases show the tag message
- `git describe` works correctly with annotated tags
- The tag message should be `"Release vX.Y.Z"` (or include a brief summary)

### If CI Fails

- Check GitHub Actions logs for the `publish.yml` workflow
- Common issues: missing OIDC permissions, pub.dev authentication
- Fix the issue, delete the tag, re-tag, and push again:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
# Fix the issue, commit
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

## Resources

- [pub.dev Publishing Guide](https://dart.dev/tools/pub/publishing)
- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
