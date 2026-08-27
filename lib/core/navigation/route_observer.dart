import 'package:flutter/material.dart';

/// Shared observer for route-scoped foreground work such as history timing.
/// Tests may use a plain MaterialApp; history still starts on the current
/// route, while the production app supplies this observer for push/pop cover
/// events.
final replicaRouteObserver = RouteObserver<ModalRoute<dynamic>>();
