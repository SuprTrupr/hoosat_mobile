class HoosatAuthUri {
  final String protocol;
  final Uri? request;
  final String? requestId;
  final String? authChallengeId;
  final String? intent;
  final String? nonce;
  final String? message;
  final Uri? callback;
  final String? recipientAddress;
  final String? asset;
  final String? intentToken;
  final DateTime? expiresAt;

  const HoosatAuthUri({
    required this.protocol,
    this.request,
    this.requestId,
    this.authChallengeId,
    this.intent,
    this.nonce,
    this.message,
    this.callback,
    this.recipientAddress,
    this.asset,
    this.intentToken,
    this.expiresAt,
  });

  static HoosatAuthUri parse(String value) {
    final uri = Uri.parse(value);
    final isAuthUri = uri.scheme == 'hoosat' &&
        uri.host == 'auth' &&
        uri.path.replaceAll('/', '') == 'sign';
    if (!isAuthUri) {
      throw Exception('Unsupported auth URI: $value');
    }

    String requiredParam(String key) {
      final param = uri.queryParameters[key]?.trim();
      if (param == null || param.isEmpty) {
        throw Exception('Missing auth URI parameter: $key');
      }
      return param;
    }

    final requestParam = uri.queryParameters['request']?.trim();
    final requestUri = requestParam == null ? null : Uri.tryParse(requestParam);
    if (requestParam != null &&
        (requestUri == null || !requestUri.hasScheme || !requestUri.hasAuthority)) {
      throw Exception('Invalid auth request URL');
    }

    final callbackParam = uri.queryParameters['callback']?.trim();
    final callback = callbackParam == null ? null : Uri.tryParse(callbackParam);
    if (callbackParam != null &&
        (callback == null || !callback.hasScheme || !callback.hasAuthority)) {
      throw Exception('Invalid auth callback');
    }

    if (requestUri == null) {
      requiredParam('nonce');
      requiredParam('message');
      if (callback == null) {
        throw Exception('Missing auth URI parameter: callback');
      }
    }

    return HoosatAuthUri(
      protocol: uri.queryParameters['protocol']?.trim() ?? 'htn-gateway-auth-v1',
      request: requestUri,
      requestId: uri.queryParameters['requestId']?.trim(),
      authChallengeId: uri.queryParameters['challengeId']?.trim(),
      intent: uri.queryParameters['intent']?.trim(),
      nonce: uri.queryParameters['nonce']?.trim(),
      message: uri.queryParameters['message']?.trim(),
      callback: callback,
      recipientAddress: uri.queryParameters['recipientAddress']?.trim(),
      asset: uri.queryParameters['asset']?.trim(),
      intentToken: uri.queryParameters['intentToken']?.trim(),
      expiresAt: DateTime.tryParse(uri.queryParameters['expiresAt'] ?? ''),
    );
  }

  static HoosatAuthUri? tryParse(String value) {
    try {
      return parse(value);
    } catch (_) {
      return null;
    }
  }
}
