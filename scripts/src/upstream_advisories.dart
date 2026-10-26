// The upstream repository's published security advisories, held against the
// crates rust/Cargo.lock resolves.
//
// Nothing else here reads them. `make rust-audit` and `make rust-deny` read
// the RustSec database, and Dependabot reads GitHub's global advisory
// database, which takes only what GitHub has reviewed. An upstream that
// publishes its advisories in its own repository reaches neither of them
// until someone files them there: measured 2026-10-21 on one upstream, three
// of the five advisories it had published answered 404 from the global
// endpoint, its most recent high-severity one among them, and RustSec had
// none. The repository's own list is the one place that has them all, so that
// is what this reads.
//
// What it does not cover: advisories filed anywhere but the upstream
// repository (RustSec stays `rust-audit`'s), crates the upstream does not
// publish, and drafts — only `state=published` is ever asked for, so nothing
// an upstream has not disclosed can reach a public CI log.
library;

import 'dart:convert';

import 'common.dart';
import 'upstream_source.dart';

/// The ecosystem GitHub names crates.io packages by in an advisory.
const advisoryEcosystem = 'rust';

/// One package a published advisory names, and the versions it covers.
class AdvisoryVulnerability {
  /// The [package] of [ecosystem] in the versions [range] covers.
  const AdvisoryVulnerability({
    required this.ecosystem,
    required this.package,
    required this.range,
    required this.patched,
  });

  /// The package registry, `rust` for crates.io.
  final String ecosystem;

  /// The package name as the advisory writes it.
  final String package;

  /// `vulnerable_version_range` as GitHub writes it: `< 0.8.2`, a bare `0.9.0`
  /// for exactly that version, or comma-separated constraints that must all
  /// hold.
  final String range;

  /// `patched_versions`, empty when there is no fixed release.
  final String patched;
}

/// A published repository security advisory, as far as this check reads it.
class UpstreamAdvisory {
  /// An advisory [ghsaId] covering [vulnerabilities].
  const UpstreamAdvisory({
    required this.ghsaId,
    required this.summary,
    required this.severity,
    required this.url,
    required this.withdrawn,
    required this.vulnerabilities,
  });

  /// One element of `GET /repos/{owner}/{repo}/security-advisories`.
  factory UpstreamAdvisory.fromJson(Map<String, dynamic> json) {
    final vulnerabilities = <AdvisoryVulnerability>[];
    for (final entry in (json['vulnerabilities'] as List<dynamic>?) ?? []) {
      final v = entry as Map<String, dynamic>;
      final package = (v['package'] as Map<String, dynamic>?) ?? const {};
      vulnerabilities.add(
        AdvisoryVulnerability(
          ecosystem: (package['ecosystem'] as String?) ?? '',
          package: (package['name'] as String?) ?? '',
          range: (v['vulnerable_version_range'] as String?) ?? '',
          patched: (v['patched_versions'] as String?) ?? '',
        ),
      );
    }
    return UpstreamAdvisory(
      ghsaId: (json['ghsa_id'] as String?) ?? '',
      summary: (json['summary'] as String?) ?? '',
      severity: (json['severity'] as String?) ?? 'unknown',
      url: (json['html_url'] as String?) ?? '',
      withdrawn: json['withdrawn_at'] != null,
      vulnerabilities: vulnerabilities,
    );
  }

  /// `GHSA-xxxx-xxxx-xxxx`.
  final String ghsaId;

  /// The advisory's one-line title.
  final String summary;

  /// `low`, `medium`, `high` or `critical`.
  final String severity;

  /// The advisory's page.
  final String url;

  /// Whether upstream withdrew it, in which case it covers nothing.
  final bool withdrawn;

  /// What it covers.
  final List<AdvisoryVulnerability> vulnerabilities;
}

/// A locked crate version an advisory covers, or might: [rangeUnparsed] says
/// the range could not be read, which counts as covered rather than as clean.
class AdvisoryHit {
  /// [crate] at [version], covered by [advisory] through [vulnerability].
  const AdvisoryHit({
    required this.advisory,
    required this.vulnerability,
    required this.crate,
    required this.version,
    required this.rangeUnparsed,
  });

  /// The advisory that covers it.
  final UpstreamAdvisory advisory;

  /// The entry of [advisory] that matched.
  final AdvisoryVulnerability vulnerability;

  /// The crate as rust/Cargo.lock names it.
  final String crate;

  /// The locked version.
  final String version;

  /// Whether [vulnerability]'s range could not be read.
  final bool rangeUnparsed;

  /// One line for a terminal or a workflow annotation.
  String describe() {
    final fix = vulnerability.patched.isEmpty
        ? 'no fixed release yet'
        : 'fixed in ${vulnerability.patched}';
    final why = rangeUnparsed
        ? 'its range "${vulnerability.range}" could not be read, so it is '
              'treated as covering $version'
        : 'covers $version (${vulnerability.range})';
    return '$crate $version: ${advisory.ghsaId} (${advisory.severity}) $why — '
        '${advisory.summary} — $fix. ${advisory.url}';
  }
}

