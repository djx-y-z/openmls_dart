// Provider-agnostic client for the AI-written CHANGELOG entries.
//
// Which model writes an entry is configuration, not code: `AI_MODELS` holds an
// ordered list of `provider/model` entries and the first one that has a key and
// answers wins. Changing provider is then a repository-variable edit rather
// than a code change that has to reach every generated project through a
// template release — which is exactly the cost the previous provider's
// retirement imposed.
//
// Deliberately carries no project- or upstream-specific naming: the prompts and
// the field names of the answer belong to the callers, so this file is shared
// byte-identically by every project generated from the template.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'common.dart';

/// Variable holding the ordered `provider/model` list.
const aiModelsEnvVar = 'AI_MODELS';

/// A list to show in help text and errors. **Not** a default.
///
/// There is deliberately no default: when [aiModelsEnvVar] is unset nothing is
/// called. A model that writes into a repository's CHANGELOG should be one
/// somebody named, not one a template picked — and an unset list is then also
/// the honest way to say "no AI here", rather than a provider quietly waiting
/// for a key to appear.
const aiModelsExample = 'anthropic/claude-opus-5,google/gemini-3.5-flash-lite';

/// Providers this client can talk to, mapped to the variable holding their key.
///
/// `openrouter` is an aggregator rather than a first party: its model half is
/// itself a `vendor/model` pair, so an entry reads
/// `openrouter/anthropic/claude-opus-5`. That parses because an entry splits on
/// its **first** slash only.
const aiProviderKeyEnvVars = <String, String>{
  'anthropic': 'ANTHROPIC_API_KEY',
  'google': 'GEMINI_API_KEY',
  'openrouter': 'OPENROUTER_API_KEY',
};

/// Optional override for how hard the model is asked to think.
///
/// Same reason [aiModelsEnvVar] exists: the cost/quality trade-off of a
/// once-a-week CHANGELOG entry is an operational decision, and pinning it in
/// code would make retuning it a template release.
const aiEffortEnvVar = 'AI_EFFORT';

/// Effort used when [aiEffortEnvVar] is unset.
const defaultAiEffort = 'medium';

/// Accepted [aiEffortEnvVar] values, cheapest first.
const aiEffortLevels = <String>['low', 'medium', 'high', 'xhigh', 'max'];

/// Reads [aiEffortEnvVar] from [env], or null when it is not configured.
///
/// Null and [defaultAiEffort] are deliberately different: a provider whose
/// support for a reasoning knob varies by route is sent nothing at all unless
/// someone asked for a level, so the default path cannot be rejected over a
/// parameter nobody set.
///
/// An unrecognised value is refused rather than passed through: the provider
/// would reject it with a 400, which this client treats as fatal — so a typo
/// here would stop the entry being written at all.
String? resolveAiEffort(Map<String, String> env) {
  final raw = _nonEmpty(env[aiEffortEnvVar])?.toLowerCase();
  if (raw == null) return null;
  if (!aiEffortLevels.contains(raw)) {
    logWarn(
      '$aiEffortEnvVar="$raw" is not one of ${aiEffortLevels.join(', ')} — '
      'using $defaultAiEffort.',
    );
    return defaultAiEffort;
  }
  return raw;
}

/// One `provider/model` entry from [aiModelsEnvVar].
class AiModel {
  /// Creates an entry from its two already-split halves.
  const AiModel(this.provider, this.model);

  /// Provider identifier, e.g. `anthropic`. Always lower-case.
  final String provider;

  /// Provider-specific model identifier, e.g. `claude-opus-5`.
  final String model;

  /// The entry as it appears in [aiModelsEnvVar].
  String get id => '$provider/$model';

  @override
  String toString() => id;

  @override
  bool operator ==(Object other) =>
      other is AiModel && other.provider == provider && other.model == model;

  @override
  int get hashCode => Object.hash(provider, model);
}

