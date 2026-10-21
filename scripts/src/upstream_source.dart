/// Where this project's upstream crates come from, and everything that
/// follows from it.
///
/// `upstream_source` in `.copier-answers.yml` names one of the classes below,
/// and each answers the same questions: how the pin reads in
/// `rust/Cargo.toml`, how a newer release is found, how a bump is written, and
/// which upstream commit a pin denotes. The scripts ask [upstreamSource] and
/// never the answer, so a source is added here — one class, its tests, and
/// its branch in the template's `macros/upstream.jinja` for the rendered files
/// — without touching the scripts that use it.
///
/// Every class is compiled into every generated project; only the constants
/// at the bottom are rendered from the answers. That is the point of the file.
/// The template's CI renders projects but compiles no Dart, so code Jinja
/// emitted for one source only would be compiled by no project using another,
/// and would break where nobody looks. Here every project's `make test`
/// exercises all of them.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'common.dart';

/// A version as SemVer writes it, with no prefix: `1.2.3`, `1.2.3-rc.1`.
///
/// Leading zeros are refused, and build metadata (`+…`) is not accepted:
/// neither orders, and a pin that does not order cannot be compared with the
/// next one.
const semverBody =
    r'(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)'
    r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?';

/// [semverBody], anchored.
final semverPattern = RegExp('^$semverBody\$');

/// A requirement this file writes on a crate that follows the primary one:
/// `X.Y.Z`, `X.Y` or `X` — Cargo's default caret range — or one of them after
/// `=`, which pins exactly.
final requirementPattern = RegExp(
  r'^=?(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)?)?$',
);

/// The newest upstream release, as a source reports it: its pin, whether it
/// is a pre-release, and a page about it.
typedef UpstreamRelease = ({String pin, bool isPrerelease, String page});

/// Everything a bump writes: the primary crate's new [pin], and the
/// requirement on each crate that follows it — empty for a source whose crates
/// all move with the one pin.
typedef UpstreamBump = ({String pin, Map<String, String> companions});

/// The upstream commit a pin denotes, as a ref the GitHub API accepts, and
/// whether the release was published from a tree with uncommitted changes —
/// in which case the commit is close to what shipped but not exactly it.
typedef UpstreamRevision = ({String ref, bool dirty});

/// An upstream crate this package builds, as `cargo metadata` resolves it: its
/// name, its version, and its directory inside the upstream repository
/// (`rust/protocol/`), which is what a compare file list is keyed on. An empty
/// [dir] is the repository root.
typedef UpstreamCrate = ({String name, String version, String dir});

/// What `cargo package` records about the commit a crate was published from:
/// `.cargo_vcs_info.json`, which every `.crate` built from a git checkout
/// carries.
typedef VcsInfo = ({String sha1, bool dirty, String pathInVcs});

/// Reads the [VcsInfo] of the crate unpacked in a directory, or null when it
/// has none. A function rather than a disk read so the rule that uses it is
/// testable without a registry cache.
typedef VcsInfoReader = VcsInfo? Function(String crateDir);

/// Where a release's own notes can be found, in the order a source tries them.
enum ReleaseNotesKind {
  /// The body of the GitHub release published for the pin's tag.
  githubRelease,

  /// `RELEASE_NOTES.md` at the pin's commit, which some upstreams overwrite
  /// every release instead of filling the GitHub release in.
  releaseNotesFile,

  /// The pin's section of `CHANGELOG.md` at its commit.
  changelogSection,
}

/// The fetches a source makes, behind an interface so every rule above them is
/// testable without a network.
abstract interface class UpstreamHttp {
  /// The body of a `GET` of a JSON API.
  Future<String> getJson(Uri url);

  /// The raw bytes of a `GET`.
  Future<Uint8List> getBytes(Uri url);
}

/// Where the upstream crates come from. See the library comment.
sealed class UpstreamSource {
  /// The source of [crates], all from the GitHub repository [repo].
  const UpstreamSource({required this.repo, required this.crates});

  /// The upstream GitHub repository, `owner/name` (`native_repo`).
  final String repo;

  /// The upstream crates, the primary one first (`upstream_crates`). Empty
  /// for a project that wraps no upstream crate and follows [repo]'s releases
  /// alone.
  final List<String> crates;

  /// The answer of `upstream_source` this class implements.
  String get kind;

  /// The crate whose version the pin records and the update check follows.
  String get primary {
    if (crates.isEmpty) {
      throw StateError(
        'This project wraps no upstream crate (upstream_crates is empty), so '
        'it has no upstream pin',
      );
    }
    return crates.first;
  }

  /// The crates that follow [primary].
  List<String> get companions => crates.isEmpty ? const [] : crates.sublist(1);

