import 'package:flutter/material.dart';

import '../../app/navigation/replica_route.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../core/i18n/replica_strings.dart';
import 'language_page.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return ReplicaScaffold(
      child: Padding(
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
              child: ReplicaButton(
                label: '开始',
                backgroundColor: FuncTokens.primary,
                foregroundColor: Colors.white,
                onPressed: () => Navigator.of(context).push(
                  replicaRoute((context) => const LanguagePage()),
                ),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
