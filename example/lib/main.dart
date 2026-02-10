import 'package:flutter/material.dart';
import 'package:openmls/openmls.dart';

import 'demos/advanced_groups_demo.dart';
import 'demos/advanced_proposals_demo.dart';
import 'demos/groups_demo.dart';
import 'demos/keys_demo.dart';
import 'demos/poc_test_demo.dart';
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _initOpenmls();
  }

  Future<void> _initOpenmls() async {
    await Openmls.init();
    setState(() => _isInitialized = true);
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
              Tab(icon: Icon(Icons.science), text: 'PoC Test'),
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
                  PocTestDemoTab(),
                ],
              )
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
