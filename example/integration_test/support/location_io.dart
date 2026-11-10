import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// A path for a database, in a directory of its own that is removed when the
/// capability ends.
///
/// The directory is under the app's temporary directory: on Android and iOS
/// that is the app's own, and nothing else can write there.
Future<String> freshDatabase(String name) async {
  final directory = await Directory.systemTemp.createTemp('openmls_it_');
  addTearDown(() async {
    // Cleanup, not a check: the engines are closed by now, but Windows can
    // hold a file a moment longer, and a leftover temporary directory fails
    // nothing.
    try {
      await directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      debugPrint('Left ${directory.path} behind: $error');
    }
  });
  return '${directory.path}${Platform.pathSeparator}$name.db';
}

/// The permission bits of the file at [path].
int permissionsOf(String path) => File(path).statSync().mode & 0x1ff;
