import 'package:openmls/openmls.dart';
import 'package:openmls_example_cli/demos/groups_demo.dart';
import 'package:openmls_example_cli/demos/keys_demo.dart';
import 'package:openmls_example_cli/demos/proposals_demo.dart';
import 'package:openmls_example_cli/demos/state_demo.dart';

void main() async {
  print('');
  print('╔══════════════════════════════════════╗');
  print('║       openmls CLI Example            ║');
  print('╚══════════════════════════════════════╝');

  await Openmls.init();

  try {
    await runKeysDemo();
    await runGroupsDemo();
    await runStateDemo();
    await runProposalsDemo();

    print('');
    print('All demos completed successfully!');
    print('');
  } catch (e, stackTrace) {
    print('');
    print('Error: $e');
    print('Stack trace: $stackTrace');
    print('');
  } finally {
    // dispose: true is required for CLI apps to allow the process to exit
    Openmls.cleanup(dispose: true);
  }
}