/// A crate name as Cargo compares them: `-` and `_` are the same character.
String crateKey(String name) => name.toLowerCase().replaceAll('-', '_');

/// Every version rust/Cargo.lock resolves for each crate, keyed by [crateKey].
/// Pure; exposed for testing.
Map<String, Set<String>> lockedVersions(String cargoLock) {
  final locked = <String, Set<String>>{};
  String? name;
  for (final raw in const LineSplitter().convert(cargoLock)) {
    final line = raw.trim();
    if (line == '[[package]]') {
      name = null;
      continue;
    }
    final field = RegExp(r'^(name|version) = "([^"]*)"$').firstMatch(line);
    if (field == null) continue;
    if (field.group(1) == 'name') {
      name = field.group(2);
    } else if (name != null) {
      locked.putIfAbsent(crateKey(name), () => <String>{}).add(field.group(2)!);
    }
  }
  return locked;
}

final _constraint = RegExp(
  r'^(<=|>=|<|>|=)?\s*v?(\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$',
);

/// Whether [version] is in [range], a GitHub `vulnerable_version_range`, or
/// `null` when [range] does not read as one. Pure; exposed for testing.
///
/// The whole range is read before any of it is applied, so a constraint that
/// does not parse makes the answer `null` even where an earlier one already
/// rules [version] out: the caller counts `null` as covered, and a range this
/// cannot read is a reason to look, never a reason to stay quiet.
bool? versionInRange(String version, String range) {
  final constraints = <(String, String)>[];
  for (final part in range.split(',')) {
    final m = _constraint.firstMatch(part.trim());
    if (m == null) return null;
    constraints.add((m.group(1) ?? '=', m.group(2)!));
  }
  for (final (op, bound) in constraints) {
    final c = compareVersions(version, bound);
    final holds = switch (op) {
      '<' => c < 0,
      '<=' => c <= 0,
      '>' => c > 0,
      '>=' => c >= 0,
      _ => c == 0,
    };
    if (!holds) return false;
  }
  return true;
}

/// Every locked crate version a published, unwithdrawn advisory covers, in
/// the order of [advisories]. Pure; exposed for testing.
///
/// An advisory may list the same crate more than once — one entry per release
/// line it was fixed on — and a version is reported once, for the first entry
/// that covers it. Only crates.io entries are read, and names are compared as
/// Cargo compares them.
List<AdvisoryHit> advisoryHits({
  required List<UpstreamAdvisory> advisories,
  required Map<String, Set<String>> locked,
}) {
  final hits = <AdvisoryHit>[];
  for (final advisory in advisories) {
    if (advisory.withdrawn) continue;
    final seen = <String>{};
    for (final v in advisory.vulnerabilities) {
      if (v.ecosystem.toLowerCase() != advisoryEcosystem) continue;
      final versions = locked[crateKey(v.package)];
      if (versions == null) continue;
      for (final version in versions.toList()..sort(compareVersions)) {
        final key = '${crateKey(v.package)}@$version';
        if (seen.contains(key)) continue;
        final inRange = versionInRange(version, v.range);
        if (inRange == false) continue;
        seen.add(key);
        hits.add(
          AdvisoryHit(
            advisory: advisory,
            vulnerability: v,
            crate: v.package,
            version: version,
            rangeUnparsed: inRange == null,
          ),
        );
      }
    }
  }
  return hits;
}

/// How many advisories GitHub returns per page, at most.
const advisoriesPerPage = 100;

/// Fetches every published advisory of [repo], page by page, retrying each
/// page [attempts] times before giving up. Throws when a page could not be
/// fetched or did not read as an advisory list: the caller reports that as
/// "not checked", which is never the same thing as "nothing found".
Future<List<UpstreamAdvisory>> fetchUpstreamAdvisories({
  required String repo,
  required UpstreamHttp http,
  int attempts = 3,
  Duration retryDelay = const Duration(seconds: 5),
}) async {
  final advisories = <UpstreamAdvisory>[];
  for (var page = 1; ; page++) {
    final url = Uri.https(
      'api.github.com',
      '/repos/$repo/security-advisories',
      {'state': 'published', 'per_page': '$advisoriesPerPage', 'page': '$page'},
    );
    Object? lastError;
    List<dynamic>? body;
    for (var attempt = 1; attempt <= attempts && body == null; attempt++) {
      try {
        body = jsonDecode(await http.getJson(url)) as List<dynamic>;
      } catch (e) {
        lastError = e;
        if (attempt < attempts) await Future<void>.delayed(retryDelay);
      }
    }
    if (body == null) {
      throw Exception('GET $url failed $attempts times: $lastError');
    }
    for (final entry in body) {
      advisories.add(UpstreamAdvisory.fromJson(entry as Map<String, dynamic>));
    }
    if (body.length < advisoriesPerPage) return advisories;
  }
}

/// [message] made safe for a workflow command such as `::error::`. The text
/// comes from the upstream's advisories, so a newline in it must not be able
/// to start a command of its own.
String escapeWorkflowCommand(String message) => message
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A');
