import 'package:test/test.dart';

import '../../scripts/src/ai_client.dart';

const anthropicKey = 'ANTHROPIC_API_KEY';
const geminiKey = 'GEMINI_API_KEY';

const opus = AiModel('anthropic', 'claude-opus-5');
const gemini = AiModel('google', 'gemini-3.5-flash-lite');

/// The Anthropic answer shape with adaptive thinking on: the model's own
/// reasoning arrives as a block *before* the answer, so anything that reads
/// `content[0]` gets the wrong one.
Map<String, dynamic> anthropicBody({
  String stopReason = 'end_turn',
  List<Map<String, dynamic>>? content,
}) => {
  'stop_reason': stopReason,
  'content':
      content ??
      [
        {'type': 'thinking', 'thinking': ''},
        {'type': 'text', 'text': '{"entry":"ok"}'},
      ],
  'usage': {'input_tokens': 7000, 'output_tokens': 1200},
};

Map<String, dynamic> geminiBody({
  String finishReason = 'STOP',
  List<Map<String, dynamic>>? parts,
}) => {
  'candidates': [
    {
      'finishReason': finishReason,
      'content': {
        'parts':
            parts ??
            [
              {'text': '{"entry":"ok"}'},
            ],
      },
    },
  ],
  'usageMetadata': {
    'promptTokenCount': 7000,
    'candidatesTokenCount': 900,
    'thoughtsTokenCount': 300,
  },
};

/// The OpenAI-shaped answer OpenRouter returns. Reasoning, when a model emits
/// it, arrives in its own `reasoning` field rather than inside `content`.
Map<String, dynamic> openRouterBody({
  String finishReason = 'stop',
  Object? content = '{"entry":"ok"}',
}) => {
  'choices': [
    {
      'finish_reason': finishReason,
      'message': {
        'role': 'assistant',
        'content': content,
        'reasoning': 'Let me think about this.',
      },
    },
  ],
  'usage': {'prompt_tokens': 7000, 'completion_tokens': 1200},
};