/// An [AiModel] paired with the key that will authenticate it.
class ResolvedAiModel {
  /// Binds [model] to the [apiKey] that will authenticate it.
  const ResolvedAiModel({required this.model, required this.apiKey});

  /// The configured entry.
  final AiModel model;

  /// Key sent to the provider. Never logged.
  final String apiKey;
}

/// What [resolveAiModels] made of the configured list.
class AiModelResolution {
  /// Records the three outcomes an entry can have.
  const AiModelResolution({
    required this.usable,
    required this.skipped,
    required this.warnings,
  });

  /// Entries that have a key, in configured order. The call order.
  final List<ResolvedAiModel> usable;

  /// Entries naming a known provider whose key is absent.
  ///
  /// Not a fault: an entry left in the list for a provider this repository has
  /// no key for is how the list expresses "use this if it is available".
  final List<AiModel> skipped;

  /// Entries that could not be used at all, each with the reason.
  ///
  /// A malformed entry or an unknown provider is a typo, not a configuration
  /// choice, and silently dropping it would reproduce the failure this whole
  /// change exists to avoid: AI entries stopping with nothing saying why.
  final List<String> warnings;

  /// Whether any model can be called.
  bool get isEmpty => usable.isEmpty;
}

/// Splits [rawModels] and pairs each entry with its key from [env].
///
/// Pure — [env] is injected rather than read from [Platform] — so the ordering
/// and fallback rules are testable. Order is preserved: it *is* the priority.
AiModelResolution resolveAiModels({
  required String? rawModels,
  required Map<String, String> env,
}) {
  final usable = <ResolvedAiModel>[];
  final skipped = <AiModel>[];
  final warnings = <String>[];

  final source = rawModels?.trim() ?? '';
  if (source.isEmpty) {
    // Nothing configured, nothing called. But a repository holding keys and no
    // list is misconfigured rather than opted out, and saying so follows the
    // same rule as the rest of this function: a choice is silent, a mistake is
    // not.
    final present = aiProviderKeyEnvVars.values
        .where((name) => _nonEmpty(env[name]) != null)
        .toList();
    if (present.isNotEmpty) {
      warnings.add(
        '$aiModelsEnvVar is not set, so no AI model will be called — even '
        'though ${present.join(', ')} ${present.length == 1 ? 'is' : 'are'} '
        'present. Set $aiModelsEnvVar to a `provider/model` list, e.g. '
        '"$aiModelsExample".',
      );
    }
    return AiModelResolution(
      usable: usable,
      skipped: skipped,
      warnings: warnings,
    );
  }

  final entries = source
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  for (final entry in entries) {
    final slash = entry.indexOf('/');
    if (slash <= 0 || slash == entry.length - 1) {
      warnings.add(
        '$aiModelsEnvVar entry "$entry" is not in `provider/model` form — '
        'ignored.',
      );
      continue;
    }

    final model = AiModel(
      entry.substring(0, slash).toLowerCase(),
      entry.substring(slash + 1),
    );

    final keyVar = aiProviderKeyEnvVars[model.provider];
    if (keyVar == null) {
      warnings.add(
        '$aiModelsEnvVar entry "$entry" names unknown provider '
        '"${model.provider}" — ignored. Known providers: '
        '${(aiProviderKeyEnvVars.keys.toList()..sort()).join(', ')}.',
      );
      continue;
    }

    final key = _nonEmpty(env[keyVar]);
    if (key == null) {
      skipped.add(model);
      continue;
    }

    usable.add(ResolvedAiModel(model: model, apiKey: key));
  }

  return AiModelResolution(
    usable: usable,
    skipped: skipped,
    warnings: warnings,
  );
}

/// [resolveAiModels] against the real process environment.
AiModelResolution resolveAiModelsFromEnv() => resolveAiModels(
  rawModels: Platform.environment[aiModelsEnvVar],
  env: Platform.environment,
);

