import 'package:flutter/material.dart';

import '../../core/settings/app_settings.dart';
import '../home/home_page.dart';
import '../login/login_page.dart';
import 'welcome_page.dart';

class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.settings,
    this.hasAccount = false,
  });

  final AppSettings settings;
  final bool hasAccount;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  late final Widget _coldStartDestination;

  @override
  void initState() {
    super.initState();
    _coldStartDestination = _selectColdStartDestination();
  }

  Widget _selectColdStartDestination() {
    if (!widget.settings.guideCompleted) {
      return const WelcomePage();
    }
    if (!widget.hasAccount) {
      return const LoginPage();
    }
    return const HomePage();
  }

  @override
  Widget build(BuildContext context) => _coldStartDestination;
}
