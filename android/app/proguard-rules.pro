# Flutter embedding + generated plugin registrant: these classes are the
# entry surface into the Dart side and must survive shrinking intact.
-keep class io.flutter.** { *; }
-keep class dev.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# App-side Kotlin: platform channels are invoked by name through
# MainActivity/plugin registrants; keep them whole.
-keep class io.github.lopution.** { *; }

# Kotlin metadata is not needed at runtime (no kotlin-reflect usage).
-dontwarn kotlin.**

# Plugins rely on their own consumer rules where they ship them; platform
# channel calls are name-based so plugin classes may be shrunk as long as
# the registrant keeps entry points — the io.flutter.plugins.** keep above
# covers first-party plugins. Third-party plugin classes that use
# reflection internally are kept below conservatively:
-keep class com.pichillilorenzo.** { *; }
-keep class com.tekartik.** { *; }
-keep class com.it_nomads.** { *; }
-keep class com.baseflow.** { *; }
-keep class be.tramckrijte.** { *; }
-keep class dev.fluttercommunity.** { *; }
-keep class io.sentry.** { *; }

# Flutter embedding references Play Core deferred-component classes
# optionally; they are absent outside Play Store builds.
-dontwarn com.google.android.play.core.**

# Keep attributes R8 strips that plugins/libraries may read reflectively.
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses,EnclosingMethod
