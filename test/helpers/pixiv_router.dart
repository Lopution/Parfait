import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:parfait/app/navigation/routes.dart';

/// The app's router at [initialLocation], disposed when the test ends.
GoRouter pixivRouter(String initialLocation) {
  final router = createPixivRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);
  return router;
}
