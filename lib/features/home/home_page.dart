import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;
    // Only the start destination's own root hands back to the system. Every
    // other branch root claims the back event and returns to Recommended.
    final atStart =
        shell.currentIndex == 0 &&
        shell.shellRouteContext.routerState.uri.path == '/recommended';
    return PopScope<void>(
      canPop: atStart,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && shell.currentIndex != 0) shell.goBranch(0);
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
