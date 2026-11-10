// What `make verify-example-library` checks: that the app under test loaded the
// library the run says it is testing.
//
// The build hook chooses, and it can choose quietly. A run meant to test this
// tree that ended up downloading the release would go green over code the tree
// had replaced — and a run meant to test the release that found a local build
// would never have touched the release at all. The hook writes down what it chose
// in a result file for each build it did, so that is what is read here.
//
// Only the script touches the disk; everything else takes values.
library;

import 'dart:convert';

/// Where a run wants its library to have come from.
enum LibrarySource {
  /// Built from this tree: `rust/target/`.
  built,

  /// Downloaded from the GitHub Release: anywhere but `rust/target/`.
  released,
}

/// Whether [path], a library the hook registered, came from [source].
bool libraryCameFrom(String path, LibrarySource source) {
  final isLocal = path.replaceAll(r'\', '/').contains('/rust/target/');
  return source == LibrarySource.built ? isLocal : !isLocal;
}

/// The libraries registered in one hook result, `output.json`.
List<String> librariesInHookOutput(String outputJson) {
  final output = jsonDecode(outputJson) as Map<String, dynamic>;
  return [
    for (final asset in (output['assets'] as List<dynamic>? ?? const []))
      if ((asset as Map<String, dynamic>)['encoding'] case {
        'file': final String file,
      })
        file,
  ];
}

/// What is wrong with [libraries], every library the hook registered in a run
/// meant to use [source]; empty when nothing is.
List<String> libraryProblems(List<String> libraries, LibrarySource source) => [
  if (libraries.isEmpty)
    'The build hook registered no library, so this run proves nothing about '
        'which one it tested.',
  for (final library in libraries)
    if (!libraryCameFrom(library, source))
      'The app loaded $library, which is not a ${source.name} library. The run '
          'tested something other than what it says.',
];

/// What is wrong with the web module, going by the marker the hook leaves in
/// `web/pkg/`: `local-dev` for a local build, or the version it downloaded.
List<String> webModuleProblems(String? marker, LibrarySource source) {
  if (marker == null) {
    return const [
      'web/pkg/ has no version marker: the build hook did not run.',
    ];
  }
  final isLocal = marker.trim() == 'local-dev';
  return (source == LibrarySource.built) == isLocal
      ? const []
      : [
          'web/pkg/ was provisioned from "${marker.trim()}", which is not a '
              '${source.name} module. The run tested something other than what '
              'it says.',
        ];
}
