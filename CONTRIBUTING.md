# Contributing to openmls

Thank you for your interest in contributing to openmls!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/djx-y-z/openmls_dart.git`
3. Setup development environment: `make setup`
4. Create a feature branch: `git checkout -b feature/your-feature`

## Development Workflow

### Running Tests

```bash
make test
```

### Code Formatting

```bash
make format
```

### Static Analysis

```bash
make analyze
```

### Coverage Report

```bash
make coverage
```

## Pull Request Process

1. Ensure all tests pass: `make test`
2. Ensure code is formatted: `make format-check`
3. Ensure no analyzer issues: `make analyze`
4. Update documentation if needed
5. Update CHANGELOG.md with your changes
6. Submit a pull request

## Updating Native Library

### Automatic Updates (CI)

The CI automatically checks for new openmls releases daily and creates PRs. The automation includes:
- Updating `pubspec.yaml` with new version
- Updating `Cargo.lock` dependencies
- Regenerating FRB bindings
- Generating AI-powered CHANGELOG entry (if `AI_MODELS_TOKEN` is configured)

### Manual Updates

```bash
# 1. Check for updates
make check-new-openmls-version

# 2. Apply update
make check-new-openmls-version ARGS="--update --version v1.0.0"

# 3. Update Cargo.lock
make rust-update

# 4. Regenerate bindings
make codegen

# 5. Update CHANGELOG (requires AI_MODELS_TOKEN)
AI_MODELS_TOKEN=xxx make update-changelog ARGS="--version v1.0.0"

# Or update CHANGELOG.md manually

# 6. Test and commit
make test
git add .
git commit -m "chore: update openmls to v1.0.0"
```

### Setting up AI Changelog

To enable AI-powered changelog generation in CI:

1. Create a Personal Access Token at https://github.com/settings/tokens
2. Required permission: **Models → Read only**
3. Add as repository secret: Settings → Secrets and variables → Actions → `AI_MODELS_TOKEN`

## Code Style

- Follow the [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style)
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Write tests for new functionality

## Commit Messages

Use clear, descriptive commit messages:

- `feat: Add new feature`
- `fix: Fix bug in XYZ`
- `docs: Update README`
- `test: Add tests for XYZ`
- `refactor: Improve code structure`

## Questions?

Feel free to open an issue for questions or discussions.
