/// Typed option enums persisted by [AppSettings]. Re-exported from
/// `app_settings.dart` so consumers keep a single import.
library;

/// Non-secret translation provider selection. Credentials, when a later
/// translation feature needs them, are referenced from secure storage only.
enum TranslationProvider {
  google(0),
  disabled(1),
  baidu(2),
  translationLlm(3),

  /// Public Bilibili Index Translate endpoint. Code 4 was the retired
  /// Doubao provider and is deliberately not reused for migration safety.
  indexTranslate(5);

  const TranslationProvider(this.code);

  final int code;

  static TranslationProvider? fromCode(Object? value) {
    if (value is! int) return null;
    for (final provider in values) {
      if (provider.code == value) return provider;
    }
    return null;
  }
}

/// Public Index Translate model choices. The wire names are part of the
/// endpoint contract; the numeric codes are the local settings contract.
enum IndexTranslateModel {
  twoB(0, 'Index-Translate-2B'),
  nineB(1, 'Index-Translate-9B'),
  thirtyFiveBA3B(2, 'Index-Translate-35B-A3B');

  const IndexTranslateModel(this.code, this.modelName);

  final int code;
  final String modelName;

  static IndexTranslateModel? fromCode(Object? value) {
    if (value is! int) return null;
    for (final model in values) {
      if (model.code == value) return model;
    }
    return null;
  }
}

/// Preview (feed card) image quality (D4). Default [medium].
///
/// Feed APIs only provide `image_urls.medium/large` — there is no original
/// URL in list payloads, so original is deliberately not an option (an
/// "original" preview would silently show large).
enum PreviewQuality {
  medium(0),
  large(1);

  const PreviewQuality(this.code);

  final int code;

  static PreviewQuality fromCode(Object? value) {
    if (value is int) {
      // Legacy saved value (code 2 = original) migrates to large: the old
      // setting already displayed large in practice.
      if (value == 2) return PreviewQuality.large;
      for (final quality in values) {
        if (quality.code == value) return quality;
      }
    }
    return PreviewQuality.medium;
  }

  /// Legacy bool migration: `true` -> large, `false` -> medium.
  static PreviewQuality fromLegacyBool(Object? value) =>
      value == true ? PreviewQuality.large : PreviewQuality.medium;
}

/// Viewer image quality (D4). Default [original].
enum ViewQuality {
  medium(0),
  large(1),
  original(2);

  const ViewQuality(this.code);

  final int code;

  static ViewQuality fromCode(Object? value) {
    if (value is int) {
      for (final quality in values) {
        if (quality.code == value) return quality;
      }
    }
    return ViewQuality.original;
  }

  /// Legacy bool migration: `true` -> original, `false` -> large.
  static ViewQuality fromLegacyBool(Object? value) =>
      value == true ? ViewQuality.original : ViewQuality.large;
}

/// Detail-page main image quality (三档之详情档). Default [large]; the
/// medium option is available for code compatibility but served as large
/// because a 540px image is unreadable as the detail hero.
enum DetailQuality {
  medium(0),
  large(1),
  original(2);

  const DetailQuality(this.code);

  final int code;

  static DetailQuality fromCode(Object? value) {
    if (value is int) {
      for (final quality in values) {
        if (quality.code == value) return quality;
      }
    }
    return DetailQuality.large;
  }
}

/// Animation speed: every UI animation length is scaled by [factor] (read
/// through `MotionTokens.resolve`). Persisted by [code], the Android page
/// transition length in milliseconds at this tier — the setting started
/// out as a page-transition speed, and keeping the code avoids a
/// migration. Unknown codes fall back to [normal]. Reduce-motion collapses
/// the resolved duration to zero regardless of the tier.
enum AnimationSpeed {
  fast(250),
  normal(350),
  slow(450);

  const AnimationSpeed(this.code);

  final int code;

  /// Multiplier on every base duration; [normal] is 1.
  double get factor => code / normal.code;

  static AnimationSpeed fromCode(Object? value) {
    if (value is int) {
      for (final speed in values) {
        if (speed.code == value) return speed;
      }
    }
    return AnimationSpeed.normal;
  }
}

/// How many columns the illustration grids fit: [standard] is two on a
/// phone, [compact] three for quick scanning, [comfortable] one for slow
/// looking. Consumed by `illustColumnsFor`. Persisted by [name].
enum FeedDensity {
  compact,
  standard,
  comfortable;

  static FeedDensity? tryFromName(Object? value) {
    if (value is! String) return null;
    for (final density in values) {
      if (density.name == value) return density;
    }
    return null;
  }
}

/// How opening an artwork card behaves on wide desktop viewports.
enum DesktopDetailMode {
  modal,
  inspector;

  static DesktopDetailMode? tryFromName(Object? value) {
    if (value is! String) return null;
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

/// App haptic strength. [off] plays nothing; on Android the other tiers pick
/// per-device effects (primitive amplitude, predefined effect, or the
/// strength-less system constant). Persisted by [name].
enum HapticStrength {
  off,
  light,
  standard,
  strong;

  static HapticStrength? tryFromName(Object? value) {
    if (value is! String) return null;
    for (final strength in values) {
      if (strength.name == value) return strength;
    }
    return null;
  }
}

/// The shell a large screen gets on a desktop (「界面形态」): [auto] is the
/// platform's own (a PC on Windows, Linux and macOS, touch on a large
/// Android screen), [touch] the touch large-screen shell on a desktop (a
/// Windows tablet, or checking that shell in a window). Offered only on
/// desktops. Persisted by [name].
enum InterfaceForm {
  auto,
  touch,
  pc;

  static InterfaceForm? tryFromName(Object? value) {
    if (value is! String) return null;
    for (final form in values) {
      if (form.name == value) return form;
    }
    return null;
  }
}

/// How the normal network stack routes traffic (D3). Only the user choice is
/// persisted; route memory and probe results are never saved.
enum NetworkMode {
  automatic(0),
  directOnly(1),
  compatPrefer(2);

  const NetworkMode(this.code);

  final int code;

  static NetworkMode? tryFromCode(Object? value) {
    if (value is int) {
      for (final mode in values) {
        if (mode.code == value) return mode;
      }
    }
    return null;
  }

  static NetworkMode fromCode(Object? value) {
    return tryFromCode(value) ?? NetworkMode.automatic;
  }
}
