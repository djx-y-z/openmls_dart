import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/src/common.dart';
import '../../scripts/src/repo_protections.dart';

/// An environment as `GET repos/<slug>/environments/<name>` returns it once
/// setup_repo_protections.dart has configured it, trimmed to the fields read.
Map<String, Object?> configured({int reviewerId = 42}) => {
  'name': 'native-build',
  'can_admins_bypass': false,
  'protection_rules': [
    {
      'id': 1,
      'type': 'required_reviewers',
      'prevent_self_review': false,
      'reviewers': [
        {
          'type': 'User',
          'reviewer': {'login': 'maintainer', 'id': reviewerId},
        },
      ],
    },
    {'id': 2, 'type': 'branch_policy'},
  ],
  'deployment_branch_policy': {
    'protected_branches': false,
    'custom_branch_policies': true,
  },
};

const tagPolicy = {'id': 7, 'name': 'libfoo_frb-*', 'type': 'tag'};

void main() {
  group('releaseEnvironments', () {
    test('native-build takes the crate tags, pub.dev the package tags', () {
      expect(
        [
          for (final env in releaseEnvironments('libfoo_frb'))
            (env.name, env.tagPattern, env.job),
        ],
        [
          ('native-build', 'libfoo_frb-*', 'create-release'),
          ('pub.dev', 'v*', 'publish'),
        ],
      );
    });
  });

  group('environmentBody', () {
    test('sends every setting, the reviewer by numeric id', () {
      expect(
        jsonEncode(environmentBody(42)),
        jsonEncode({
          'wait_timer': 0,
          'prevent_self_review': false,
          'reviewers': [
            {'type': 'User', 'id': 42},
          ],
          'can_admins_bypass': false,
          'deployment_branch_policy': {
            'protected_branches': false,
            'custom_branch_policies': true,
          },
        }),
      );
    });

    test('lets in only the listed policies, never protected branches', () {
      final policy =
          environmentBody(1)['deployment_branch_policy']!
              as Map<String, Object?>;
      // GitHub requires exactly one of the two to be true.
      expect(policy['custom_branch_policies'], isTrue);
      expect(policy['protected_branches'], isFalse);
    });
  });

  test('tagPolicyBody names a tag policy, not a branch one', () {
    expect(tagPolicyBody('v*'), {'name': 'v*', 'type': 'tag'});
  });

  group('planTagPolicy', () {
    test('creates the policy when there is none', () {
      final plan = planTagPolicy(const [], 'libfoo_frb-*');
      expect(plan.create, isTrue);
      expect(plan.extra, isEmpty);
    });

    test('does not create it twice', () {
      final plan = planTagPolicy(const [tagPolicy], 'libfoo_frb-*');
      expect(plan.create, isFalse);
      expect(plan.extra, isEmpty);
    });

    test('a branch policy of the same name is not the tag policy', () {
      const branch = {'id': 8, 'name': 'libfoo_frb-*', 'type': 'branch'};
      final plan = planTagPolicy(const [branch], 'libfoo_frb-*');
      expect(plan.create, isTrue);
      expect(plan.extra, [branch]);
    });

    test('a policy without a type is a branch policy', () {
      const untyped = {'id': 9, 'name': 'libfoo_frb-*'};
      final plan = planTagPolicy(const [untyped], 'libfoo_frb-*');
      expect(plan.create, isTrue);
      expect(plan.extra, [untyped]);
    });

    test('reports every other policy and keeps it', () {
      const main = {'id': 10, 'name': 'main', 'type': 'branch'};
      const other = {'id': 11, 'name': 'v*', 'type': 'tag'};
      final plan = planTagPolicy(const [
        main,
        tagPolicy,
        other,
      ], 'libfoo_frb-*');
      expect(plan.create, isFalse);
      expect(plan.extra, [main, other]);
    });
  });

  group('environmentMismatches', () {
    List<String> check(
      Map<String, Object?> live, [
      List<Map<String, Object?>> policies = const [tagPolicy],
    ]) => environmentMismatches(
      live,
      policies,
      reviewerId: 42,
      tagPattern: 'libfoo_frb-*',
    );

    test('none for the environment the script sets up', () {
      expect(check(configured()), isEmpty);
    });

    test('an admin bypass', () {
      expect(check({...configured(), 'can_admins_bypass': true}), [
        contains('can_admins_bypass is true'),
      ]);
    });

    test('every branch allowed, which GitHub reports as a null policy', () {
      expect(check({...configured(), 'deployment_branch_policy': null}), [
        contains('deployment_branch_policy is null'),
      ]);
    });

    test('protected branches instead of the listed policies', () {
      expect(
        check({
          ...configured(),
          'deployment_branch_policy': {
            'protected_branches': true,
            'custom_branch_policies': false,
          },
        }),
        [contains('not custom policies only')],
      );
    });

    test('no required reviewers at all', () {
      expect(check({...configured(), 'protection_rules': const []}), [
        contains('no required reviewers'),
      ]);
    });

    test('someone else as the reviewer', () {
      expect(check(configured(reviewerId: 7)), [
        contains('user 42 is not a required reviewer'),
      ]);
    });

    test('self-review prevented', () {
      final live = configured();
      final rule = (live['protection_rules']! as List).first as Map;
      rule['prevent_self_review'] = true;
      expect(check(live), [contains('prevent_self_review is true')]);
    });

    test('a wait timer', () {
      final live = configured();
      (live['protection_rules']! as List).add({
        'type': 'wait_timer',
        'wait_timer': 5,
      });
      expect(check(live), [contains('wait timer')]);
    });

    test('the tag policy missing, and another policy present', () {
      expect(
        check(configured(), const [
          {'id': 3, 'name': 'main'},
        ]),
        [
          contains('no deployment policy for libfoo_frb-* tags'),
          allOf(contains('branch "main"'), contains('policy id 3')),
        ],
      );
    });
  });

  group('pushTagPatterns', () {
    test('reads the tags under on: push:, quoted or not, comments dropped', () {
      const workflow = '''
name: Release

on:
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
  push:
    # Release tags only.
    tags:
      - 'v*'  # v1.0.0, v1.0.1, ...
      - "release-*"
      - plain-*
    branches:
      - main

jobs:
  push:
    tags:
      - 'not-a-trigger'
''';
      expect(pushTagPatterns(workflow), ['v*', 'release-*', 'plain-*']);
    });

    test('nothing when the workflow is not pushed by tags', () {
      expect(pushTagPatterns('on:\n  workflow_dispatch:\njobs: {}\n'), isEmpty);
    });
  });

  // What this script sends is only right while the release workflows still
  // trigger on these tags and run their publishing job in these environments.
  group("this project's release workflows", () {
    final workflows = Directory('${getPackageDir().path}/.github/workflows');
    String read(String name) =>
        File('${workflows.path}/$name').readAsStringSync();
    final environments = {
      for (final env in releaseEnvironments(getCrateName())) env.name: env,
    };

    test('publish.yml is pushed by the pub.dev tags and runs in pub.dev', () {
      final publish = read('publish.yml');
      expect(pushTagPatterns(publish), [environments['pub.dev']!.tagPattern]);
      expect(publish, contains('environment: pub.dev'));
    });

    test(
      'the native build is pushed by the crate tags and runs in native-build',
      () {
        final builds = [
          for (final file in workflows.listSync().whereType<File>())
            if (RegExp(r'[/\\]build-[^/\\]+\.yml$').hasMatch(file.path) &&
                file.readAsStringSync().contains('environment: native-build'))
              file,
        ];
        expect(builds, hasLength(1), reason: 'one build workflow publishes');
        expect(pushTagPatterns(builds.single.readAsStringSync()), [
          environments['native-build']!.tagPattern,
        ]);
      },
    );
  });
}
