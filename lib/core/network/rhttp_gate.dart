/// Global readiness gate for the rhttp Rust transport.
///
/// [main] starts `rhttp.Rhttp.init()` without blocking the first frame, and
/// every network exit waits on [ready] before creating a client. This lets
/// the UI render (settings/account restore) while the native transport
/// loads, instead of serialising them behind `runApp`.
class RhttpGate {
  RhttpGate._();

  static Future<void>? ready;
}
