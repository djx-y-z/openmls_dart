import 'package:flutter/material.dart';
// ignore: unused_import
import 'package:openmls/openmls.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // TODO: Initialize the library
  // Openmls.init();

  runApp(const OpenmlsExampleApp());
}

class OpenmlsExampleApp extends StatelessWidget {
  const OpenmlsExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openmls Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _output = 'Tap the button to run demo...';

  Future<void> _runDemo() async {
    setState(() {
      _output = 'Running demo...\n\n';
    });

    try {
      // TODO: Add your demo code here
      // Example:
      // final result = Openmls.someOperation();
      // _appendOutput('Result: $result');

      _appendOutput('Demo completed successfully!');
    } catch (e) {
      _appendOutput('Error: $e');
    }
  }

  void _appendOutput(String text) {
    setState(() {
      _output += '$text\n';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('openmls Example'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Info card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'openmls',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Dart wrapper for OpenMLS — a Rust implementation of the Messaging Layer Security (MLS) protocol (RFC 9420)',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Demo button
            FilledButton.icon(
              onPressed: _runDemo,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run Demo'),
            ),

            const SizedBox(height: 16),

            // Output area
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      _output,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.green[300],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
