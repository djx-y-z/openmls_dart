import 'package:test/test.dart';

import '../../scripts/src/msrv.dart';

void main() {
  group('compareRustVersions', () {
    // `rust-version = "1.85"` is legal and common; it means 1.85.0.
    test('compares two parts against three', () {
      expect(compareRustVersions('1.85', '1.93.1'), lessThan(0));
      expect(compareRustVersions('1.95', '1.93.1'), greaterThan(0));
      expect(compareRustVersions('1.85', '1.85.0'), 0);
    });

    test('compares numerically, not as text', () {
      expect(compareRustVersions('1.100.0', '1.93.1'), greaterThan(0));
    });

    test('refuses what is not a Rust version', () {
      expect(
        () => compareRustVersions('stable', '1.85'),
        throwsFormatException,
      );
    });
  });

  group('rustVersionIn', () {
    test('reads the package floor and nothing else', () {
      const toml =
          '[package]\n'
          'name = "wrapper_frb"\n'
          'rust-version = "1.93.1"\n'
          '\n'
          '[dependencies]\n'
          'other = { version = "1", rust-version = "9.9" }\n';
      expect(rustVersionIn(toml), '1.93.1');
    });

    test('is null when the package declares none', () {
      expect(rustVersionIn('[package]\nname = "x"\n'), isNull);
    });
  });

  group('withRustVersion', () {
    test('moves the package floor and leaves the rest byte for byte', () {
      const toml =
          '[package]\n'
          'name = "wrapper_frb"\n'
          'rust-version = "1.93.1"   # CI reads this\n'
          '\n'
          '[dependencies]\n'
          'rand = "0.9"\n';
      expect(
        withRustVersion(toml, '1.95.0'),
        toml.replaceFirst('"1.93.1"', '"1.95.0"'),
      );
    });
  });

  group('the rust_version answer', () {
    const answers =
        "_commit: v4.17.0\nrust_edition: '2024'\nrust_version: 1.93.1\ntopics: x\n";

    test('is read', () {
      expect(rustVersionAnswerIn(answers), '1.93.1');
      expect(rustVersionAnswerIn("rust_version: '1.85'\n"), '1.85');
    });

    test('is moved, and nothing else is', () {
      expect(
        withRustVersionAnswer(answers, '1.95.0'),
        answers.replaceFirst('rust_version: 1.93.1', 'rust_version: 1.95.0'),
      );
    });

    // Bare, YAML reads it as the number 1.8 and renders `1.8`.
    test('is quoted when it has two parts', () {
      expect(
        withRustVersionAnswer(answers, '1.80'),
        answers.replaceFirst('rust_version: 1.93.1', "rust_version: '1.80'"),
      );
    });
  });

  group('the advertised toolchain', () {
    const contributing =
        '- [Rust toolchain](https://rustup.rs/) (1.93.1+) — `rust-version` in\n'
        '  `rust/Cargo.toml` is the authority; this is the same number\n';
    const readme =
        '- [Rust](https://rustup.rs/) (1.93.1+) — must match `rust-version` in '
        '`rust/Cargo.toml`\n';

    test('is read next to the rustup link', () {
      expect(advertisedRustVersionIn(contributing), '1.93.1');
      expect(advertisedRustVersionIn(readme), '1.93.1');
    });

    // A document that does not carry it is reported, never an error.
    test('is null in a document that does not carry it', () {
      expect(
        advertisedRustVersionIn('# Title\n\nNo toolchain here.\n'),
        isNull,
      );
    });

    test('is raised where it stands', () {
      expect(
        withAdvertisedRustVersion(contributing, '1.95.0'),
        contributing.replaceFirst('(1.93.1+)', '(1.95.0+)'),
      );
    });

    test('leaves a version that is not next to the link alone', () {
      const other = 'Tested on (1.93.1+) runners.\n';
      expect(withAdvertisedRustVersion(other, '1.95.0'), other);
    });
  });

  group('floorOf', () {
    Map<String, dynamic> metadata(List<Map<String, dynamic>> packages) => {
      'packages': packages,
      'workspace_members': ['path+file:///w/rust#wrapper_frb@7.0.0'],
    };
    Map<String, dynamic> package(
      String name,
      String version,
      String? floor,
    ) => {
      'id':
          'registry+https://github.com/rust-lang/crates.io-index#$name@$version',
      'name': name,
      'version': version,
      'rust_version': floor,
    };

    test('is the highest floor in the graph, with who declares it', () {
      final floor = floorOf(
        metadata([
          package('a', '1.0.0', '1.85'),
          package('b', '2.0.0', '1.93.1'),
          package('c', '0.1.0', null),
        ]),
      );
      expect(floor, (version: '1.93.1', declaredBy: 'b 2.0.0'));
    });

    // Its floor is the one being checked, so it cannot also set it.
    test('leaves out the workspace crate itself', () {
      final floor = floorOf(
        metadata([
          {
            'id': 'path+file:///w/rust#wrapper_frb@7.0.0',
            'name': 'wrapper_frb',
            'version': '7.0.0',
            'rust_version': '1.99.0',
          },
          package('a', '1.0.0', '1.85'),
        ]),
      );
      expect(floor, (version: '1.85', declaredBy: 'a 1.0.0'));
    });

    test('is null when nothing declares one', () {
      expect(floorOf(metadata([package('a', '1.0.0', null)])), isNull);
    });
  });

  group('msrvSentenceFor', () {
    test('names the crate whose floor it moved to', () {
      expect(
        msrvSentenceFor(
          '1.93.1',
          '1.95.0',
          floor: (version: '1.95.0', declaredBy: 'upstream-core 0.2.0'),
        ),
        'The minimum Rust version moves from 1.93.1 to 1.95.0, the floor '
        '`upstream-core 0.2.0` declares.',
      );
    });

    test('says only the move when no crate declared that floor', () {
      expect(
        msrvSentenceFor('1.93.1', '1.95.0'),
        'The minimum Rust version moves from 1.93.1 to 1.95.0.',
      );
    });

    test('is empty when it did not move', () {
      expect(msrvSentenceFor('1.93.1', '1.93.1'), isEmpty);
      expect(msrvSentenceFor(null, '1.93.1'), isEmpty);
    });
  });
}
