import 'package:openmls/openmls.dart';
import 'package:test/test.dart';

void main() {
  group('Openmls', () {
    // =========================================================================
    // Initialization tests
    // =========================================================================
    group('initialization', () {
      // Ensure clean state after each test
      tearDown(Openmls.cleanup);

      test('initializes successfully', () async {
        await Openmls.init();
        expect(Openmls.isInitialized, isTrue);
      });

      test('multiple init calls are idempotent', () async {
        await Openmls.init();
        await Openmls.init();
        expect(Openmls.isInitialized, isTrue);
      });

      test('cleanup resets initialization state', () async {
        await Openmls.init();
        Openmls.cleanup();
        expect(Openmls.isInitialized, isFalse);
      });

      test('cleanup is safe to call when not initialized', () {
        // Should not throw
        Openmls.cleanup();
        expect(Openmls.isInitialized, isFalse);
      });

      test('can reinitialize after cleanup', () async {
        await Openmls.init();
        Openmls.cleanup();
        await Openmls.init();
        expect(Openmls.isInitialized, isTrue);
      });
    });

    // =========================================================================
    // Guard tests
    // =========================================================================
    group('ensureInitialized', () {
      test('throws StateError when not initialized', () {
        Openmls.cleanup();
        expect(Openmls.ensureInitialized, throwsStateError);
      });

      test('does not throw when initialized', () async {
        await Openmls.init();
        // Should not throw
        expect(Openmls.ensureInitialized, returnsNormally);
        Openmls.cleanup();
      });
    });
  });

  // ===========================================================================
  // Add more test groups for your library's functionality below
  // ===========================================================================
  //
  // Recommended test structure:
  // - test/openmls_test.dart - Basic initialization and version tests (this file)
  // - test/utils_test.dart - Utility function tests
  // - test/<feature>_test.dart - Feature-specific tests
  //
  // Example test group structure:
  //
  // group('MyFeature', () {
  //   setUpAll(Openmls.init);
  //   tearDownAll(Openmls.cleanup);
  //
  //   test('feature does something', () {
  //     // Your test here
  //   });
  // });
}
