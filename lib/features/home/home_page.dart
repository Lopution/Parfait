import 'package:flutter/material.dart';

import 'recommended/recommended_illust_page.dart';

import '../../app/icons/app_icons.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  static const pages = [
    RecommendedIllustPage(),
    Center(child: Text('排行榜')),
    Center(child: Text('新作')),
    Center(child: Text('搜索')),
    Center(child: Text('设置')),
  ];

  static const icons = [
    AppIcons.home,
    AppIcons.ranking,
    AppIcons.n,
    AppIcons.search,
    Icons.settings,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: BottomAppBar(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: List.generate(icons.length, (i) {
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => index = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 5,
                      horizontal: 10,
                    ),
                    child: Icon(
                      icons[i],
                      size: 35,
                      color: index == i
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
