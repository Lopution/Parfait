/// Short-lived in-memory secret holder for one account.
///
/// Never log this object: [toString] is intentionally redacted so accidental
/// interpolation cannot leak tokens into logs or test snapshots.
class Credential {
  const Credential({
    required this.accessToken,
    required this.refreshToken,
    this.cookie,
  });

  final String accessToken;
  final String refreshToken;

  /// Session cookie, when the login flow provides one.
  final String? cookie;

  @override
  String toString() =>
      'Credential(accessToken: ███, refreshToken: ███, cookie: ${cookie == null ? 'null' : '███'})';
}