  /// Returns [raw] if it is a well-formed pin for this source, and throws a
  /// [FormatException] naming [origin] otherwise.
  ///
  /// Every pin is untrusted until it has been through here — one read from the
  /// API, typed into a workflow input, or recorded in `rust/Cargo.toml` alike
  /// — because pins reach `GITHUB_OUTPUT`, and from there workflow shell
  /// commands, branch names and API URLs. [origin] names which of them was
  /// refused: each fails for a different reason, and the fix differs.
  String validatePin(String raw, {required String origin});

  /// The primary crate's pin as [cargoToml] records it, validated.
  ///
  /// Throws a [FormatException] that says what was expected when there is
  /// none: a missing pin must never read as "no update needed".
  String pinFrom(String cargoToml);

  /// [pin] as a bare SemVer version, for ordering and display.
  String semverOf(String pin);

  /// The pin that denotes [version], a bare SemVer version — the inverse of
  /// [semverOf].
  String pinOf(String version);

  /// How `rust/Cargo.toml` declares [primary] at [pin], exactly as the
  /// template's `dependency` macro renders it — which is what [pinFrom] reads
  /// back.
  String declarationOf(String pin);

  /// Whether [pin] denotes a pre-release.
  bool isPrerelease(String pin) => semverOf(pin).contains('-');

  /// How [pin] is spelled where documentation quotes the dependency line, so
  /// a bump can replace it there too.
  String pinLiteral(String pin);

  /// A page about the release [pin] names, and what to call a link to it.
  ({String label, String url}) pageFor(String pin);

  /// Looks up the newest stable upstream release.
  Future<UpstreamRelease> fetchLatest(UpstreamHttp http);

  /// Works out everything a bump to [pin] writes.
  Future<UpstreamBump> planBump(String pin, UpstreamHttp http);

  /// [cargoToml] with every upstream dependency moved to [bump].
  String rewriteCargoToml(String cargoToml, UpstreamBump bump);

  /// [answers], the text of `.copier-answers.yml`, with the answers that
  /// record the pins moved to [bump] — so the next `copier update` renders the
  /// dependency lines this project already has.
  String rewriteAnswers(String answers, UpstreamBump bump);

  /// The upstream commit [pin] denotes.
  Future<UpstreamRevision> revisionOf(String pin, UpstreamHttp http);

  /// Where to look for a release's notes, in order.
  List<ReleaseNotesKind> get releaseNotesKinds;

  /// The upstream crates in a decoded `cargo metadata` document.
  ///
  /// Read from the resolved graph rather than from [crates], because the
  /// answers name only what this package depends on directly, and a crate
  /// they pull in from the same repository is in the graph all the same. A
  /// crate whose directory upstream cannot be read is left out rather than
  /// guessed. [vcsInfo] reads what a registry crate records about where it
  /// came from.
  List<UpstreamCrate> cratesIn(
    Map<String, dynamic> metadata, {
    required VcsInfoReader vcsInfo,
  });
}

/// The upstream crates are a git dependency on [repo], pinned by tag; new
/// releases are found through the repository's GitHub Releases.
final class GitTagSource extends UpstreamSource {
  /// The source of [crates] at tags of [repo] that start with [tagPrefix].
  const GitTagSource({
    required super.repo,
    required super.crates,
    required this.tagPrefix,
  });

  /// What every upstream release tag starts with (`version_tag_prefix`).
  final String tagPrefix;

  @override
  String get kind => 'git_tag';

  /// `<tagPrefix>X.Y.Z`, built from [tagPrefix] rather than hardcoded: an
  /// upstream that uses a prefix other than `v` must still validate its own
  /// tags, and a hardcoded `v?` silently rejects every one of them.
  RegExp get _tagPattern => RegExp('^${RegExp.escape(tagPrefix)}$semverBody\$');

  @override
  String validatePin(String raw, {required String origin}) {
    if (!_tagPattern.hasMatch(raw)) {
      throw FormatException('Refusing unexpected $origin format: "$raw"');
    }
    return raw;
  }

  /// Anchored, and the inline table may not span lines, because the first
  /// match in the file is taken. Unanchored it reads a commented-out pin — the
  /// shape an upgrade leaves behind — in preference to the real one below it.
  /// The dangerous direction is a comment naming a *newer* tag: the update
  /// check then reports the dependency as already current, and an upstream
  /// release, security fixes included, silently never lands.
  @override
  String pinFrom(String cargoToml) {
    final tag = RegExp(
      '^\\s*${RegExp.escape(primary)}\\s*=\\s*\\{[^}\\n]*tag\\s*=\\s*"([^"]+)"',
      multiLine: true,
    ).firstMatch(cargoToml)?.group(1)?.trim();
    if (tag == null) {
      throw FormatException(
        '$primary tag not found in rust/Cargo.toml. Expected format: '
        '$primary = { git = "...", tag = "${tagPrefix}X.Y.Z" }',
      );
    }
    return validatePin(tag, origin: 'tag recorded in rust/Cargo.toml');
  }

