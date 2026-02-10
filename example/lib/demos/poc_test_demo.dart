import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:openmls/openmls.dart';

import '../widgets/demo_card.dart';

class PocTestDemoTab extends StatefulWidget {
  const PocTestDemoTab({super.key});

  @override
  State<PocTestDemoTab> createState() => _PocTestDemoTabState();
}

class _PocTestDemoTabState extends State<PocTestDemoTab> {
  String? _result;
  bool _loading = false;

  Uint8List _randomKey() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _result = null;
    });
    try {
      final r = StringBuffer();

      // Test 1: Unencrypted roundtrip
      r.writeln('=== Test 1: Unencrypted Roundtrip ===');
      final testData = [1, 2, 3, 4, 5];
      final loaded = await pocStoreAndLoad(key: 'demo_key', value: testData);
      r.writeln('Input:  $testData');
      r.writeln('Output: ${loaded.toList()}');
      r.writeln('Match:  ${loaded.toList().toString() == testData.toString()}');
      r.writeln();

      // Test 2: Encrypted roundtrip — check DevTools IndexedDB!
      r.writeln('=== Test 2: Encrypted Roundtrip (AES-256-GCM) ===');
      final encKey = _randomKey();
      final encReport = await pocEncryptedRoundtrip(encryptionKey: encKey);
      r.writeln(encReport);
      r.writeln();

      // Test 3: Wrong key rejection
      r.writeln('=== Test 3: Wrong Key Rejection ===');
      final correctKey = _randomKey();
      final wrongKey = _randomKey();
      final wrongKeyReport = await pocWrongKeyTest(
        correctKey: correctKey,
        wrongKey: wrongKey,
      );
      r.writeln(wrongKeyReport);

      setState(() => _result = r.toString());
    } catch (e) {
      setState(() => _result = 'Error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: DemoCard(
        title: 'WASM PoC Test',
        description:
            'Tests async I/O + AES-256-GCM encryption on IndexedDB. '
            'After running, check Chrome DevTools > Application > IndexedDB '
            '> poc_db > kv_store — values should be encrypted blobs.',
        onRun: _run,
        isLoading: _loading,
        result: _result,
      ),
    );
  }
}
