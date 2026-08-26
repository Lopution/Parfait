import 'package:flutter/material.dart';

import '../../app/theme/func_tokens.dart';
import '../../core/i18n/replica_strings.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: width * .1),
      child: Column(
        children: [
          const Spacer(),
          Text(
            ReplicaStrings.text(ReplicaLanguage.zhCN, 'welcome1'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Text(
            ReplicaStrings.text(ReplicaLanguage.zhCN, 'welcome2'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const Spacer(flex: 2),
          SizedBox(
            width: double.infinity,
            child: MaterialButton(
              elevation: 0,
              color: FuncTokens.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(40),
              ),
              padding: const EdgeInsets.symmetric(vertical: 20),
              onPressed: onStart,
              child: const Text(
                '开始',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
