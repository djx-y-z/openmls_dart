import 'dart:math';

/// An IndexedDB database name that nothing else in this run uses.
Future<String> freshDatabase(String name) async {
  final random = Random();
  // Two draws: on the web an int is a JavaScript number, and `nextInt` takes
  // no more than 2^32.
  return 'openmls_it_${name}_${random.nextInt(1 << 30)}_'
      '${random.nextInt(1 << 30)}';
}

/// There is no file on the web: never called there.
int permissionsOf(String path) =>
    throw UnsupportedError('A database on the web is not a file.');
