/// Platform-specific implementations with conditional imports.
///
/// On native platforms (iOS, Android, macOS, Linux, Windows), this exports
/// from `platform_io.dart`.
///
/// On web, this exports from `platform_web.dart`.
library;

export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
