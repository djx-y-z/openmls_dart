import 'package:test/test.dart';

import '../../scripts/src/frb_pins.dart';

void main() {
  group('frbVersionFromPubspec', () {
    test('accepts the single-version range', () {
      expect(
        frbVersionFromPubspec(
          'dependencies:\n  flutter_rust_bridge: ">=2.12.0 <2.12.1"\n',
        ),
        '2.12.0',
      );
    });

    test('accepts it unquoted and single-quoted', () {
      for (final line in [
        '  flutter_rust_bridge: >=2.12.0 <2.12.1',
        "  flutter_rust_bridge: '>=2.12.0 <2.12.1'",
      ]) {
        expect(frbVersionFromPubspec('dependencies:\n$line\n'), '2.12.0');
      }
    });

    // The form that caused the incident: the caret let a newer runtime into
    // the published archive while the committed bindings named the old one.
    test('rejects a caret', () {
      expect(
        () => frbVersionFromPubspec('  flutter_rust_bridge: ^2.12.0\n'),
        throwsA(
          isA<FrbPinFormatException>().having(
            (e) => e.message,
            'message',
            contains('not the required form'),
          ),
        ),
      );
    });

    // Publishable-form guard: a bare version is the same single version but
    // makes `dart pub publish` exit 65, which takes `make release` with it.
    test('rejects a bare version and says why', () {
      expect(
        () => frbVersionFromPubspec('  flutter_rust_bridge: 2.12.0\n'),
        throwsA(
          isA<FrbPinFormatException>().having(
            (e) => e.message,
            'message',
            contains('unpublishable'),
          ),
        ),
      );
    });

    // A range wide enough to admit a second version fails the runtime assert
    // for every version but one, so the bound is checked and not just parsed.
    test('rejects a minor-wide range', () {
      expect(
        () => frbVersionFromPubspec(
          '  flutter_rust_bridge: ">=2.12.0 <2.13.0"\n',
        ),
        throwsA(
          isA<FrbPinFormatException>().having(
            (e) => e.message,
            'message',
            contains('not the next patch'),
          ),
        ),
      );
    });

    // A person writes a comment beside a pin; it is not part of the version,
    // and reading it as part turned a correctly-pinned file into a failure
    // telling the reader to write what they had already written.
    test('tolerates a trailing comment', () {
      expect(
        frbVersionFromPubspec(
          '  flutter_rust_bridge: ">=2.12.0 <2.12.1" # pinned, see CONTRIBUTING\n',
        ),
        '2.12.0',
      );
    });

    // A `dependency_overrides` entry replaces the dependency outright, so the
    // constraint above it is not the one pub resolves. Reading only the first
    // reported agreement about a version nothing installs.
    test('rejects a second declaration anywhere in the file', () {
      const content =
          'dependencies:\n'
          '  flutter_rust_bridge: ">=2.12.0 <2.12.1"\n'
          'dependency_overrides:\n'
          '  flutter_rust_bridge: ^2.9.0\n';
      expect(
        () => frbVersionFromPubspec(content),
        throwsA(
          isA<FrbPinFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('2 times'), contains('^2.9.0')),
          ),
        ),
      );
    });

    test('rejects a pubspec with no FRB dependency', () {
      expect(
        () => frbVersionFromPubspec('dependencies:\n  crypto: ^3.0.7\n'),
        throwsA(isA<FrbPinFormatException>()),
      );
    });
  });

  group('the other four sources', () {
    test('reads the string form in Cargo.toml', () {
      expect(
        frbVersionFromCargoToml(
          '[dependencies]\nflutter_rust_bridge = "=2.12.0"\n',
        ),
        '2.12.0',
      );
    });

    test('reads the table form in Cargo.toml', () {
      expect(
        frbVersionFromCargoToml(
          'flutter_rust_bridge = { version = "=2.12.0", features = ["rust-async"] }\n',
        ),
        '2.12.0',
      );
    });

    test('ignores a Cargo.toml pin that is not exact', () {
      expect(frbVersionFromCargoToml('flutter_rust_bridge = "2.12.0"\n'), null);
    });

    // The rendered manifest already carries a wasm32 target section, so a
    // second pin there is an ordinary thing to write.
    test('rejects two different Cargo pins', () {
      const content =
          '[dependencies]\n'
          'flutter_rust_bridge = "=2.12.0"\n'
          '[target.\'cfg(target_arch = "wasm32")\'.dependencies]\n'
          'flutter_rust_bridge = "=2.11.0"\n';
      expect(
        () => frbVersionFromCargoToml(content),
        throwsA(isA<FrbPinFormatException>()),
      );
    });

    test('accepts the same Cargo pin written twice', () {
      const content =
          'flutter_rust_bridge = "=2.12.0"\n'
          '[target.\'cfg(target_arch = "wasm32")\'.dependencies]\n'
          'flutter_rust_bridge = "=2.12.0"\n';
      expect(frbVersionFromCargoToml(content), '2.12.0');
    });

    test('reads FRB_CODEGEN_VERSION from the Makefile', () {
      expect(
        frbVersionFromMakefile('FVM := fvm\nFRB_CODEGEN_VERSION ?= 2.12.0\n'),
        '2.12.0',
      );
    });

    // make resolves a later `=` over an earlier `?=`, so the first assignment
    // is not the one that installs the generator.
    test('takes the last Makefile assignment, as make does', () {
      expect(
        frbVersionFromMakefile(
          'FRB_CODEGEN_VERSION ?= 2.12.0\nFRB_CODEGEN_VERSION = 2.11.0\n',
        ),
        '2.11.0',
      );
    });

    test('reads codegenVersion from the generated bindings', () {
      expect(
        frbVersionFromGeneratedBindings(
          "  @override\n  String get codegenVersion => '2.12.0';\n",
        ),
        '2.12.0',
      );
    });

    // copier.yml's own default for this answer is written quoted, and the
    // gate's failure text tells the reader to edit this file — so a quoted
    // value is a hazard it actively invites.
    test('reads frb_version with a caret, quotes or a comment', () {
      expect(frbVersionFromCopierAnswers('frb_version: ^2.12.0\n'), '2.12.0');
      expect(frbVersionFromCopierAnswers('frb_version: 2.12.0\n'), '2.12.0');
      expect(frbVersionFromCopierAnswers("frb_version: '2.12.0'\n"), '2.12.0');
      expect(frbVersionFromCopierAnswers('frb_version: "^2.12.0"\n'), '2.12.0');
      expect(
        frbVersionFromCopierAnswers('frb_version: 2.12.0 # pinned\n'),
        '2.12.0',
      );
    });
  });

  group('frbPinReport', () {
    FrbPin pin(String source, String? version, [String detail = '']) =>
        FrbPin(source: source, version: version, detail: detail);

    test('says nothing when every source agrees', () {
      expect(
        frbPinReport([
          pin('pubspec.yaml', '2.12.0'),
          pin('rust/Cargo.toml', '2.12.0'),
          pin('Makefile', '2.12.0'),
        ]),
        isNull,
      );
    });

    // The shape of the real incident: the bindings lag the constraint.
    test('names every file when they disagree', () {
      final report = frbPinReport([
        pin('pubspec.yaml', '2.13.0'),
        pin('rust/Cargo.toml', '2.13.0'),
        pin('lib/src/rust/frb_generated.dart', '2.12.0'),
      ])!;
      expect(report, contains('2.13.0 vs 2.12.0'));
      expect(report, contains('lib/src/rust/frb_generated.dart'));
      expect(report, contains('pubspec.yaml'));
    });

    // A project generated but never built has no bindings; failing there would
    // make the gate impossible to satisfy on a first run.
    test('tolerates bindings that have not been generated yet', () {
      expect(
        frbPinReport([
          pin('pubspec.yaml', '2.12.0'),
          pin('lib/src/rust/frb_generated.dart', null, 'not generated yet'),
        ]),
        isNull,
      );
    });

    test('reports a file that exists but holds no readable pin', () {
      final report = frbPinReport([
        pin('pubspec.yaml', '2.12.0'),
        pin('Makefile', null, 'no FRB_CODEGEN_VERSION found in the file'),
      ])!;
      expect(report, contains('Makefile'));
      expect(report, contains('no FRB_CODEGEN_VERSION'));
    });
  });
}
