/// What `setup_repo_protections.dart` sends to GitHub for the two release
/// environments, kept free of I/O so the request bodies can be tested.
library;

import 'dart:convert';

/// An environment a release workflow publishes from.
///
/// [tagPattern] is the only ref allowed to enter it. A run started from a
/// branch, `main` included, is refused by GitHub before the job starts, so a
/// mistaken approval cannot publish from one; and only an Admin can create a
/// tag at all (the `Protect release tags` ruleset).
class ReleaseEnvironment {
  const ReleaseEnvironment({
    required this.name,
    required this.tagPattern,
    required this.workflow,
    required this.job,
  });

  /// The environment's name, as the job's `environment:` key names it.
  final String name;

  /// The tags that may enter it: the ones its workflow is pushed by.
  final String tagPattern;

  /// The workflow file whose [job] runs in it, for messages.
  final String workflow;

  /// The job that runs in it.
  final String job;
}

/// The two environments, for the native crate named [crateName]: its release
/// tags are `<crateName>-X.Y.Z` (`make release-frb`), the package's are
/// `vX.Y.Z` (`make release`).
List<ReleaseEnvironment> releaseEnvironments(String crateName) => [
  ReleaseEnvironment(
    name: 'native-build',
    tagPattern: '$crateName-*',
    workflow: 'the native build workflow',
    job: 'create-release',
  ),
  const ReleaseEnvironment(
    name: 'pub.dev',
    tagPattern: 'v*',
    workflow: 'publish.yml',
    job: 'publish',
  ),
];

/// The body of `PUT repos/<slug>/environments/<name>`: every setting at once,
/// so that a re-run converges on the same environment whatever was there.
///
/// - [reviewerId] is the one required reviewer, and approving one's own run is
///   allowed (`prevent_self_review: false`): with a single maintainer, the
///   person who pushes the release tag is the only one who can approve it.
/// - `can_admins_bypass: false`: an Admin's run waits for the review as well.
///   GitHub's REST description does not list this field, but the API applies
///   it in a public repository, and google/go-github sends it.
/// - `deployment_branch_policy` with custom policies only: what may enter is
///   then exactly the policies listed, which [planTagPolicy] makes the tag one.
Map<String, Object?> environmentBody(int reviewerId) => {
  'wait_timer': 0,
  'prevent_self_review': false,
  'reviewers': [
    {'type': 'User', 'id': reviewerId},
  ],
  'can_admins_bypass': false,
  'deployment_branch_policy': {
    'protected_branches': false,
    'custom_branch_policies': true,
  },
};

/// The body of `POST repos/<slug>/environments/<name>/deployment-branch-policies`
/// that lets [pattern] tags in.
Map<String, String> tagPolicyBody(String pattern) => {
  'name': pattern,
  'type': 'tag',
};

bool _isTagPolicy(Map<String, Object?> policy, String pattern) =>
    policy['name'] == pattern && (policy['type'] ?? 'branch') == 'tag';

/// Whether the tag policy for [pattern] still has to be created, and which of
/// the [existing] policies let in something else.
///
/// [existing] is the `branch_policies` array GitHub lists; a policy without a
/// `type` is a branch policy, as GitHub's own default is. Nothing is deleted
/// here: an extra policy widens what may enter, and removing it is left to the
/// maintainer, who is told which one it is.
({bool create, List<Map<String, Object?>> extra}) planTagPolicy(
  List<Map<String, Object?>> existing,
  String pattern,
) => (
  create: !existing.any((p) => _isTagPolicy(p, pattern)),
  extra: [
    for (final p in existing)
      if (!_isTagPolicy(p, pattern)) p,
  ],
);

/// How the environment GitHub reports differs from what [environmentBody] and
/// [planTagPolicy] set up; empty when it matches.
///
/// [live] is `GET repos/<slug>/environments/<name>`, [policies] the
/// `branch_policies` of its deployment policies.
List<String> environmentMismatches(
  Map<String, Object?> live,
  List<Map<String, Object?>> policies, {
  required int reviewerId,
  required String tagPattern,
}) {
  final problems = <String>[];
  if (live['can_admins_bypass'] != false) {
    problems.add(
      'can_admins_bypass is ${live['can_admins_bypass']}: an Admin skips the review',
    );
  }
  final branchPolicy = live['deployment_branch_policy'];
  if (branchPolicy is! Map ||
      branchPolicy['protected_branches'] != false ||
      branchPolicy['custom_branch_policies'] != true) {
    problems.add(
      'deployment_branch_policy is ${jsonEncode(branchPolicy)}, '
      'not custom policies only: more than the tag may enter',
    );
  }
  final rules = [
    for (final rule in live['protection_rules'] as List? ?? const [])
      (rule as Map).cast<String, Object?>(),
  ];
  final reviewRules = rules.where((r) => r['type'] == 'required_reviewers');
  if (reviewRules.isEmpty) {
    problems.add('no required reviewers: nothing waits for an approval');
  } else {
    final rule = reviewRules.first;
    final ids = [
      for (final entry in rule['reviewers'] as List? ?? const [])
        ((entry as Map)['reviewer'] as Map?)?['id'],
    ];
    if (!ids.contains(reviewerId)) {
      problems.add('user $reviewerId is not a required reviewer (ids: $ids)');
    }
    if (rule['prevent_self_review'] != false) {
      problems.add(
        'prevent_self_review is ${rule['prevent_self_review']}: '
        'whoever starts the run cannot approve it',
      );
    }
  }
  if (rules.any(
    (r) => r['type'] == 'wait_timer' && (r['wait_timer'] ?? 0) != 0,
  )) {
    problems.add('a wait timer is set');
  }
  final plan = planTagPolicy(policies, tagPattern);
  if (plan.create) {
    problems.add('no deployment policy for $tagPattern tags');
  }
  for (final p in plan.extra) {
    problems.add(
      'a deployment policy also lets in ${p['type'] ?? 'branch'} '
      '"${p['name']}" (policy id ${p['id']})',
    );
  }
  return problems;
}

/// The tag patterns a workflow's `on: push: tags:` list names, in order.
///
/// A plain reading of the block-style YAML the workflows here use, enough to
/// hold [releaseEnvironments] against them; it does not parse YAML in general.
List<String> pushTagPatterns(String workflow) {
  final lines = const LineSplitter().convert(workflow);
  final patterns = <String>[];
  var inOn = false;
  var inPush = false;
  var inTags = false;
  for (final line in lines) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final indent = line.length - trimmed.length;
    if (indent == 0) {
      inOn = RegExp(r'''^(on|'on'|"on"):''').hasMatch(trimmed);
      inPush = false;
      inTags = false;
      continue;
    }
    if (!inOn) continue;
    if (indent == 2 && trimmed.startsWith('push:')) {
      inPush = true;
      inTags = false;
      continue;
    }
    if (inPush && indent <= 2) {
      inPush = false;
      inTags = false;
    }
    if (!inPush) continue;
    if (indent == 4) inTags = trimmed.startsWith('tags:');
    if (inTags && indent >= 6 && trimmed.startsWith('- ')) {
      var value = trimmed.substring(2).trim();
      final comment = value.indexOf(' #');
      if (comment >= 0) value = value.substring(0, comment).trim();
      if (value.length >= 2 &&
          (value.startsWith("'") || value.startsWith('"')) &&
          value.endsWith(value[0])) {
        value = value.substring(1, value.length - 1);
      }
      patterns.add(value);
    }
  }
  return patterns;
}