/// Prints what [resolveAiModels] decided, without ever printing a key.
void logAiModelResolution(AiModelResolution resolution) {
  for (final warning in resolution.warnings) {
    logWarn(warning);
  }
  for (final model in resolution.skipped) {
    logInfo(
      'AI model $model skipped: ${aiProviderKeyEnvVars[model.provider]} is '
      'not set.',
    );
  }
  if (resolution.usable.isNotEmpty) {
    logInfo(
      'AI models in priority order: '
      '${resolution.usable.map((m) => m.model.id).join(' → ')}',
    );
  }
}

/// Token counts for one answered call, for cost reporting.
class AiUsage {
  /// Wraps the two counts every provider reports.
  const AiUsage({required this.inputTokens, required this.outputTokens});

  /// Tokens billed as input.
  final int inputTokens;

  /// Tokens billed as output, thinking included.
  final int outputTokens;

  @override
  String toString() => '$inputTokens in / $outputTokens out';
}

/// A successful answer, and which model produced it.
class AiResponse {
  /// Binds the raw answer [text] to the [model] that wrote it.
  const AiResponse({required this.model, required this.text, this.usage});

  /// The model that answered.
  final AiModel model;

  /// Raw answer text. A JSON object, per the schema the call requested.
  final String text;

  /// Token counts, when the provider reported them.
  final AiUsage? usage;
}

/// One provider attempt that did not produce an answer.
class AiAttemptFailure {
  /// Records that [model] failed with [reason].
  const AiAttemptFailure({
    required this.model,
    required this.reason,
    required this.retryable,
  });

  /// The model that was tried.
  final AiModel model;

  /// Why it did not answer. Safe to print: never contains a key.
  final String reason;

  /// Whether the next list entry was tried after this.
  final bool retryable;

  @override
  String toString() => '$model — $reason';
}

/// Thrown when no configured model produced an answer.
class AiCallException implements Exception {
  /// Wraps [message], optionally with the per-model [failures] behind it.
  const AiCallException(this.message, [this.failures = const []]);

  /// Summary line.
  final String message;

  /// One entry per model that was tried, in the order they were tried.
  final List<AiAttemptFailure> failures;

  @override
  String toString() => failures.isEmpty
      ? message
      : '$message\n${failures.map((f) => '  - $f').join('\n')}';
}

/// JSON Schema for a flat object of required string fields, in the shape the
/// Anthropic Messages API accepts under `output_config.format`.
///
/// [fields] maps field name to the description the model is given for it;
/// iteration order is preserved. `additionalProperties: false` is mandatory
/// there and rejected by Gemini, which is why the two schemas are built
/// separately instead of shared.
Map<String, Object?> strictJsonSchema(Map<String, String> fields) => {
  'type': 'object',
  'properties': {
    for (final field in fields.entries)
      field.key: {'type': 'string', 'description': field.value},
  },
  'required': fields.keys.toList(),
  'additionalProperties': false,
};

/// The same object in the OpenAPI 3.0 subset Gemini's `responseSchema` accepts.
///
/// `propertyOrdering` is Gemini-specific and pins the generation order, which
/// the provider documents as materially affecting answer quality.
Map<String, Object?> geminiResponseSchema(Map<String, String> fields) => {
  'type': 'object',
  'properties': {
    for (final field in fields.entries)
      field.key: {'type': 'string', 'description': field.value},
  },
  'required': fields.keys.toList(),
  'propertyOrdering': fields.keys.toList(),
};

/// Reads the JSON object out of a model answer, or null if there is none.
///
/// Structured outputs make the JSON contract binding on every provider, so the
/// direct decode is the normal path. The extraction behind it covers what that
/// guarantee does not: an answer wrapped in a markdown fence, or with a
/// sentence around it. It is *not* a net for truncation — a response cut off at
/// the token limit is rejected before it reaches here, because half an object
/// that still parses is how a broken entry reaches a CHANGELOG unnoticed.
Map<String, dynamic>? decodeAiJsonObject(String text) {
  final trimmed = text.trim();

  final direct = _tryDecodeObject(trimmed);
  if (direct != null) return direct;

  final braces = RegExp(r'\{[\s\S]*\}').firstMatch(trimmed);
  if (braces != null) return _tryDecodeObject(braces.group(0)!);

  return null;
}

