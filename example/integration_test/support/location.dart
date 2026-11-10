// Where a capability keeps a database it opens more than once, and what each
// platform lets a test see of it: a file in a directory of its own natively,
// an IndexedDB database of its own on the web.
export 'location_web.dart' if (dart.library.io) 'location_io.dart';