  /// Strips [tagPrefix], falling back to a bare `v`/`V` for a tag that does
  /// not carry it. Must stay in step with `version` in the template's
  /// `macros/upstream.jinja`, which renders the README badge this rewrites.
  @override
  String semverOf(String pin) {
    if (tagPrefix.isNotEmpty && pin.startsWith(tagPrefix)) {
      return pin.substring(tagPrefix.length);
    }
    if (pin.startsWith('v') || pin.startsWith('V')) return pin.substring(1);
    return pin;
  }

  @override
  String pinOf(String version) => '$tagPrefix$version';

  @override
  String declarationOf(String pin) =>
      '$primary = { git = "https://github.com/$repo", tag = "$pin" }';

  @override
  String pinLiteral(String pin) => 'tag = "$pin"';

  @override
  ({String label, String url}) pageFor(String pin) => (
    label: 'release notes',
    url: 'https://github.com/$repo/releases/tag/$pin',
  );

  @override
  Future<UpstreamRelease> fetchLatest(UpstreamHttp http) async {
    final release =
        jsonDecode(
              await http.getJson(
                Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
              ),
            )
            as Map<String, dynamic>;
    final tag = release['tag_name'];
    if (tag is! String) {
      throw FormatException(
        'GitHub returned no tag_name for the latest release of $repo',
      );
    }
    // Attacker-controlled upstream data, bound for GITHUB_OUTPUT.
    final pin = validatePin(tag, origin: 'tag_name from the GitHub API');
    return (
      pin: pin,
      isPrerelease: release['prerelease'] as bool? ?? false,
      page:
          release['html_url'] as String? ?? 'https://github.com/$repo/releases',
    );
  }

  /// Every upstream crate moves with the one tag, so a bump is the tag alone.
  @override
  Future<UpstreamBump> planBump(String pin, UpstreamHttp http) async => (
    pin: validatePin(pin, origin: 'target tag'),
    companions: const <String, String>{},
  );

  @override
  String rewriteCargoToml(String cargoToml, UpstreamBump bump) {
    var out = cargoToml;
    for (final crate in crates) {
      out = out.replaceAllMapped(
        RegExp(
          '^(\\s*${RegExp.escape(crate)}\\s*=\\s*\\{[^}\\n]*\\btag\\s*=\\s*")'
          r'[^"\n]*(")',
          multiLine: true,
        ),
        (m) => '${m.group(1)}${bump.pin}${m.group(2)}',
      );
    }
    return out;
  }

  @override
  String rewriteAnswers(String answers, UpstreamBump bump) =>
      replaceAnswer(answers, 'upstream_version', bump.pin) ?? answers;

  /// A tag is a ref the GitHub API accepts as it is.
  @override
  Future<UpstreamRevision> revisionOf(String pin, UpstreamHttp http) async =>
      (ref: validatePin(pin, origin: 'tag'), dirty: false);

  @override
  List<ReleaseNotesKind> get releaseNotesKinds => const [
    ReleaseNotesKind.githubRelease,
    ReleaseNotesKind.releaseNotesFile,
  ];

