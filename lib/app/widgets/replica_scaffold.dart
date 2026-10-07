import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'app_top_bar.dart';

class ReplicaScaffold extends StatelessWidget {
  const ReplicaScaffold({
    super.key,
    required this.child,
    this.title,
    this.centerTitle = true,
    this.actions,
    this.bottom,
    this.floatingActionButton,
    this.upLocation,
  });

  final Widget child;
  final Widget? title;
  final bool centerTitle;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget? floatingActionButton;

  /// Where back leads when the page was opened with nothing under it (a
  /// direct link or a restored route), so it still has a way out. Without
  /// it such a page shows no back button and system back leaves the app.
  final String? upLocation;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    final up = canPop ? null : upLocation;
    final scaffold = Scaffold(
      appBar: AppTopBar(
        title: title,
        centerTitle: centerTitle,
        automaticallyImplyLeading: false,
        actions: actions,
        bottom: bottom,
        leading: canPop || up != null
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: up == null
                    ? () => Navigator.of(context).maybePop()
                    : () => context.go(up),
                // The platform's back glyph, as every BackButton (U1).
                icon: const BackButtonIcon(),
              )
            : null,
      ),
      body: SafeArea(top: false, child: child),
      floatingActionButton: floatingActionButton,
    );
    if (up == null) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(up);
      },
      child: scaffold,
    );
  }
}
