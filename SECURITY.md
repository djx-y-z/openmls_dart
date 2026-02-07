# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in openmls, please report it responsibly:

1. **Do NOT** open a public GitHub issue for security vulnerabilities
2. Email the maintainers directly or use GitHub's private vulnerability reporting feature
3. Include as much detail as possible:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Security Measures

This package implements several security measures:

### Supply Chain Security

- **SHA256 Checksums**: All pre-built native libraries are verified against checksums before use
- **Signed Releases**: GitHub Releases include checksum files for verification
- **Dependency Auditing**: `cargo audit` is run in CI to detect known vulnerabilities in Rust dependencies

### Build Security

- **Reproducible Builds**: CI builds are automated and reproducible
- **Minimal Dependencies**: We keep dependencies minimal and well-audited
- **LTO and Stripping**: Release builds use Link-Time Optimization and symbol stripping

### Code Security

- **Memory Safety**: Core functionality is written in Rust, which provides memory safety guarantees
- **No Unsafe Code**: We avoid `unsafe` Rust code where possible
- **Static Analysis**: Both Dart (`dart analyze`) and Rust (`cargo clippy`) static analysis are run in CI

## Upstream Security

This package wraps openmls. For security issues in the underlying library:

- Check the upstream repository: [openmls/openmls](https://github.com/openmls/openmls)
- Security advisories may be published there first

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Development**: Depends on severity and complexity
- **Public Disclosure**: Coordinated with reporter after fix is available

## Security Updates

Subscribe to releases on this repository to receive notifications about security updates.