Map<String, dynamic>? _tryDecodeObject(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Asks the first model in [models] that answers to return a JSON object.
///
/// [jsonFields] names the fields the object must carry, mapped to the
/// description each is given; every provider is asked to enforce it natively.
///
/// Falls through to the next entry only when a model produced no answer —
/// network failure, an auth/rate-limit/server status, a refusal, or a response
/// cut off at the token limit. Never on the *content* of an answer: a valid but
/// mediocre entry is not something the next provider would improve, and
/// switching on it would make the entries in a CHANGELOG silently
/// inconsistent. A malformed request (4xx that is not 401/403/408/429) stops
/// the whole call, so a bug in what this file sends stays visible instead of
/// being papered over by the next provider.
Future<AiResponse> callAi({
  required List<ResolvedAiModel> models,
  required String prompt,
  required Map<String, String> jsonFields,
  int maxTokens = 16000,
  String? effort,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final resolvedEffort = effort ?? resolveAiEffort(Platform.environment);
  // Anthropic is always sent a level, defaulting to [defaultAiEffort]; Google
  // has no such knob and OpenRouter is sent one only when asked. Saying
  // "(default)" without that distinction reads as though all three were.
  final effortLabel =
      resolvedEffort ?? '$defaultAiEffort (default; providers differ)';

  if (models.isEmpty) {
    throw AiCallException(
      'No usable AI model is configured. Set $aiModelsEnvVar to a '
      '`provider/model` list (e.g. "$aiModelsExample") and the key for each '
      'provider you name.',
    );
  }

  final failures = <AiAttemptFailure>[];

  for (final entry in models) {
    try {
      logStep('Asking ${entry.model} (effort: $effortLabel)...');
      final response = await _callProvider(
        entry: entry,
        prompt: prompt,
        jsonFields: jsonFields,
        maxTokens: maxTokens,
        effort: resolvedEffort,
        timeout: timeout,
      );
      final usage = response.usage;
      logInfo(
        'Answered by ${response.model}'
        '${usage == null ? '' : ' ($usage tokens)'}',
      );
      return response;
    } on AiAttemptException catch (failure) {
      // A failure quotes the provider's response body, which is logged and
      // reaches pull-request output. None of the three providers echo the key
      // back — checked against a live rejection from each — but that is a
      // property of their error messages, not of this client. Make it one of
      // this client's.
      final reason = redactSecret(failure.reason, entry.apiKey);
      failures.add(
        AiAttemptFailure(
          model: entry.model,
          reason: reason,
          retryable: failure.retryable,
        ),
      );
      if (!failure.retryable) {
        logError('${entry.model} failed: $reason');
        break;
      }
      logWarn('${entry.model} did not answer: $reason');
    }
  }

  throw AiCallException('No configured AI model produced an answer:', failures);
}

Future<AiResponse> _callProvider({
  required ResolvedAiModel entry,
  required String prompt,
  required Map<String, String> jsonFields,
  required int maxTokens,
  required String? effort,
  required Duration timeout,
}) {
  switch (entry.model.provider) {
    case 'anthropic':
      return _callAnthropic(
        entry: entry,
        prompt: prompt,
        jsonFields: jsonFields,
        maxTokens: maxTokens,
        effort: effort,
        timeout: timeout,
      );
    case 'google':
      return _callGoogle(
        entry: entry,
        prompt: prompt,
        jsonFields: jsonFields,
        maxTokens: maxTokens,
        timeout: timeout,
      );
    case 'openrouter':
      return _callOpenRouter(
        entry: entry,
        prompt: prompt,
        jsonFields: jsonFields,
        maxTokens: maxTokens,
        effort: effort,
        timeout: timeout,
      );
    default:
      // Unreachable: resolveAiModels drops unknown providers. Kept so a new
      // entry in aiProviderKeyEnvVars without a branch here fails loudly.
      throw AiAttemptException(
        'no client for provider "${entry.model.provider}"',
        retryable: false,
      );
  }
}

/// Anthropic Messages API.
///
/// `thinking` is left unset on purpose. On the current Opus models that means
/// adaptive thinking, which is their default and their best-quality mode;
/// explicitly disabling it is documented to leak `<thinking>` tags into the
/// visible text, which would break exactly the JSON contract this call rests
/// on. `max_tokens` bounds thinking *and* answer together, hence the generous
/// budget — output is billed by what is produced, not by the ceiling.
///
/// No `temperature`/`top_p`/`top_k`: these models reject them outright.
Future<AiResponse> _callAnthropic({
  required ResolvedAiModel entry,
  required String prompt,
  required Map<String, String> jsonFields,
  required int maxTokens,
  required String? effort,
  required Duration timeout,
}) async {
  final response = await _postJson(
    url: Uri.parse('https://api.anthropic.com/v1/messages'),
    headers: {
      'content-type': 'application/json',
      'x-api-key': entry.apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: {
      'model': entry.model.model,
      'max_tokens': maxTokens,
      'output_config': {
        'effort': effort ?? defaultAiEffort,
        'format': {
          'type': 'json_schema',
          'schema': strictJsonSchema(jsonFields),
        },
      },
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    },
    timeout: timeout,
  );

  return parseAnthropicResponse(
    body: _decodeResponseObject(response),
    model: entry.model,
    maxTokens: maxTokens,
  );
}

/// Reads the answer out of an Anthropic Messages API response body.
///
/// Separate from the request so the cases that would otherwise put a broken
/// entry in a CHANGELOG — a thinking block ahead of the answer, a refusal, a
/// response cut off at the token limit — are covered by tests rather than only
/// by a live call. Throws [AiAttemptException] when there is no usable answer.
AiResponse parseAnthropicResponse({
  required Map<String, dynamic> body,
  required AiModel model,
  required int maxTokens,
}) {
  // Read before `content`: a refusal leaves it empty, and a truncated answer
  // leaves an unterminated fragment in it that must never reach a CHANGELOG.
  final stopReason = body['stop_reason'];
  if (stopReason == 'refusal') {
    throw const AiAttemptException(
      'declined by the provider (stop_reason: refusal)',
      retryable: true,
    );
  }
  if (stopReason == 'max_tokens') {
    throw AiAttemptException(
      'answer truncated at max_tokens ($maxTokens) — raise the budget',
      retryable: true,
    );
  }

  final content = body['content'];
  if (content is! List) {
    throw const AiAttemptException('no content in response', retryable: false);
  }

  // Filtered by type rather than indexed: with thinking on, the first block is
  // a thinking block, not the answer.
  final text = content
      .whereType<Map<String, dynamic>>()
      .where((block) => block['type'] == 'text')
      .map((block) => block['text'])
      .whereType<String>()
      .join();

  if (text.trim().isEmpty) {
    throw const AiAttemptException(
      'response carried no text block',
      retryable: true,
    );
  }

  final usage = body['usage'];
  return AiResponse(
    model: model,
    text: text,
    usage: usage is Map<String, dynamic>
        ? AiUsage(
            inputTokens: _asInt(usage['input_tokens']),
            outputTokens: _asInt(usage['output_tokens']),
          )
        : null,
  );
}

/// Google Gemini `generateContent`.
///
/// The model chooses its own reasoning depth here, so there is no effort knob
/// to pass; `maxOutputTokens` is the only budget.
Future<AiResponse> _callGoogle({
  required ResolvedAiModel entry,
  required String prompt,
  required Map<String, String> jsonFields,
  required int maxTokens,
  required Duration timeout,
}) async {
  final response = await _postJson(
    url: Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '${entry.model.model}:generateContent',
    ),
    headers: {
      'content-type': 'application/json',
      'x-goog-api-key': entry.apiKey,
    },
    body: {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': geminiResponseSchema(jsonFields),
        'maxOutputTokens': maxTokens,
      },
    },
    timeout: timeout,
  );

  return parseGeminiResponse(
    body: _decodeResponseObject(response),
    model: entry.model,
    maxTokens: maxTokens,
  );
}

/// Reads the answer out of a Gemini `generateContent` response body.
///
/// Separate from the request for the same reason as
/// [parseAnthropicResponse]. Throws [AiAttemptException] when there is no
/// usable answer.
AiResponse parseGeminiResponse({
  required Map<String, dynamic> body,
  required AiModel model,
  required int maxTokens,
}) {
  final candidates = body['candidates'];
  if (candidates is! List || candidates.isEmpty) {
    final feedback = body['promptFeedback'];
    final blockReason = feedback is Map<String, dynamic>
        ? feedback['blockReason']
        : null;
    throw AiAttemptException(
      blockReason == null
          ? 'no candidates in response'
          : 'prompt blocked by the provider ($blockReason)',
      retryable: true,
    );
  }

  final candidate = candidates.first;
  if (candidate is! Map<String, dynamic>) {
    throw const AiAttemptException(
      'unexpected candidate shape in response',
      retryable: false,
    );
  }

  // Same reason as the Anthropic stop_reason check: MAX_TOKENS here means the
  // JSON object is cut off, and SAFETY/RECITATION mean there is no answer.
  final finishReason = candidate['finishReason'];
  if (finishReason != null && finishReason != 'STOP') {
    throw AiAttemptException(
      finishReason == 'MAX_TOKENS'
          ? 'answer truncated at maxOutputTokens ($maxTokens) — raise the '
                'budget'
          : 'stopped with finishReason: $finishReason',
      retryable: true,
    );
  }

  final content = candidate['content'];
  final parts = content is Map<String, dynamic> ? content['parts'] : null;
  if (parts is! List) {
    throw const AiAttemptException(
      'response carried no content parts',
      retryable: true,
    );
  }

  // Reasoning models return their own thinking as parts flagged `thought`;
  // concatenating those into the answer would corrupt the JSON.
  final text = parts
      .whereType<Map<String, dynamic>>()
      .where((part) => part['thought'] != true)
      .map((part) => part['text'])
      .whereType<String>()
      .join();

  if (text.trim().isEmpty) {
    throw const AiAttemptException(
      'response carried no answer text',
      retryable: true,
    );
  }

  final meta = body['usageMetadata'];
  return AiResponse(
    model: model,
    text: text,
    usage: meta is Map<String, dynamic>
        ? AiUsage(
            inputTokens: _asInt(meta['promptTokenCount']),
            outputTokens:
                _asInt(meta['candidatesTokenCount']) +
                _asInt(meta['thoughtsTokenCount']),
          )
        : null,
  );
}

/// OpenRouter, an aggregator in front of many vendors.
///
/// Its API is OpenAI-shaped, which is a shim everywhere else but is the only
/// interface OpenRouter has — there is no "more native" alternative to prefer,
/// and it does support structured outputs. What it buys is one key for many
/// models, so a model swap costs neither a code change nor a new secret. What
/// it costs is a third party on the path and a weaker schema guarantee: support
/// is per model *and* per backing provider, and `strict` is enforced exactly by
/// some and treated as guidance by others.
///
/// A model that cannot do structured outputs is rejected by OpenRouter with a
/// plain 4xx, which this client treats as fatal on purpose — that is a mistake
/// in the configured list, and it should be read rather than quietly survived
/// by the next entry.
Future<AiResponse> _callOpenRouter({
  required ResolvedAiModel entry,
  required String prompt,
  required Map<String, String> jsonFields,
  required int maxTokens,
  required String? effort,
  required Duration timeout,
}) async {
  final response = await _postJson(
    url: Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ${entry.apiKey}',
    },
    body: {
      'model': entry.model.model,
      'max_tokens': maxTokens,
      // Same level names as the other providers take, so AI_EFFORT means
      // one thing across the whole list. Sent only when a level was actually
      // configured: the reasoning parameter is supported on some routes and
      // not others, and an unsupported parameter is a 4xx, which this client
      // treats as fatal — so the default path must not carry one.
      if (effort != null) 'reasoning': {'effort': effort},
      'response_format': {
        'type': 'json_schema',
        'json_schema': {
          'name': 'structured_answer',
          'strict': true,
          'schema': strictJsonSchema(jsonFields),
        },
      },
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    },
    timeout: timeout,
  );

  return parseOpenRouterResponse(
    body: _decodeResponseObject(response),
    model: entry.model,
    maxTokens: maxTokens,
  );
}

