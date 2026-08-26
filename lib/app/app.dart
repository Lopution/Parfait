import 'package:flutter/material.dart';

import 'theme/replica_theme.dart';

class PixivFuncApp extends StatelessWidget {
  const PixivFuncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pixiv Func',
      debugShowCheckedModeBanner: false,
      theme: replicaTheme(Brightness.light),
      darkTheme: replicaTheme(Brightness.dark),
      home: const Scaffold(
        body: Center(
          child: Text('Pixiv Func Replica'),
        ),
      ),
    );
  }
}
