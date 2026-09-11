import 'package:material_ui/material_ui.dart';

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
      appBar: AppBar(
        elevation: 0,
        title: title,
        centerTitle: centerTitle,
        automaticallyImplyLeading: false,
        actions: actions,
        bottom: bottom,
        leading: canPop
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_ios_new),
              )
            : null,
      ),
      body: SafeArea(top: false, child: child),
      floatingActionButton: floatingActionButton,
    );
  }
}