/// Reads the answer out of an OpenRouter chat-completion response body.
///
/// Separate from the request for the same reason as [parseAnthropicResponse].
/// Throws [AiAttemptException] when there is no usable answer.
AiResponse parseOpenRouterResponse({
  required Map<String, dynamic> body,
  required AiModel model,
  required int maxTokens,
}) {
  // Checked first, and on a 2xx: unlike the other two, OpenRouter reports an
  // upstream failure as an `error` object inside an otherwise successful
  // response, so a status-only check would read it as a valid answer and then
  // fail on the missing `choices`.
  final error = body['error'];
  if (error is Map<String, dynamic>) {
    final code = error['code'];
    throw AiAttemptException(
      'provider error${code == null ? '' : ' $code'}: ${error['message']}',
      // 402 is "out of credits" — a routing problem for this entry, not a
      // malformed request, so the next entry is worth trying.
      retryable: code is! int || code == 402 || isTransportFailure(code, ''),
    );
  }

  final choices = body['choices'];
  if (choices is! List || choices.isEmpty) {
    throw const AiAttemptException('no choices in response', retryable: false);
  }

  final choice = choices.first;
  if (choice is! Map<String, dynamic>) {
    throw const AiAttemptException(
      'unexpected choice shape in response',
      retryable: false,
    );
  }

  // Read before the content, as on the other two providers: `length` leaves an
  // unterminated JSON fragment behind, and the rest leave no answer at all.
  final finishReason = choice['finish_reason'];
  if (finishReason == 'length') {
    throw AiAttemptException(
      'answer truncated at max_tokens ($maxTokens) — raise the budget',
      retryable: true,
    );
  }
  if (finishReason == 'content_filter' || finishReason == 'error') {
    throw AiAttemptException(
      'stopped with finish_reason: $finishReason'
      '${choice['native_finish_reason'] == null ? '' : ' (${choice['native_finish_reason']})'}',
      retryable: true,
    );
  }

  // Reasoning arrives in its own `reasoning` field rather than mixed into the
  // content, so there is nothing to filter out here.
  final message = choice['message'];
  final text = message is Map<String, dynamic> ? message['content'] : null;
  if (text is! String || text.trim().isEmpty) {
    throw const AiAttemptException(
      'response carried no answer text',
      retryable: true,
    );
  }

  final usage = body['usage'];
  return AiResponse(
    model: model,
    text: text,
    usage: usage is Map<String, dynamic>
        ? AiUsage(
            inputTokens: _asInt(usage['prompt_tokens']),
            outputTokens: _asInt(usage['completion_tokens']),
          )
        : null,
  );
}

