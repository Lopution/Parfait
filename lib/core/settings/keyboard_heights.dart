import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preference_keys.dart';
import 'shared_preferences.dart';

/// What a panel that stands in for the soft keyboard needs to know: the
/// keyboard's height on a screen of a given shape.
abstract interface class KeyboardHeightMemory {
  /// The height last seen on a screen of [size]'s orientation and width,
  /// or null before one has been.
  double? heightFor(Size size);

  /// Keeps [height] for [size]'s shape. Heights a docked keyboard cannot
  /// have (a floating or hardware one, a half-open inset) are dropped.
  void record(Size size, double height);
}

/// The soft keyboard's height per orientation and width, kept across
/// restarts: the comment panels take it before the keyboard has shown in
/// this run. A keyboard's height depends on the screen it sits on, so a
/// rotation or a foldable's other screen keeps its own.
final keyboardHeightsProvider =
    NotifierProvider<KeyboardHeights, Map<String, double>>(KeyboardHeights.new);

class KeyboardHeights extends Notifier<Map<String, double>>
    implements KeyboardHeightMemory {
  /// Lower than any docked phone keyboard.
  static const minHeight = 160.0;

  /// Of the screen's height; a docked keyboard leaves the app more.
  static const maxShare = 0.6;

  @override
  Map<String, double> build() {
    unawaited(
      ref
          .watch(sharedPreferencesProvider)
          .getString(PreferenceKeys.keyboardHeights)
          .then((raw) {
            if (raw == null || !ref.mounted) return;
            final saved = _decode(raw);
            // A height seen in this run before the read landed is newer.
            if (saved.isNotEmpty) state = {...saved, ...state};
          }),
    );
    return const {};
  }

  static String _keyFor(Size size) =>
      '${size.width > size.height ? 'landscape' : 'portrait'}:'
      '${size.width.round()}';

  static Map<String, double> _decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return const {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (value is num && value > 0) key: value.toDouble(),
      };
    } on FormatException {
      return const {};
    }
  }

  @override
  double? heightFor(Size size) => state[_keyFor(size)];

  @override
  void record(Size size, double height) {
    if (height < minHeight || height > size.height * maxShare) return;
    final key = _keyFor(size);
    if (state[key] == height) return;
    state = {...state, key: height};
    unawaited(
      ref
          .read(sharedPreferencesProvider)
          .setString(PreferenceKeys.keyboardHeights, jsonEncode(state)),
    );
  }
}
