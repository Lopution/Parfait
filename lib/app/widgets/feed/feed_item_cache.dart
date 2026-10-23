import 'package:flutter/widgets.dart';

/// Hands a feed list back the card it built for an index while the entity
/// there is the same instance and the builder's other inputs are equal, so
/// Flutter skips rebuilding that card.
///
/// Each rebuild of a feed's body gave every built card a new widget: a
/// page appended, a load-more phase change, a store merging other
/// entities. Every built card rebuilt in that frame.
class FeedItemCache {
  List<Object>? _items;
  Object? _deps;
  final _built = <int, (Object, Widget)>{};

  /// Follows [items], the entity at each index, and [deps], everything
  /// else the builder reads, compared with `==`. The builder must not read
  /// its context. Without [items] every card is built anew.
  void update(List<Object>? items, Object? deps) {
    if (items == null || deps != _deps) {
      _built.clear();
    } else {
      _built.removeWhere((index, _) => index >= items.length);
    }
    _items = items;
    _deps = deps;
  }

  /// The card at [index]: the one built before, or [builder]'s.
  Widget build(BuildContext context, int index, IndexedWidgetBuilder builder) {
    final items = _items;
    if (items == null) return builder(context, index);
    final item = items[index];
    final cached = _built[index];
    if (cached != null && identical(cached.$1, item)) return cached.$2;
    final card = builder(context, index);
    _built[index] = (item, card);
    return card;
  }
}
