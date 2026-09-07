import 'dart:io';

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

  group('the readers the pubspec rule does not cover', () {
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

    test('names the manifest it read when two pins disagree', () {
      const content =
          'flutter_rust_bridge = "=2.13.0"\n'
          '[target.\'cfg(target_arch = "wasm32")\'.dependencies]\n'
          'flutter_rust_bridge = "=2.12.0"\n';
      expect(
        () => frbVersionFromCargoToml(content, path: 'rust/fuzz/Cargo.toml'),
        throwsA(
          isA<FrbPinFormatException>().having(
            (e) => e.message,
            'message',
            contains('rust/fuzz/Cargo.toml'),
          ),
        ),
      );
    });

    test('sees a dependency in every shape cargo accepts', () {
      expect(cargoTomlDeclaresFrb('flutter_rust_bridge = "=2.13.0"\n'), isTrue);
      expect(
        cargoTomlDeclaresFrb('flutter_rust_bridge = { version = "=2.13.0" }\n'),
        isTrue,
      );
      expect(
        cargoTomlDeclaresFrb(
          '[dependencies.flutter_rust_bridge]\nversion = "=2.13.0"\n',
        ),
        isTrue,
      );
      expect(
        cargoTomlDeclaresFrb(
          '[target.\'cfg(target_arch = "wasm32")\'.dependencies]\n'
          'flutter_rust_bridge = "=2.13.0"\n',
        ),
        isTrue,
      );
    });

    // The predicate decides whether the manifest is asked for a version at all,
    // so anything it counts as a dependency that is not one turns a project
    // with nothing to check into a failure — and anything it misses turns a
    // real pin into a source the gate silently skips. This is the test that
    // goes red if it is ever "simplified" to a substring search.
    test('does not count a comment or a differently named crate', () {
      expect(
        cargoTomlDeclaresFrb(
          '# flutter_rust_bridge = "=2.13.0" — pinned in the main crate\n',
        ),
        isFalse,
      );
      expect(
        cargoTomlDeclaresFrb('# see flutter_rust_bridge for the pin\n'),
        isFalse,
      );
      expect(
        cargoTomlDeclaresFrb('flutter_rust_bridge_codegen = "2.13.0"\n'),
        isFalse,
      );
      expect(
        cargoTomlDeclaresFrb('[dependencies]\nlibfuzzer-sys = "0.4"\n'),
        isFalse,
      );
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

    test('reads the getter, not an earlier mention of the same name', () {
      // The one shape that could make this gate report agreement it never
      // checked: `firstMatch` on an unanchored pattern takes whatever comes
      // first in the file, comment included.
      expect(
        frbVersionFromGeneratedBindings(
          "// String get codegenVersion => '9.9.9';\n"
          "  @override\n  String get codegenVersion => '2.13.0';\n",
        ),
        '2.13.0',
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
    FrbPin pin(
      String source,
      String? version, {
      String detail = '',
      bool isAbsent = false,
    }) => FrbPin(
      source: source,
      version: version,
      detail: detail,
      isAbsent: isAbsent,
    );

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
          pin(
            'lib/src/rust/frb_generated.dart',
            null,
            detail: 'not generated yet',
            isAbsent: true,
          ),
        ]),
        isNull,
      );
    });

    test('reports a file that exists but holds no readable pin', () {
      final report = frbPinReport([
        pin('pubspec.yaml', '2.12.0'),
        pin(
          'Makefile',
          null,
          detail: 'no FRB_CODEGEN_VERSION found in the file',
        ),
      ])!;
      expect(report, contains('Makefile'));
      expect(report, contains('no FRB_CODEGEN_VERSION'));
    });
  });

  group('collectFrbPins', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('frb_pins_test');
      File('${dir.path}/pubspec.yaml').writeAsStringSync(
        'dependencies:\n  flutter_rust_bridge: ">=2.13.0 <2.13.1"\n',
      );
      File(
        '${dir.path}/Makefile',
      ).writeAsStringSync('FRB_CODEGEN_VERSION ?= 2.13.0\n');
      File(
        '${dir.path}/.copier-answers.yml',
      ).writeAsStringSync('frb_version: 2.13.0\n');
      Directory('${dir.path}/rust').createSync(recursive: true);
      File(
        '${dir.path}/rust/Cargo.toml',
      ).writeAsStringSync('[dependencies]\nflutter_rust_bridge = "=2.13.0"\n');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    void writeFuzzPin(String version) {
      Directory('${dir.path}/rust/fuzz').createSync(recursive: true);
      File('${dir.path}/rust/fuzz/Cargo.toml').writeAsStringSync(
        '[dependencies]\nflutter_rust_bridge = "=$version"\n',
      );
    }

    test('reads the fuzz crate pin', () {
      writeFuzzPin('2.13.0');
      final pins = collectFrbPins(packageDir: dir);
      expect(pins.map((p) => p.source), contains('rust/fuzz/Cargo.toml'));
      expect(frbPinReport(pins), isNull);
    });

    // The incident this source was added for: the main crate moved to 2.13.0
    // and the fuzz crate kept its `=2.12.0`, which does not merely drift —
    // cargo cannot resolve a path dependency on the main crate against it, so
    // every fuzz target stops building. No other gate sees it: `rust/fuzz` is
    // its own workspace root, so nothing under `rust/` resolves through it, and
    // the Fuzz workflow runs only on `rust/**` pull requests and a weekly cron,
    // never on a push to main.
    test('reports a fuzz crate left behind on the old version', () {
      writeFuzzPin('2.12.0');
      final report = frbPinReport(collectFrbPins(packageDir: dir))!;
      expect(report, contains('rust/fuzz/Cargo.toml'));
      expect(report, contains('2.13.0 vs 2.12.0'));
    });

    test('tolerates a project with no fuzz crate', () {
      expect(frbPinReport(collectFrbPins(packageDir: dir)), isNull);
    });

    // The shape a project is generated in: the scaffold writes a fuzz crate
    // that takes the main crate by path and nothing else. There is no pin to
    // disagree with, and reporting the manifest as unreadable would make the
    // gate red on a first run in every project that has one.
    test('tolerates a fuzz crate that does not depend on FRB', () {
      Directory('${dir.path}/rust/fuzz').createSync(recursive: true);
      File('${dir.path}/rust/fuzz/Cargo.toml').writeAsStringSync(
        '[dependencies]\nlibfuzzer-sys = "0.4"\n'
        '\n[dependencies.the_crate]\npath = ".."\n',
      );
      final pins = collectFrbPins(packageDir: dir);
      final fuzz = pins.firstWhere((p) => p.source == 'rust/fuzz/Cargo.toml');
      expect(fuzz.isAbsent, isTrue);
      expect(fuzz.detail, contains('dependency'));
      expect(frbPinReport(pins), isNull);
    });

    // The one shape that must not be read as absence: the crate is depended on,
    // so the versions are coupled, but the pin is written in a form no reader
    // here accepts. Silence there would be the gate reporting agreement it
    // never checked.
    test('reports a fuzz crate whose pin is not the accepted form', () {
      Directory('${dir.path}/rust/fuzz').createSync(recursive: true);
      File(
        '${dir.path}/rust/fuzz/Cargo.toml',
      ).writeAsStringSync('[dependencies]\nflutter_rust_bridge = "2.13.0"\n');
      final report = frbPinReport(collectFrbPins(packageDir: dir))!;
      expect(report, contains('rust/fuzz/Cargo.toml'));
      expect(report, contains('flutter_rust_bridge = "=X.Y.Z"'));
    });
  });
}
