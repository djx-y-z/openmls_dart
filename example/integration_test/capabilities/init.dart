import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

import '../support/harness.dart';

/// The package's own initialization, which every capability has run first.
/// A family of capabilities is a function like this one, called from the entry
/// point; add one per area of the package as it grows.
void initCapabilities() {
  group('Openmls', () {
    capability('init is idempotent and survives cleanup', () async {
      expect(Openmls.isInitialized, isTrue);
      await Openmls.init();
      Openmls.ensureInitialized();
      OpenmlsBase.ensureInit();

      Openmls.cleanup();
      expect(Openmls.isInitialized, isFalse);
      expect(Openmls.ensureInitialized, throwsStateError);

      // Without `dispose: true` the bridge stays up, so this comes back.
      await Openmls.init();
      expect(Openmls.isInitialized, isTrue);
    });
  });
}
