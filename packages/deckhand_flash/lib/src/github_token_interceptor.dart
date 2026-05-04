import 'package:deckhand_core/deckhand_core.dart';
import 'package:dio/dio.dart';

/// Dio interceptor that injects the user's saved GitHub PAT as a
/// Bearer-Authorization header on every outbound request to
/// `api.github.com`. No-op for any other host so we don't leak the
/// token to non-GitHub upstreams.
///
/// The token is read fresh from [SecurityService] per request so a
/// "save token / clear token" toggle in Settings takes effect on the
/// next API call without restarting the app or rebuilding the Dio.
///
/// When no token is set, requests still go through unauthenticated —
/// GitHub's 60/hour anonymous quota is fine for a single install. The
/// preflight `github_rate_limit` check warns the user when they're
/// close to the wall.
class GitHubTokenInterceptor extends Interceptor {
  GitHubTokenInterceptor(this.security);

  final SecurityService security;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final host = options.uri.host.toLowerCase();
    if (host != 'api.github.com') {
      handler.next(options);
      return;
    }
    final token = await security.getGitHubToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
      // GitHub requests with a PAT consume the authenticated
      // 5000/hour bucket instead of the anonymous 60/hour one.
    }
    handler.next(options);
  }
}
