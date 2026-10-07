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
  });

  final Widget child;
  final Widget? title;
  final bool centerTitle;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppTopBar(
        title: title,
        centerTitle: centerTitle,
        automaticallyImplyLeading: false,
        actions: actions,
        bottom: bottom,
        leading: canPop
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                // The platform's back glyph, as every BackButton (U1).
                icon: const BackButtonIcon(),
              )
            : null,
      ),
      body: SafeArea(top: false, child: child),
      floatingActionButton: floatingActionButton,
    );
  }
}
