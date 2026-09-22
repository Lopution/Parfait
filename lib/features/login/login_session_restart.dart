import '../../core/auth/oauth_service.dart';

/// Restarts the PKCE login session in place after a fatal error.
///
/// [OAuthService.beginSession] discards the previous verifier internally,
/// so callers only need to load the returned authorize URL into their
/// WebView. Shared by the mobile and desktop login pages so both ends
/// restart the session identically instead of re-opening the route.
Uri restartLoginSession(OAuthService oauthService) =>
    oauthService.beginSession().authorizeUrl;
