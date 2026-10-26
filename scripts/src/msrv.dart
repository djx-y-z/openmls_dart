/// The minimum Rust version this package declares, and the one its resolved
/// dependency graph needs.
///
/// One source for the two places that ask: `make check-msrv`, which raises
/// the declared floor when an update needs it, and the CHANGELOG script, which
/// says so in the entry and keeps such an update from being merged unread.
library;

/// The highest `rust-version` a crate of the graph declares, and that crate as
/// `name version`.
typedef RustFloor = ({String version, String declaredBy});

/// A Rust version, `1.85` or `1.93.1`, as three numbers; null for anything
/// else.
List<int>? _parts(String version) {
  final match = RegExp(
    r'^(\d+)\.(\d+)(?:\.(\d+))?$',
  ).firstMatch(version.trim());
  if (match == null) return null;
  return [
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3] ?? '0'),
  ];
}

/// Whether [version] is a Rust version this module can compare.
bool isRustVersion(String version) => _parts(version) != null;

/// Compares two Rust versions of two parts or three: `1.85` is `1.85.0`, a
/// form `rust-version` allows and many crates write. Throws [FormatException]
/// on anything else. Pure; exposed for testing.
int compareRustVersions(String a, String b) {
  final left = _parts(a);
  final right = _parts(b);
  if (left == null) throw FormatException('not a Rust version', a);
  if (right == null) throw FormatException('not a Rust version', b);
  for (var i = 0; i < 3; i++) {
    final order = left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return 0;
}

final _packageRustVersion = RegExp(r'^rust-version\s*=\s*"([^"]*)"');

/// The `rust-version` of the `[package]` in [cargoToml], or null when it
/// declares none. Pure; exposed for testing.
String? rustVersionIn(String cargoToml) {
  var inPackage = false;
  for (final line in cargoToml.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('[')) {
      inPackage = trimmed == '[package]';
      continue;
    }
    if (!inPackage) continue;
    final match = _packageRustVersion.firstMatch(trimmed);
    if (match != null) return match[1];
  }
  return null;
}

/// [cargoToml] with the `[package]` `rust-version` set to [version]; unchanged
/// when it declares none. Pure; exposed for testing.
String withRustVersion(String cargoToml, String version) {
  var inPackage = false;
  final lines = cargoToml.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.startsWith('[')) {
      inPackage = trimmed == '[package]';
      continue;
    }
    if (inPackage && _packageRustVersion.hasMatch(trimmed)) {
      lines[i] = lines[i].replaceFirst(RegExp(r'"[^"]*"'), '"$version"');
      break;
    }
  }
  return lines.join('\n');
}

final _answer = RegExp(r'^rust_version:[ \t]*(.*)$', multiLine: true);

/// The `rust_version` answer in [answers], the text of `.copier-answers.yml`,
/// or null. Pure; exposed for testing.
String? rustVersionAnswerIn(String answers) => _answer
    .firstMatch(answers)?[1]
    ?.trim()
    .replaceAll(RegExp('^[\'"]|[\'"]\$'), '');

/// [answers] with `rust_version` set to [version]. Pure; exposed for testing.
///
/// The answer renders the manifest line, so a floor raised in the manifest
/// alone comes straight back on the next template update. A two-part version
/// is quoted, as copier writes it: bare, YAML reads `1.80` as the number 1.8.
String withRustVersionAnswer(String answers, String version) {
  final value = RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)
      ? version
      : "'$version'";
  return answers.replaceFirst(_answer, 'rust_version: $value');
}

/// A toolchain a document advertises: the rustup link, then `(<version>+)`.
final _advertised = RegExp(
  r'(\[Rust[^\]]*\]\(https://rustup\.rs/?\)\s*\()(\d+\.\d+(?:\.\d+)?)(\+\))',
);

/// The Rust version [doc] advertises next to its rustup link, or null when it
/// carries none. Pure; exposed for testing.
String? advertisedRustVersionIn(String doc) => _advertised.firstMatch(doc)?[2];

/// [doc] advertising [version] wherever it advertises one. Pure; exposed for
/// testing.
String withAdvertisedRustVersion(String doc, String version) =>
    doc.replaceAllMapped(_advertised, (m) => '${m[1]}$version${m[3]}');

/// The highest `rust-version` a package of the resolved graph declares, and
/// that package as `name version`, from `cargo metadata` output; null when
/// none declares one. Pure; exposed for testing.
///
/// The workspace's own crates are left out, since theirs is the floor being
/// checked. Everything else in the resolve counts, not only what ships:
/// `make build` compiles the build-dependencies and `make rust-test` the
/// dev-dependencies, so a contributor's toolchain needs their floor as well.
///
/// ⚠ This reads what crates DECLARE. A crate that uses a language feature
/// newer than its own floor is invisible here; the CI MSRV check, which builds
/// with exactly the declared version, stays the oracle for that.
RustFloor? floorOf(Map<String, dynamic> metadata) {
  final members = {
    for (final id in metadata['workspace_members'] as List? ?? const [])
      if (id is String) id,
  };
  RustFloor? floor;
  for (final package in metadata['packages'] as List? ?? const []) {
    if (package is! Map<String, dynamic>) continue;
    if (members.contains(package['id'])) continue;
    final version = package['rust_version'];
    if (version is! String || !isRustVersion(version)) continue;
    if (floor == null || compareRustVersions(version, floor.version) > 0) {
      floor = (
        version: version,
        declaredBy: '${package['name']} ${package['version']}',
      );
    }
  }
  return floor;
}

/// The sentence the CHANGELOG entry gains when the declared floor moved from
/// [before] to [after], naming the crate whose floor it is when [floor] is
/// what it moved to; empty when it did not move. Pure; exposed for testing.
String msrvSentenceFor(String? before, String? after, {RustFloor? floor}) {
  if (before == null || after == null || before == after) return '';
  final whose = floor != null && floor.version == after
      ? ', the floor `${floor.declaredBy}` declares'
      : '';
  return 'The minimum Rust version moves from $before to $after$whose.';
}
