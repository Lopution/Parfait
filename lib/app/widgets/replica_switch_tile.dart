import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class ReplicaSwitchTile extends StatelessWidget {
  const ReplicaSwitchTile({
    super.key,
    required this.value,
    required this.title,
    required this.onTap,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  final bool value;
  final Widget title;
  final VoidCallback onTap;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: contentPadding,
        child: Row(
          children: [
            Expanded(child: title),
            CupertinoSwitch(
              value: value,
              activeTrackColor: Theme.of(context).colorScheme.primary,
              onChanged: (_) => onTap(),
            ),
          ],
        ),
      ),
    );
  }
}
