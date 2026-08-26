import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  static const pages = [
    Center(child: Text('推荐')),
    Center(child: Text('排行榜')),
    Center(child: Text('新作')),
    Center(child: Text('搜索')),
    Center(child: Text('设置')),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          children: List.generate(5, (i) {
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
                    [
                      Icons.home,
                      Icons.emoji_events,
                      Icons.new_releases,
                      Icons.search,
                      Icons.settings,
                    ][i],
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
    );
  }
}