  /// The git packages from [repo]. Their directory upstream is where `cargo
  /// metadata` reports the manifest inside the checkout,
  /// `<CARGO_HOME>/git/checkouts/<repo>-<hash>/<short rev>/<dir>/Cargo.toml`.
  @override
  List<UpstreamCrate> cratesIn(
    Map<String, dynamic> metadata, {
    required VcsInfoReader vcsInfo,
  }) {
    final fromRepo = RegExp(
      '^git\\+https://github\\.com/${RegExp.escape(repo)}'
      r'(?:\.git)?(?:[?#]|$)',
      caseSensitive: false,
    );
    final checkoutManifest = RegExp(
      r'/git/checkouts/[^/]+/[^/]+/(.*)Cargo\.toml$',
    );
    return [
      for (final package in _packagesOf(metadata))
        if (fromRepo.hasMatch(package.source))
          if (checkoutManifest
                  .firstMatch(package.manifest.replaceAll(r'\', '/'))
                  ?.group(1)
              case final dir?)
            (name: package.name, version: package.version, dir: dir),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }
}

/// The upstream crates come from the crates.io registry; new releases are
/// found there, whatever the upstream repository names its tags or whether it
/// publishes GitHub releases at all.
final class CratesIoSource extends UpstreamSource {
  /// The source of [crates], published to crates.io from [repo].
  const CratesIoSource({required super.repo, required super.crates});

  static const _api = 'https://crates.io/api/v1/crates';

  /// How `cargo metadata` names the crates.io index as a package source.
  static const _registry =
      'registry+https://github.com/rust-lang/crates.io-index';

  @override
  String get kind => 'crates_io';

  @override
  String validatePin(String raw, {required String origin}) {
    if (!semverPattern.hasMatch(raw)) {
      throw FormatException(
        'Refusing unexpected $origin format: "$raw" (expected X.Y.Z, the '
        'exact crates.io version of $primary)',
      );
    }
    return raw;
  }

  /// Every declaration of [crate] as a dependency: `crate = "req"`, or
  /// `crate = { …, version = "req", … }`, on a line of its own — anchored,
  /// like [GitTagSource.pinFrom], so a commented-out declaration is never
  /// read. Group 2 is a bare requirement; 3, 4 and 5 are a table's text before
  /// the requirement, the requirement, and the rest of the table.
  ///
  /// Inline declarations only, which is what the template writes. A crate
  /// declared as a `[dependencies.<crate>]` table, or renamed with `package =`,
  /// is not seen — and if that leaves the primary crate with no declaration at
  /// all, [pinFrom] says so instead of guessing.
  static RegExp _declaration(String crate) => RegExp(
    '^(\\s*${RegExp.escape(crate)}\\s*=\\s*)'
    r'(?:"([^"\n]*)"|(\{[^}\n]*\bversion\s*=\s*)"([^"\n]*)"([^}\n]*\}))',
    multiLine: true,
  );

  /// The primary crate's exact version. Every declaration counts — a target
  /// table declares the crate again, with its own features — and they must
  /// agree, because Cargo resolves one version for all of them and a pin that
  /// read only the first would describe a build that is not happening.
  ///
  /// A declaration of any upstream crate that still names a git repository or
  /// a path is refused first: it is what a change of source leaves half done —
  /// the registry in one table, git in a target table — and every other
  /// declaration would read as a clean pin while Cargo built something else.
  @override
  String pinFrom(String cargoToml) {
    for (final crate in crates) {
      final stray = RegExp(
        '^\\s*${RegExp.escape(crate)}\\s*=\\s*\\{[^}\\n]*\\b(?:git|path)\\s*=',
        multiLine: true,
      ).firstMatch(cargoToml);
      if (stray != null) {
        throw FormatException(
          '$crate is still declared from git or a path in rust/Cargo.toml '
          '(${stray.group(0)!.trim()}...); with upstream_source=crates_io every '
          'declaration of an upstream crate must come from the registry',
        );
      }
    }
    final requirements = {
      for (final m in _declaration(primary).allMatches(cargoToml))
        (m.group(2) ?? m.group(4)!).trim(),
    };
    if (requirements.isEmpty) {
      throw FormatException(
        '$primary is not declared with a version in rust/Cargo.toml. Expected '
        'format: $primary = "=X.Y.Z", or $primary = { version = "=X.Y.Z", ... }',
      );
    }
    if (requirements.length > 1) {
      throw FormatException(
        '$primary is declared with different versions in rust/Cargo.toml '
        '(${requirements.join(', ')}); every declaration, each target table '
        'included, must pin the same one',
      );
    }
    final requirement = requirements.single;
    if (!requirement.startsWith('=')) {
      throw FormatException(
        '$primary must be pinned exactly in rust/Cargo.toml ("=X.Y.Z"), but '
        'it reads "$requirement": with a range, Cargo.lock decides which '
        'release is built, and the update check would compare against a '
        'version nothing builds',
      );
    }
    return validatePin(
      requirement.substring(1).trim(),
      origin: 'version recorded in rust/Cargo.toml',
    );
  }

  @override
  String semverOf(String pin) => pin;

  @override
  String pinOf(String version) => version;

  @override
  String declarationOf(String pin) => '$primary = "=$pin"';

  @override
  String pinLiteral(String pin) => '"=$pin"';

  @override
  ({String label, String url}) pageFor(String pin) =>
      (label: 'crates.io', url: 'https://crates.io/crates/$primary/$pin');

  /// The highest stable version crates.io reports, refused if it is yanked —
  /// a yanked release is one its own publisher withdrew.
  @override
  Future<UpstreamRelease> fetchLatest(UpstreamHttp http) async {
    final json = _object(
      await http.getJson(Uri.parse('$_api/$primary')),
      what: 'the crates.io record of $primary',
    );
    final crate = json['crate'];
    if (crate is! Map<String, dynamic>) {
      throw FormatException(
        'crates.io returned no crate record for $primary: '
        '${json['errors'] ?? 'unrecognised response'}',
      );
    }
    final stable = crate['max_stable_version'];
    final newest = stable is String ? stable : crate['max_version'];
    if (newest is! String) {
      throw FormatException('crates.io names no version of $primary');
    }
    // Attacker-controlled upstream data, bound for GITHUB_OUTPUT.
    final pin = validatePin(newest, origin: 'version from the crates.io API');
    await _published(pin, http);
    return (pin: pin, isPrerelease: isPrerelease(pin), page: pageFor(pin).url);
  }

  /// The primary crate at [pin], and each crate that follows it at the
  /// requirement [pin]'s release itself declares — taken from crates.io, not
  /// guessed, because a workspace's crates are versioned independently and
  /// only the primary crate knows which of theirs it was released against.
  ///
  /// A crate the primary does not depend on is left where it is.
  @override
  Future<UpstreamBump> planBump(String pin, UpstreamHttp http) async {
    validatePin(pin, origin: 'target version');
    await _published(pin, http);
    if (companions.isEmpty)
      return (pin: pin, companions: const <String, String>{});

    final json = _object(
      await http.getJson(Uri.parse('$_api/$primary/$pin/dependencies')),
      what: 'the dependencies of $primary $pin',
    );
    final dependencies = json['dependencies'];
    if (dependencies is! List) {
      throw FormatException(
        'crates.io returned no dependency list for $primary $pin',
      );
    }
    final requirements = companionRequirements(
      dependencies,
      companions: companions,
      release: '$primary $pin',
    );
    for (final crate in companions) {
      if (!requirements.containsKey(crate)) {
        logWarn(
          '$primary $pin does not depend on $crate, so its requirement is '
          'left as it is; move it by hand if this release needs it to',
        );
      }
    }
    return (pin: pin, companions: requirements);
  }

  /// Refuses a [pin] crates.io does not serve, or serves yanked.
  Future<void> _published(String pin, UpstreamHttp http) async {
    final json = _object(
      await http.getJson(Uri.parse('$_api/$primary/$pin')),
      what: 'the crates.io record of $primary $pin',
    );
    final version = json['version'];
    if (version is! Map<String, dynamic>) {
      throw FormatException(
        'crates.io has no $primary $pin: '
        '${json['errors'] ?? 'unrecognised response'}',
      );
    }
    if (version['yanked'] == true) {
      throw FormatException(
        '$primary $pin is yanked on crates.io; refusing to pin a release its '
        'publisher withdrew',
      );
    }
  }

  @override
  String rewriteCargoToml(String cargoToml, UpstreamBump bump) {
    var out = _rewrite(cargoToml, primary, '=${bump.pin}');
    for (final MapEntry(key: crate, value: requirement)
        in bump.companions.entries) {
      out = _rewrite(out, crate, requirement);
    }
    return out;
  }

  static String _rewrite(String toml, String crate, String requirement) =>
      toml.replaceAllMapped(
        _declaration(crate),
        (m) => m.group(2) != null
            ? '${m.group(1)}"$requirement"'
            : '${m.group(1)}${m.group(3)}"$requirement"${m.group(5)}',
      );

  /// Moves `upstream_version` to the pin, and every crate in the bump within
  /// `upstream_crate_versions` — written in [companions] order, each crate the
  /// bump left alone keeping what it had.
  @override
  String rewriteAnswers(String answers, UpstreamBump bump) {
    final out = replaceAnswer(answers, 'upstream_version', bump.pin) ?? answers;
    if (bump.companions.isEmpty) return out;
    final current = readAnswer(out, 'upstream_crate_versions');
    if (current == null) {
      logWarn(
        '.copier-answers.yml has no upstream_crate_versions, so it still '
        'renders the old requirements; rust/Cargo.toml was updated',
      );
      return out;
    }
    final recorded = parseCrateRequirements(current);
    final merged = [
      for (final crate in companions)
        if (bump.companions[crate] ?? recorded[crate] case final requirement?)
          '$crate=$requirement',
    ].join(',');
    return replaceAnswer(out, 'upstream_crate_versions', merged) ?? out;
  }

  /// The commit `cargo package` recorded in the published `.crate`.
  ///
  /// crates.io's API does not carry it, and the upstream's tags cannot be
  /// trusted to name it — which tag scheme an upstream uses is exactly what
  /// this source exists not to depend on. Read from static.crates.io over
  /// HTTPS; only the commit id and directory are kept, both validated, and
  /// both are used to address the GitHub API, never to build anything.
  @override
  Future<UpstreamRevision> revisionOf(String pin, UpstreamHttp http) async {
    validatePin(pin, origin: 'version');
    final archive = await http.getBytes(
      Uri.parse('https://static.crates.io/crates/$primary/$primary-$pin.crate'),
    );
    final info = vcsInfoFromCrate(archive, crate: primary, version: pin);
    if (info == null) {
      throw FormatException(
        '$primary $pin was published without .cargo_vcs_info.json, so no '
        'upstream commit can be named for it',
      );
    }
    return (ref: info.sha1, dirty: info.dirty);
  }

  /// crates.io carries no release notes, so they are looked for in the
  /// repository itself, at the release's commit.
  @override
  List<ReleaseNotesKind> get releaseNotesKinds => const [
    ReleaseNotesKind.releaseNotesFile,
    ReleaseNotesKind.changelogSection,
  ];

  /// The registry packages published from [repo]: the `repository` their
  /// manifest declares is [repo], and their directory upstream is the
  /// `path_in_vcs` they record.
  @override
  List<UpstreamCrate> cratesIn(
    Map<String, dynamic> metadata, {
    required VcsInfoReader vcsInfo,
  }) {
    final crates = <UpstreamCrate>[];
    for (final package in _packagesOf(metadata)) {
      if (package.source != _registry || !_isRepo(package.repository)) {
        continue;
      }
      final manifest = package.manifest.replaceAll(r'\', '/');
      final dir = manifest.substring(0, manifest.lastIndexOf('/') + 1);
      final info = vcsInfo(dir);
      if (info == null) continue;
      final path = info.pathInVcs;
      crates.add((
        name: package.name,
        version: package.version,
        dir: path.isEmpty || path.endsWith('/') ? path : '$path/',
      ));
    }
    return crates..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Whether [url], a manifest's `repository`, is [repo] on GitHub — the
  /// repository itself, or a directory or file in it.
  ///
  /// A workspace's member crates commonly point at their own directory
  /// (`https://github.com/<repo>/tree/main/traits`); taking only the bare
  /// repository would recognise the primary crate and leave every other
  /// upstream crate to be listed as a third-party one. Anchored after the name,
  /// so a repository whose name merely starts the same is not taken for it.
  bool _isRepo(String? url) =>
      url != null &&
      RegExp(
        '^https?://github\\.com/${RegExp.escape(repo)}'
        r'(?:\.git)?(?:/(?:tree|blob)/[^?#\s]*)?/?$',
        caseSensitive: false,
      ).hasMatch(url.trim());
}

/// The requirement [release] declares on each of [companions], out of its
/// crates.io dependency list, in the form `rust/Cargo.toml` writes it.
///
/// Only normal dependencies count — a dev-dependency says nothing about what
/// the release was built against. A crate it declares more than once (per
/// target) must be declared alike; a crate it does not declare is left out of
/// the result, and so stays at whatever requirement it has. Pure; exposed for
/// testing.
Map<String, String> companionRequirements(
  List<Object?> dependencies, {
  required List<String> companions,
  required String release,
}) {
  final out = <String, String>{};
  for (final crate in companions) {
    final declared = {
      for (final dependency in dependencies)
        if (dependency is Map<String, dynamic> &&
            dependency['crate_id'] == crate &&
            dependency['kind'] == 'normal' &&
            dependency['req'] is String)
          dependency['req'] as String,
    };
    if (declared.isEmpty) continue;
    if (declared.length > 1) {
      throw FormatException(
        '$release declares $crate more than once, differently '
        '(${declared.join(', ')}); update it by hand',
      );
    }
    out[crate] = requirementFrom(declared.single);
  }
  return out;
}

/// [declared], a requirement as crates.io reports it (`^0.6.0`, `=0.6.0`), as
/// `rust/Cargo.toml` writes it (`0.6.0`, `=0.6.0`).
///
/// Anything but a single version is refused rather than approximated: a
/// `>=0.6, <0.8` written back as one version would quietly narrow what the
/// release allows. Pure; exposed for testing.
String requirementFrom(String declared) {
  final trimmed = declared.trim();
  final written = trimmed.startsWith('^')
      ? trimmed.substring(1).trim()
      : trimmed;
  if (!requirementPattern.hasMatch(written)) {
    throw FormatException(
      'Unsupported version requirement "$declared": only a single version, '
      'as a caret or an exact requirement, can be followed automatically',
    );
  }
  return written;
}

/// `crate=X.Y.Z,crate2=X.Y.Z`, the form of `upstream_crate_versions`, as a
/// map. Pure; exposed for testing.
Map<String, String> parseCrateRequirements(String value) => {
  for (final entry in value.split(','))
    if (entry.trim().isNotEmpty && entry.contains('='))
      entry.substring(0, entry.indexOf('=')).trim(): entry
          .substring(entry.indexOf('=') + 1)
          .trim(),
};

/// The value of [key] in [answers], the text of `.copier-answers.yml`, or
/// null when the key is absent. Pure; exposed for testing.
String? readAnswer(String answers, String key) =>
    _answerLine(key).firstMatch(answers)?.group(3);

/// [answers] with the value of [key] replaced by [value], keeping the quoting
/// it had — double, single, or none — or null when the key is absent, so the
/// caller can tell "unchanged" from "nothing to change". Pure; exposed for
/// testing.
String? replaceAnswer(String answers, String key, String value) {
  final pattern = _answerLine(key);
  if (!pattern.hasMatch(answers)) return null;
  return answers.replaceFirstMapped(pattern, (m) {
    final quote = m.group(2) ?? '';
    return '${m.group(1)}$quote$value$quote';
  });
}

/// One `key: value` line of an answers file, anchored so a key that merely
/// ends in [key] is not taken for it. Groups: the text before the value, the
/// quote, the value.
RegExp _answerLine(String key) => RegExp(
  '^(${RegExp.escape(key)}:[ \\t]*)(["\']?)([^"\'\\s]+)\\2',
  multiLine: true,
);

/// The fields of each package in a decoded `cargo metadata` document that
/// [UpstreamSource.cratesIn] reads, skipping any that lacks one.
Iterable<
  ({
    String name,
    String version,
    String source,
    String manifest,
    String? repository,
  })
>
_packagesOf(Map<String, dynamic> metadata) sync* {
  final packages = metadata['packages'];
  if (packages is! List) return;
  for (final package in packages) {
    if (package is! Map<String, dynamic>) continue;
    final name = package['name'];
    final version = package['version'];
    final source = package['source'];
    final manifest = package['manifest_path'];
    if (name is! String ||
        version is! String ||
        source is! String ||
        manifest is! String) {
      continue;
    }
    final repository = package['repository'];
    yield (
      name: name,
      version: version,
      source: source,
      manifest: manifest,
      repository: repository is String ? repository : null,
    );
  }
}

/// [body] decoded as a JSON object, or a [FormatException] naming [what].
Map<String, dynamic> _object(String body, {required String what}) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('Expected a JSON object for $what');
  }
  return decoded;
}

/// The [VcsInfo] inside [crateBytes], the `.crate` archive of [crate]
/// [version], or null when it carries none — a crate packaged outside a git
/// checkout has no `.cargo_vcs_info.json`. Pure; exposed for testing.
VcsInfo? vcsInfoFromCrate(
  Uint8List crateBytes, {
  required String crate,
  required String version,
}) {
  final tar = Uint8List.fromList(gzip.decode(crateBytes));
  final entry = tarEntry(tar, '$crate-$version/.cargo_vcs_info.json');
  return entry == null ? null : vcsInfoFrom(utf8.decode(entry));
}

/// Parses a `.cargo_vcs_info.json`.
///
/// Strict, because both fields end up in GitHub API URLs: the commit must be a
/// full hexadecimal object id (SHA-1, or SHA-256 for a repository using it),
/// and the directory a relative path that does not climb out of the
/// repository. Pure; exposed for testing.
VcsInfo vcsInfoFrom(String json) {
  final decoded = jsonDecode(json);
  final git = decoded is Map<String, dynamic> ? decoded['git'] : null;
  final sha1 = git is Map<String, dynamic> ? git['sha1'] : null;
  if (sha1 is! String ||
      !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(sha1)) {
    throw FormatException('.cargo_vcs_info.json names no commit id: $json');
  }
  final path = (decoded as Map<String, dynamic>)['path_in_vcs'] ?? '';
  if (path is! String ||
      path.startsWith('/') ||
      path.split('/').contains('..') ||
      !RegExp(r'^[A-Za-z0-9._/-]*$').hasMatch(path)) {
    throw FormatException(
      '.cargo_vcs_info.json names an unusable path_in_vcs: $json',
    );
  }
  return (
    sha1: sha1,
    dirty: (git as Map<String, dynamic>)['dirty'] == true,
    pathInVcs: path,
  );
}

/// The contents of the regular file [path] in the tar archive [tar], or null
/// when it holds none.
///
/// Reads what `cargo package` writes: ustar or GNU headers, with a pax
/// extended header or a GNU long-name record standing in for a path longer
/// than the header's 100 bytes. Written here because these scripts depend on
/// nothing outside the SDK — the update check runs on a fresh checkout before
/// `pub get` — and the SDK reads gzip but not tar. Pure; exposed for testing.
Uint8List? tarEntry(Uint8List tar, String path) {
  var offset = 0;
  String? longName;
  while (offset + 512 <= tar.length) {
    final header = Uint8List.sublistView(tar, offset, offset + 512);
    if (header.every((byte) => byte == 0)) return null;
    final size = _octal(header, 124, 12);
    final type = header[156];
    final start = offset + 512;
    if (start + size > tar.length) {
      throw const FormatException('Truncated tar archive');
    }
    final data = Uint8List.sublistView(tar, start, start + size);
    offset = start + (size + 511) ~/ 512 * 512;

    switch (type) {
      case 0x78: // 'x': pax extended header for the next entry
        longName = _paxPath(data) ?? longName;
        continue;
      case 0x67: // 'g': pax global header
        continue;
      case 0x4c: // 'L': GNU long name for the next entry
        longName = _cString(data, 0, data.length);
        continue;
    }
    final name = longName ?? _ustarName(header);
    longName = null;
    // '0' and the pre-POSIX NUL both mean a regular file.
    if ((type == 0x30 || type == 0) && name == path) return data;
  }
  return null;
}

/// The path a ustar header names: the POSIX `prefix` field, when the header
/// is POSIX ustar, joined to `name`. GNU headers keep other data in that
/// field, so it is read only after the POSIX magic.
String _ustarName(Uint8List header) {
  final name = _cString(header, 0, 100);
  final posix = _cString(header, 257, 6) == 'ustar';
  final prefix = posix ? _cString(header, 345, 155) : '';
  return prefix.isEmpty ? name : '$prefix/$name';
}

/// The `path` record of a pax extended header, or null when it has none.
/// Records read `<length> <key>=<value>\n`.
String? _paxPath(Uint8List data) {
  for (final record in utf8.decode(data, allowMalformed: true).split('\n')) {
    final space = record.indexOf(' ');
    if (space < 0) continue;
    final field = record.substring(space + 1);
    if (field.startsWith('path=')) return field.substring('path='.length);
  }
  return null;
}

/// The NUL-terminated ASCII string of at most [length] bytes at [start].
String _cString(Uint8List bytes, int start, int length) {
  var end = start;
  while (end < start + length && end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return latin1.decode(Uint8List.sublistView(bytes, start, end));
}

/// The octal number in the [length] bytes at [start], as tar headers write
/// sizes. The base-256 form tar uses past 8 GiB is refused: no crate is that
/// large, and a header claiming it is not one to trust.
int _octal(Uint8List bytes, int start, int length) {
  if (bytes[start] & 0x80 != 0) {
    throw const FormatException('Unsupported tar size encoding');
  }
  final digits = _cString(bytes, start, length).trim();
  if (digits.isEmpty) return 0;
  final value = int.tryParse(digits, radix: 8);
  if (value == null) {
    throw FormatException('Malformed tar size field: "$digits"');
  }
  return value;
}

/// Thrown by [NetworkUpstreamHttp] for any response other than 200 from a host
/// other than the GitHub API, which [githubApiGet] diagnoses itself.
class UpstreamHttpException implements Exception {
  /// A failed request for [url], answered with [statusCode] and [body].
  UpstreamHttpException(this.url, this.statusCode, this.body);

  /// What was requested.
  final Uri url;

  /// What the server answered.
  final int statusCode;

  /// The start of the response body, for the diagnosis.
  final String body;

  @override
  String toString() => 'GET $url answered $statusCode: $body';
}

/// [UpstreamHttp] over the network.
///
/// The GitHub API goes through [githubApiGet], which authenticates whenever a
/// token is available — for quota, not access. Everything else is sent with
/// [userAgent], which names this repository: crates.io refuses requests that
/// do not say who is asking, and a repository URL says it without naming a
/// person.
final class NetworkUpstreamHttp implements UpstreamHttp {
  /// Requests identified by [userAgent].
  const NetworkUpstreamHttp({required this.userAgent});

  /// What every request is identified by.
  final String userAgent;

  @override
  Future<String> getJson(Uri url) async {
    if (url.host == 'api.github.com') {
      return githubApiGet(
        url,
        accept: 'application/vnd.github.v3+json',
        userAgent: userAgent,
      );
    }
    return utf8.decode(
      await _get(url, accept: 'application/json'),
      allowMalformed: true,
    );
  }

  @override
  Future<Uint8List> getBytes(Uri url) => _get(url, accept: '*/*');

  Future<Uint8List> _get(Uri url, {required String accept}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(url);
      request.headers
        ..set('Accept', accept)
        ..set('User-Agent', userAgent);
      final response = await request.close();
      final body = BytesBuilder(copy: false);
      await response.forEach(body.add);
      final bytes = body.takeBytes();
      if (response.statusCode != 200) {
        final start = bytes.length > 500
            ? Uint8List.sublistView(bytes, 0, 500)
            : bytes;
        throw UpstreamHttpException(
          url,
          response.statusCode,
          utf8.decode(start, allowMalformed: true),
        );
      }
      return bytes;
    } finally {
      client.close();
    }
  }
}

/// Builds the source [kind] names. Throws for a kind this file does not know,
/// which is what an answers file newer than this checkout looks like.
UpstreamSource upstreamSourceFor({
  required String kind,
  required String repo,
  required List<String> crates,
  required String tagPrefix,
}) => switch (kind) {
  'git_tag' => GitTagSource(repo: repo, crates: crates, tagPrefix: tagPrefix),
  'crates_io' => CratesIoSource(repo: repo, crates: crates),
  _ => throw ArgumentError.value(kind, 'upstream_source', 'Unknown source'),
};

/// The upstream pin recorded in `rust/Cargo.toml`, validated: the tag or the
/// crates.io version, whichever [upstreamSource] pins by.
String getUpstreamVersion() {
  final cargo = File('${getPackageDir().path}/rust/Cargo.toml');
  if (!cargo.existsSync()) {
    throw Exception('rust/Cargo.toml not found');
  }
  return upstreamSource.pinFrom(cargo.readAsStringSync());
}

// ---------------------------------------------------------------------------
// The only part of this file rendered from the answers.
// ---------------------------------------------------------------------------

/// The answer of `upstream_source` this project was generated with.
const upstreamSourceKind = 'crates_io';

/// What every request [upstreamHttp] makes is identified by.
const upstreamUserAgent =
    'openmls-update-checker (https://github.com/djx-y-z/openmls_dart)';

/// The fetches the scripts make.
const UpstreamHttp upstreamHttp = NetworkUpstreamHttp(
  userAgent: upstreamUserAgent,
);

/// Where this project's upstream crates come from.
final UpstreamSource upstreamSource = upstreamSourceFor(
  kind: upstreamSourceKind,
  repo: 'openmls/openmls',
  crates: const [
    'openmls',
    'openmls_rust_crypto',
    'openmls_basic_credential',
    'openmls_traits',
    'openmls_libcrux_crypto',
  ],
  tagPrefix: 'v',
);
