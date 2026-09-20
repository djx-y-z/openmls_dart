import 'package:flutter/material.dart';
import 'package:openmls/openmls.dart';

import 'demos/advanced_groups_demo.dart';
import 'demos/advanced_proposals_demo.dart';
import 'demos/groups_demo.dart';
import 'demos/keys_demo.dart';
import 'demos/post_quantum_demo.dart';
import 'demos/proposals_demo.dart';
import 'demos/state_demo.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isInitialized = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _initOpenmls();
  }

  Future<void> _initOpenmls() async {
    try {
      await Openmls.init();
      if (!mounted) return;
      setState(() => _isInitialized = true);
    } catch (e) {
      // Report it on screen. This method is fire-and-forget from `initState`,
      // so without this a throw leaves `_isInitialized` false, the spinner
      // below runs forever, and the only trace is a line in the console — a
      // hang that says nothing about its cause.
      //
      // On web the ordinary cause is a missing `web/pkg/`: `flutter run -d
      // chrome` after a run for another platform reuses that run's
      // `dart_build` stamp — the build directory key does not include the
      // target platform — and skips the build hook outright, so the WASM
      // module is never provisioned and `init()` fails on a 404.
      if (!mounted) return;
      setState(() => _initError = '$e');
    }
  }

  /// Shown instead of the spinner when [Openmls.init] threw.
  ///
  /// The raw error is kept in the text on purpose: any `init()` failure lands
  /// here, not only the missing-WASM one the hint names.
  Widget _buildInitError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            const Text(
              'openmls failed to initialize',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SelectableText(
              _initError!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            const Text(
              'On web this usually means web/pkg/ was not provisioned.\n'
              'Run `make run-example-web` from the package root — it rebuilds '
              'the WASM module and clears the dart_build stamp that makes '
              'flutter run skip the build hook.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    Openmls.cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openmls Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('openmls Example'),
          centerTitle: true,
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabs: const [
              Tab(icon: Icon(Icons.key), text: 'Keys'),
              Tab(icon: Icon(Icons.group), text: 'Groups'),
              Tab(icon: Icon(Icons.info_outline), text: 'State'),
              Tab(icon: Icon(Icons.send), text: 'Proposals'),
              Tab(icon: Icon(Icons.group_work), text: 'Adv Groups'),
              Tab(icon: Icon(Icons.tune), text: 'Adv Proposals'),
              Tab(icon: Icon(Icons.security), text: 'Post-Quantum'),
            ],
          ),
        ),
        body: _isInitialized
            ? TabBarView(
                controller: _tabController,
                children: const [
                  KeysDemoTab(),
                  GroupsDemoTab(),
                  StateDemoTab(),
                  ProposalsDemoTab(),
                  AdvancedGroupsDemoTab(),
                  AdvancedProposalsDemoTab(),
                  PostQuantumDemoTab(),
                ],
              )
            : _initError != null
            ? _buildInitError()
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
