import 'package:test/test.dart';

import '../../scripts/src/common.dart';

/// The body GitHub sends when the per-IP quota for anonymous callers is spent.
/// The status is 403, which is also what a genuine permission failure returns —
/// which is exactly why the message and the headers have to survive.
const rateLimitBody = '''
{
  "message": "API rate limit exceeded for 20.1.2.3.",
  "documentation_url": "https://docs.github.com/rest/overview/rate-limiting"
}''';

void main() {
  final url = Uri.parse(
    'https://api.github.com/repos/owner/repo/releases/latest',
  );

  group('describeGithubFailure', () {
    test("keeps the status, the URL and GitHub's own explanation", () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 403,
        body: rateLimitBody,
        authenticated: false,
      );

      expect(message, contains('403'));
      expect(message, contains(url.toString()));
      expect(message, contains('API rate limit exceeded for 20.1.2.3.'));
    });

    test('names the exhausted quota and when it resets', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 403,
        body: rateLimitBody,
        authenticated: false,
        rateLimitRemaining: '0',
        // 2026-08-17T11:00:00Z
        rateLimitReset: '1786964400',
      );

      expect(message, contains('Rate limit exhausted'));
      expect(message, contains('2026-08-17T11:00:00.000Z'));
    });

    test('reports that the call was anonymous, since that is the fix', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 403,
        body: rateLimitBody,
        authenticated: false,
      );

      expect(message, contains('unauthenticated'));
      expect(message, contains('GITHUB_TOKEN'));
    });

    test('does not blame the token when a token was used', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 404,
        body: '{"message":"Not Found"}',
        authenticated: true,
      );

      expect(message, contains('Not Found'));
      expect(message, isNot(contains('unauthenticated')));
    });

    test('says nothing about a quota that is not exhausted', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 404,
        body: '{"message":"Not Found"}',
        authenticated: true,
        rateLimitRemaining: '58',
        rateLimitReset: '1786964400',
      );

      expect(message, isNot(contains('Rate limit')));
    });

    test('falls back to the raw body when it is not the documented JSON', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 502,
        body: '<html><body>Bad gateway</body></html>',
        authenticated: true,
      );

      expect(message, contains('Bad gateway'));
    });

    test('truncates a body long enough to bury the rest of the report', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 502,
        body: 'x' * 5000,
        authenticated: true,
      );

      expect(message.length, lessThan(600));
      expect(message, contains('…'));
    });

    test('cuts a long body on a code point, never on half a character', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 502,
        // The emoji is the 200th code point, straddling the cut. Counted in
        // UTF-16 units — which is what `substring` counts — its two halves sit
        // on either side of it.
        body: '${'x' * 199}🙂${'x' * 500}',
        authenticated: true,
      );

      expect(message, contains('🙂'));
      expect(
        message.runes.any((r) => r >= 0xD800 && r <= 0xDFFF),
        isFalse,
        reason: 'a lone surrogate means the cut split a character in half',
      );
    });

    test('survives an empty body', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 500,
        body: '',
        authenticated: true,
      );

      expect(message, contains('500'));
      expect(message, contains(url.toString()));
    });
  });

  group('GithubApiException', () {
    test('prints the diagnosis alone, with no exception prefix', () {
      final message = describeGithubFailure(
        url: url,
        statusCode: 403,
        body: rateLimitBody,
        authenticated: false,
      );

      expect(GithubApiException(message).toString(), message);
    });
  });
}