/// A provider attempt that failed, and whether to try the next entry.
class AiAttemptException implements Exception {
  /// Records [reason], and whether the next configured model should be tried.
  const AiAttemptException(this.reason, {required this.retryable});

  /// Why the attempt produced no answer. Never contains a key.
  final String reason;

  /// Whether this is a "no answer" (try the next model) rather than a "bad
  /// request" (stop, so a bug in what this file sends stays visible).
  final bool retryable;

  @override
  String toString() => reason;
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// POSTs [body] as JSON and returns status and body together.
///
/// `dart:io` rather than a `curl` subprocess for two reasons: the status code
/// is what decides whether the next model is tried, and a subprocess would put
/// the key in the process arguments where any local process can read it.
Future<_HttpResult> _postJson({
  required Uri url,
  required Map<String, String> headers,
  required Map<String, Object?> body,
  required Duration timeout,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.postUrl(url).timeout(timeout);
    for (final header in headers.entries) {
      request.headers.set(header.key, header.value);
    }
    request.add(utf8.encode(jsonEncode(body)));

    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    return _HttpResult(response.statusCode, text);
  } on TimeoutException {
    throw AiAttemptException(
      'no response within ${timeout.inSeconds}s',
      retryable: true,
    );
  } on SocketException catch (e) {
    throw AiAttemptException('network error: ${e.message}', retryable: true);
  } on HttpException catch (e) {
    throw AiAttemptException('HTTP error: ${e.message}', retryable: true);
  } on TlsException catch (e) {
    throw AiAttemptException('TLS error: ${e.message}', retryable: true);
  } finally {
    client.close(force: true);
  }
}

/// Turns a raw HTTP result into the decoded JSON object, or an attempt failure.
///
/// Only transport-shaped statuses fall through to the next model. A 400 or 404
/// says this client sent something the provider will not accept, and the next
/// provider answering would hide that permanently.
Map<String, dynamic> _decodeResponseObject(_HttpResult response) {
  if (response.statusCode ~/ 100 != 2) {
    throw AiAttemptException(
      'HTTP ${response.statusCode}: ${_truncate(response.body, 400)}',
      retryable: isTransportFailure(response.statusCode, response.body),
    );
  }

  final decoded = _tryDecodeObject(response.body);
  if (decoded == null) {
    throw AiAttemptException(
      'response was not a JSON object: ${_truncate(response.body, 200)}',
      retryable: false,
    );
  }
  return decoded;
}

/// Whether a non-2xx response means "this model did not answer" — try the next
/// entry — rather than "this client sent something wrong" — stop, so the bug
/// stays visible instead of being papered over by the next provider.
///
/// The status alone is not enough. Google answers an invalid API key with
/// `400 API_KEY_INVALID` where Anthropic uses `401`, and reading that as a
/// malformed request would halt the walk at a misconfigured key without ever
/// reaching the next model — precisely what the priority list exists to
/// survive. The exception is kept narrow on purpose: only a 400 that names an
/// authentication problem, so every other 400 stays fatal.
///
/// Pure; exposed for testing.
bool isTransportFailure(int statusCode, String body) {
  if (statusCode == 401 ||
      statusCode == 403 ||
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500) {
    return true;
  }
  return statusCode == 400 && _namesAnAuthFailure(body);
}

/// Whether an error body carries Google's invalid-key markers.
bool _namesAnAuthFailure(String body) {
  final error = _tryDecodeObject(body)?['error'];
  if (error is! Map<String, dynamic>) return false;

  if (error['status'] == 'UNAUTHENTICATED') return true;

  final details = error['details'];
  return details is List &&
      details.whereType<Map<String, dynamic>>().any(
        (detail) => detail['reason'] == 'API_KEY_INVALID',
      );
}

/// Replaces every occurrence of [secret] in [text] with a placeholder.
///
/// Pure; exposed for testing.
String redactSecret(String text, String secret) =>
    secret.isEmpty ? text : text.replaceAll(secret, '<redacted>');

String? _nonEmpty(String? value) =>
    (value == null || value.trim().isEmpty) ? null : value.trim();

int _asInt(Object? value) => value is num ? value.toInt() : 0;

String _truncate(String value, int max) {
  final single = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return single.length <= max ? single : '${single.substring(0, max)}…';
}
