import 'package:flutter/material.dart';

class ReplicaButton extends StatelessWidget {
  const ReplicaButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
    this.borderColor,
  });

  final String label;
  final VoidCallback onPressed;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(40);
    return Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: borderColor == null
            ? BorderSide.none
            : BorderSide(color: borderColor!),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: foregroundColor,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
