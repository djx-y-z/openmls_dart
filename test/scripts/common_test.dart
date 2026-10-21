import 'dart:io';

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

    // This function only ever runs while a failure is already being reported,
    // so a throw here costs the diagnosis and replaces it with noise about the
    // diagnosis. `x-ratelimit-reset` is only trustworthy when GitHub wrote it;
    // an intermediary or a proxy error page can put anything there, and
    // `int.tryParse` accepts up to 2^63 while `* 1000` wraps silently.
    for (final hostile in const [
      '99999999999999999', // wraps, then DateTime throws RangeError
      '9223372036854775807', // wraps to 1969 — a silent lie, not a crash
      '-9999999999999999',
      '0x10', // int.tryParse reads this as 16 without an explicit radix
      'not-a-number',
      '',
    ]) {
      test('survives an unusable x-ratelimit-reset: "$hostile"', () {
        String? message;
        expect(
          () => message = describeGithubFailure(
            url: url,
            statusCode: 403,
            body: rateLimitBody,
            authenticated: true,
            rateLimitRemaining: '0',
            rateLimitReset: hostile,
          ),
          returnsNormally,
        );

        // The quota is still reported — only the timestamp is dropped.
        expect(message, contains('Rate limit exhausted'));
        expect(message, isNot(contains(' until ')));
        expect(message, contains('API rate limit exceeded for 20.1.2.3.'));
      });
    }

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

  group('githubApiGet', () {
    late HttpServer server;

    setUp(() async {
      server = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
        ..listen((request) async {
          final response = request.response;
          if (request.uri.path == '/ok') {
            response.write('{"tag_name":"v1.2.3"}');
          } else {
            // Not valid UTF-8. An error page from something in front of the
            // API is the realistic source — the API itself always sends JSON.
            response
              ..statusCode = 500
              ..add([0xff, 0xfe, 0x41, 0x42]);
          }
          await response.close();
        });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    Future<String> get(String path) => githubApiGet(
      at(path),
      accept: 'application/vnd.github.v3+json',
      userAgent: 'common-test',
    );

    test('returns the body on 200', () async {
      expect(await get('/ok'), '{"tag_name":"v1.2.3"}');
    });

    // The decode happens before the status code is read, so a strict decoder
    // throws `FormatException` and takes the status and the URL with it —
    // less than the bare status code this function was written to replace,
    // and not the type its contract promises.
    test('keeps the status and the URL when the body is not UTF-8', () async {
      await expectLater(
        get('/broken'),
        throwsA(
          isA<GithubApiException>()
              .having((e) => e.message, 'message', contains('500'))
              .having((e) => e.message, 'message', contains('/broken')),
        ),
      );
    });
  });
}
