import 'package:flutter/material.dart';

class ReplicaScaffold extends StatelessWidget {
  const ReplicaScaffold({
    super.key,
    required this.child,
    this.title,
    this.centerTitle = true,
  });

  final Widget child;
  final Widget? title;
  final bool centerTitle;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: title,
        centerTitle: centerTitle,
        automaticallyImplyLeading: false,
        leading: canPop
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Icon(Icons.arrow_back_ios_new),
                ),
              )
            : null,
      ),
      body: SafeArea(top: false, child: child),
    );
  }
}