void main() {
  group('resolveAiModels', () {
    // There is no default list. A model that writes into a CHANGELOG is one
    // somebody named, and an unset list is the honest way to say "no AI here".
    test('calls nothing when the variable is unset', () {
      final resolution = resolveAiModels(rawModels: null, env: const {});

      expect(resolution.usable, isEmpty);
      expect(resolution.warnings, isEmpty);
    });

    test('treats a blank variable as unset', () {
      final resolution = resolveAiModels(rawModels: '   ', env: const {});

      expect(resolution.usable, isEmpty);
    });

    // Keys but no list is a misconfiguration, not an opt-out, and going quiet
    // there is the exact failure this design exists to avoid.
    test('warns when keys are present but no list is configured', () {
      final resolution = resolveAiModels(
        rawModels: null,
        env: const {anthropicKey: 'sk-x'},
      );

      expect(resolution.usable, isEmpty);
      expect(resolution.warnings.single, contains(anthropicKey));
      expect(resolution.warnings.single, contains('AI_MODELS'));
    });

    test('names every configured key in that warning', () {
      final resolution = resolveAiModels(
        rawModels: '',
        env: const {anthropicKey: 'sk-x', geminiKey: 'gk-x'},
      );

      expect(resolution.warnings.single, contains(anthropicKey));
      expect(resolution.warnings.single, contains(geminiKey));
    });

    // Order is the priority, so it is asserted rather than assumed.
    test('preserves configured order and tolerates whitespace', () {
      final resolution = resolveAiModels(
        rawModels: ' google/gemini-3.5-flash-lite , anthropic/claude-opus-5 ',
        env: const {anthropicKey: 'sk-x', geminiKey: 'gk-x'},
      );

      expect(resolution.usable.map((m) => m.model), [gemini, opus]);
    });

    test('ignores empty entries from a trailing or doubled comma', () {
      final resolution = resolveAiModels(
        rawModels: 'anthropic/claude-opus-5,,',
        env: const {anthropicKey: 'sk-x'},
      );

      expect(resolution.usable, hasLength(1));
      expect(resolution.warnings, isEmpty);
    });

    test('lower-cases the provider half', () {
      final resolution = resolveAiModels(
        rawModels: 'Anthropic/claude-opus-5',
        env: const {anthropicKey: 'sk-x'},
      );

      expect(resolution.usable.single.model.provider, 'anthropic');
    });

    // A model name may contain slashes; only the first one splits the entry.
    test('splits on the first slash only', () {
      final resolution = resolveAiModels(
        rawModels: 'google/models/gemini-x',
        env: const {geminiKey: 'gk-x'},
      );

      expect(resolution.usable.single.model.model, 'models/gemini-x');
    });

    // Skipping is how the list expresses "use this if it is available", so it
    // is deliberately quiet — unlike the two cases below.
    test('silently skips a known provider whose key is absent', () {
      final resolution = resolveAiModels(
        rawModels: 'anthropic/claude-opus-5,google/gemini-3.5-flash-lite',
        env: const {geminiKey: 'gk-x'},
      );

      expect(resolution.usable.single.model, gemini);
      expect(resolution.skipped, [opus]);
      expect(resolution.warnings, isEmpty);
    });

    // A typo must never look like a configuration choice: that is exactly the
    // failure mode this design exists to avoid.
    test('warns about an unknown provider instead of skipping quietly', () {
      final resolution = resolveAiModels(
        rawModels: 'anthropc/claude-opus-5,google/gemini-3.5-flash-lite',
        env: const {geminiKey: 'gk-x'},
      );

      expect(resolution.usable.single.model, gemini);
      expect(resolution.skipped, isEmpty);
      expect(resolution.warnings.single, contains('anthropc'));
    });

    test('warns about entries that are not provider/model', () {
      final resolution = resolveAiModels(
        rawModels: 'claude-opus-5,/model,anthropic/',
        env: const {anthropicKey: 'sk-x'},
      );

      expect(resolution.usable, isEmpty);
      expect(resolution.warnings, hasLength(3));
    });

    test('ignores a key set to the empty string', () {
      final resolution = resolveAiModels(
        rawModels: 'anthropic/claude-opus-5',
        env: const {anthropicKey: '  '},
      );

      expect(resolution.usable, isEmpty);
      expect(resolution.skipped, [opus]);
    });

    test('trims the key it reads', () {
      final resolution = resolveAiModels(
        rawModels: 'anthropic/claude-opus-5',
        env: const {anthropicKey: ' sk-x\n'},
      );

      expect(resolution.usable.single.apiKey, 'sk-x');
    });

    // One variable per provider, and nothing else: a key is read only from
    // the variable its own provider owns.
    test('reads a key only from its own provider variable', () {
      final resolution = resolveAiModels(
        rawModels: 'anthropic/claude-opus-5,google/gemini-3.5-flash-lite',
        env: const {anthropicKey: 'sk-x'},
      );

      expect(resolution.usable.single.model, opus);
      expect(resolution.usable.single.apiKey, 'sk-x');
      expect(resolution.skipped, [gemini]);
    });
  });

  group('schemas', () {
    // Anthropic and Gemini reject each other's shape, which is why the two are
    // built separately rather than shared. OpenRouter takes the Anthropic one.
    test('the Anthropic shape carries additionalProperties: false', () {
      final schema = strictJsonSchema(const {'entry': 'One list item.'});

      expect(schema['additionalProperties'], isFalse);
      expect(schema['required'], ['entry']);
      expect((schema['properties']! as Map)['entry'], {
        'type': 'string',
        'description': 'One list item.',
      });
    });

    test('the Gemini shape omits additionalProperties and pins order', () {
      final schema = geminiResponseSchema(const {
        'highlight': 'A Highlights line.',
        'changed': 'A Changed entry.',
      });

      expect(schema.containsKey('additionalProperties'), isFalse);
      expect(schema['propertyOrdering'], ['highlight', 'changed']);
      expect(schema['required'], ['highlight', 'changed']);
    });
  });

  group('decodeAiJsonObject', () {
    test('reads a plain object', () {
      expect(decodeAiJsonObject('{"entry":"ok"}'), {'entry': 'ok'});
    });

    test('reads an object wrapped in a markdown fence', () {
      expect(decodeAiJsonObject('```json\n{"entry":"ok"}\n```'), {
        'entry': 'ok',
      });
    });

    test('reads an object with prose around it', () {
      expect(
        decodeAiJsonObject('Here you go:\n{"entry":"ok"}\nHope that helps.'),
        {'entry': 'ok'},
      );
    });

    // The extraction is for stragglers around a complete object, never a net
    // for a truncated one.
    test('returns null for a truncated object', () {
      expect(decodeAiJsonObject('{"entry":"half of a sen'), isNull);
    });

    test('returns null for a non-object', () {
      expect(decodeAiJsonObject('["entry"]'), isNull);
      expect(decodeAiJsonObject('not json at all'), isNull);
    });
  });

  group('parseOpenRouterResponse', () {
    const route = AiModel('openrouter', 'anthropic/claude-opus-5');
    AiResponse parse(Map<String, dynamic> body) =>
        parseOpenRouterResponse(body: body, model: route, maxTokens: 16000);

    test('reads the answer text', () {
      expect(parse(openRouterBody()).text, '{"entry":"ok"}');
    });

    test('reports usage', () {
      final usage = parse(openRouterBody()).usage;
      expect(usage?.inputTokens, 7000);
      expect(usage?.outputTokens, 1200);
    });

    // Unlike the other two, OpenRouter reports an upstream failure as an error
    // object inside an otherwise successful response. Checking the status only
    // would read this as a valid answer.
    test('rejects an error object carried in a 200 body', () {
      expect(
        () => parse({
          'error': {'code': 429, 'message': 'rate limited upstream'},
        }),
        throwsA(
          isA<AiAttemptException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.reason, 'reason', contains('rate limited')),
        ),
      );
    });

    // Out of credits is a routing problem for this entry, not a bad request.
    test('retries when the account is out of credits', () {
      expect(
        () => parse({
          'error': {'code': 402, 'message': 'insufficient credits'},
        }),
        throwsA(
          isA<AiAttemptException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });

    test('rejects a response truncated at the token limit', () {
      expect(
        () => parse(
          openRouterBody(
            finishReason: 'length',
            content: '{"entry":"half of a sen',
          ),
        ),
        throwsA(
          isA<AiAttemptException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.reason, 'reason', contains('truncated')),
        ),
      );
    });

    test('rejects a content filter stop', () {
      expect(
        () => parse(openRouterBody(finishReason: 'content_filter')),
        throwsA(
          isA<AiAttemptException>().having(
            (e) => e.reason,
            'reason',
            contains('content_filter'),
          ),
        ),
      );
    });

    // The OpenAI shape allows a null content, which must not reach jsonDecode.
    test('rejects a null content', () {
      expect(
        () => parse(openRouterBody(content: null)),
        throwsA(isA<AiAttemptException>()),
      );
    });
  });

  group('redactSecret', () {
    // Failure text quotes the provider's response body and reaches logs and
    // pull-request output. None of the three providers echo the key back, but
    // that is their choice of wording — this makes it ours.
    test('removes the key from text that would be logged', () {
      expect(
        redactSecret('HTTP 401: bad key sk-ant-secret123', 'sk-ant-secret123'),
        'HTTP 401: bad key <redacted>',
      );
    });

    test('removes every occurrence', () {
      expect(redactSecret('a KEY b KEY', 'KEY'), 'a <redacted> b <redacted>');
    });

    // Guard against the degenerate case: an empty secret would otherwise match
    // between every character and destroy the message.
    test('leaves text alone when the secret is empty', () {
      expect(redactSecret('HTTP 500: upstream', ''), 'HTTP 500: upstream');
    });
  });

  group('isTransportFailure', () {
    test('retries auth, rate-limit and server statuses', () {
      for (final status in [401, 403, 408, 429, 500, 503, 529]) {
        expect(isTransportFailure(status, ''), isTrue, reason: '$status');
      }
    });

    // A request this client got wrong must stop the walk, or the next provider
    // answering would hide it permanently.
    test('does not retry a malformed request or a missing model', () {
      for (final status in [400, 404, 413, 422]) {
        expect(isTransportFailure(status, ''), isFalse, reason: '$status');
      }
    });

    // Observed against the live API: Google answers an invalid key with 400,
    // where Anthropic uses 401. Read as a bad request, a misconfigured key in
    // the first list entry would stop the walk before the second is tried.
    test('retries a 400 that names an invalid API key', () {
      const googleBody = '''
{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT",
"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo",
"reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}''';

      expect(isTransportFailure(400, googleBody), isTrue);
    });

    test('retries a 400 whose status is UNAUTHENTICATED', () {
      expect(
        isTransportFailure(400, '{"error":{"status":"UNAUTHENTICATED"}}'),
        isTrue,
      );
    });

    // The carve-out stays narrow: every other 400 remains fatal.
    test('still refuses to retry an ordinary 400', () {
      expect(
        isTransportFailure(
          400,
          '{"error":{"status":"INVALID_ARGUMENT","message":"bad field"}}',
        ),
        isFalse,
      );
      expect(isTransportFailure(400, 'not json at all'), isFalse);
    });
  });

  group('parseAnthropicResponse', () {
    AiResponse parse(Map<String, dynamic> body) =>
        parseAnthropicResponse(body: body, model: opus, maxTokens: 16000);

    // With thinking on the answer is never content[0].
    test('reads the text block past a leading thinking block', () {
      expect(parse(anthropicBody()).text, '{"entry":"ok"}');
    });

    test('reports usage', () {
      expect(parse(anthropicBody()).usage?.outputTokens, 1200);
    });

    // A truncated answer is an unterminated JSON fragment. Salvaging it is how
    // a broken entry reaches a CHANGELOG unnoticed.
    test('rejects a response truncated at the token limit', () {
      expect(
        () => parse(
          anthropicBody(
            stopReason: 'max_tokens',
            content: [
              {'type': 'text', 'text': '{"entry":"half of a sen'},
            ],
          ),
        ),
        throwsA(
          isA<AiAttemptException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.reason, 'reason', contains('truncated')),
        ),
      );
    });

    test('rejects a refusal before reading content', () {
      expect(
        () => parse(anthropicBody(stopReason: 'refusal', content: const [])),
        throwsA(
          isA<AiAttemptException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.reason, 'reason', contains('refusal')),
        ),
      );
    });

    test('rejects a response with thinking but no answer', () {
      expect(
        () => parse(
          anthropicBody(
            content: [
              {'type': 'thinking', 'thinking': 'still going'},
            ],
          ),
        ),
        throwsA(isA<AiAttemptException>()),
      );
    });

    // A shape this client does not understand is a bug in the client, not a
    // provider outage, so the next model must not paper over it.
    test('does not retry an unrecognised body shape', () {
      expect(
        () => parse({'stop_reason': 'end_turn', 'content': 'oops'}),
        throwsA(
          isA<AiAttemptException>().having(
            (e) => e.retryable,
            'retryable',
            isFalse,
          ),
        ),
      );
    });
  });

  group('parseGeminiResponse', () {
    AiResponse parse(Map<String, dynamic> body) =>
        parseGeminiResponse(body: body, model: gemini, maxTokens: 16000);

    test('reads the answer text', () {
      expect(parse(geminiBody()).text, '{"entry":"ok"}');
    });

    test('counts thinking tokens as output', () {
      expect(parse(geminiBody()).usage?.outputTokens, 1200);
    });

    // Reasoning models return their own thinking as parts flagged `thought`;
    // concatenating those would corrupt the JSON.
    test('drops parts flagged as thought', () {
      final response = parse(
        geminiBody(
          parts: [
            {'text': 'Let me think about this.', 'thought': true},
            {'text': '{"entry":"ok"}'},
          ],
        ),
      );

      expect(response.text, '{"entry":"ok"}');
    });

    test('rejects a response truncated at the token limit', () {
      expect(
        () => parse(
          geminiBody(
            finishReason: 'MAX_TOKENS',
            parts: [
              {'text': '{"entry":"half of a sen'},
            ],
          ),
        ),
        throwsA(
          isA<AiAttemptException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.reason, 'reason', contains('truncated')),
        ),
      );
    });

    test('rejects a safety stop', () {
      expect(
        () => parse(geminiBody(finishReason: 'SAFETY', parts: const [])),
        throwsA(
          isA<AiAttemptException>().having(
            (e) => e.reason,
            'reason',
            contains('SAFETY'),
          ),
        ),
      );
    });

    test('reports a blocked prompt by name', () {
      expect(
        () => parse({
          'candidates': <Object?>[],
          'promptFeedback': {'blockReason': 'OTHER'},
        }),
        throwsA(
          isA<AiAttemptException>().having(
            (e) => e.reason,
            'reason',
            contains('OTHER'),
          ),
        ),
      );
    });
  });
}
