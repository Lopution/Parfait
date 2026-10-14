import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/navigation/home_destination.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;
    // Only the first destination's own root hands back to the system. Every
    // other branch root claims the back event and returns to the first.
    final first = ref.watch(
      homeArrangementProvider.select((arrangement) => arrangement.shown.first),
    );
    final atStart =
        shell.currentIndex == first.branchIndex &&
        shell.shellRouteContext.routerState.uri.path == first.rootPath;
    return PopScope<void>(
      canPop: atStart,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && shell.currentIndex != first.branchIndex) {
          shell.goBranch(first.branchIndex);
        }
      },
      child: Scaffold(
        // Keyboard overlay, not resize: this Scaffold's body is the branch
        // navigator — resizing it compresses every pushed route regardless
        // of the leaf page's own resizeToAvoidBottomInset.
        resizeToAvoidBottomInset: false,
        body: shell,
      ),
    );
  }
}
