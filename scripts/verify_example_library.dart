/// Check that the app under test loaded the library the run says it tests.
///
/// Run it after the tests, with where the library should have come from. See
/// `scripts/src/example_library.dart`.
///
/// Usage: make verify-example-library ARGS="--built|--released [--web] [--dir <app>]"
library;

import 'dart:io';

import 'src/example_library.dart';

/// On a line of its own, so that no other line's length depends on it.
const _packageName = 'openmls';

void main(List<String> args) {
  final LibrarySource source;
  if (args.contains('--built')) {
    source = LibrarySource.built;
  } else if (args.contains('--released')) {
    source = LibrarySource.released;
  } else {
    stderr.writeln('Say which: --built or --released.');
    exit(2);
  }

  final dirFlag = args.indexOf('--dir');
  final app = dirFlag < 0 ? 'example' : args[dirFlag + 1];

  final List<String> problems;
  if (args.contains('--web')) {
    final marker = File('$app/web/pkg/.wasm-version');
    problems = webModuleProblems(
      marker.existsSync() ? marker.readAsStringSync() : null,
      source,
    );
  } else {
    final results = Directory('$app/.dart_tool/hooks_runner/$_packageName');
    final libraries = <String>{
      if (results.existsSync())
        for (final entry in results.listSync(recursive: true))
          if (entry is File && entry.path.endsWith('output.json'))
            ...librariesInHookOutput(entry.readAsStringSync()),
    }.toList();
    stdout.writeln(libraries.map((library) => 'Loaded: $library').join('\n'));
    problems = libraryProblems(libraries, source);
  }

  if (problems.isEmpty) {
    stdout.writeln('The run tested a ${source.name} library, as it should.');
    return;
  }
  problems.forEach(stderr.writeln);
  exit(1);
}
