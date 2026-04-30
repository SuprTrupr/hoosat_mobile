import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../app_providers.dart';
import '../encrypt/blake3am.dart';
import '../hoosat/types.dart';
import '../util/ui_util.dart';

const _messagePrefix = 'Hoosat Signed Message:\n';
const _signatureScheme = 'hoosat-mobile-identity-schnorr-blake3-v2';
const _authIdentityTypeIndex = 2;
const _authIdentityIndex = 0;

Future<HoosatAuthUri> _resolveAuthUri(HoosatAuthUri uri) async {
  if (uri.request == null) {
    return uri;
  }

  final response = await http.get(uri.request!);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('Could not load signature request (${response.statusCode})');
  }

  final payload = jsonDecode(response.body);
  if (payload is! Map<String, dynamic> || payload['ok'] != true) {
    throw Exception('Invalid signature request response');
  }

  final callback = Uri.tryParse((payload['callback'] as String?) ?? '');
  if (callback == null || !callback.hasScheme || !callback.hasAuthority) {
    throw Exception('Invalid signature request callback');
  }

  return HoosatAuthUri(
    protocol: (payload['protocol'] as String?) ?? uri.protocol,
    requestId: payload['requestId'] as String? ?? uri.requestId,
    authChallengeId: payload['challengeId'] as String? ?? uri.authChallengeId,
    intent: payload['intent'] as String? ?? uri.intent,
    nonce: payload['nonce'] as String?,
    message: payload['message'] as String?,
    callback: callback,
    recipientAddress: payload['recipientAddress'] as String? ?? uri.recipientAddress,
    asset: payload['asset'] as String? ?? uri.asset,
    intentToken: payload['intentToken'] as String? ?? uri.intentToken,
    expiresAt: DateTime.tryParse((payload['expiresAt'] as String?) ?? '') ?? uri.expiresAt,
  );
}

Uint8List _encodeVarint(int value) {
  if (value < 0xfd) {
    return Uint8List.fromList([value]);
  }
  if (value <= 0xffff) {
    final data = ByteData(3)
      ..setUint8(0, 0xfd)
      ..setUint16(1, value, Endian.little);
    return data.buffer.asUint8List();
  }
  final data = ByteData(5)
    ..setUint8(0, 0xfe)
    ..setUint32(1, value, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List _hashSignedMessage(String message) {
  final prefix = Uint8List.fromList(utf8.encode(_messagePrefix));
  final body = Uint8List.fromList(utf8.encode(message));
  final formatted = BytesBuilder()
    ..add(_encodeVarint(prefix.length))
    ..add(prefix)
    ..add(_encodeVarint(body.length))
    ..add(body);
  return blake3WithDefaultKey(formatted.toBytes());
}

Future<void> handleAuthSignUri(
  BuildContext context, {
  required WidgetRef ref,
  required HoosatAuthUri uri,
}) async {
  try {
    uri = await _resolveAuthUri(uri);
  } catch (error) {
    UIUtil.showSnackbar('Could not load signature request: $error', context);
    return;
  }

  final isGatewayLogin = uri.protocol == 'htn-gateway-auth-v1';
  final isSignedIntent = uri.protocol == 'hoosat-signed-intent-v1';
  if (!isGatewayLogin && !isSignedIntent) {
    UIUtil.showSnackbar('Unsupported signature request protocol.', context);
    return;
  }

  if (uri.expiresAt != null &&
      DateTime.now().toUtc().isAfter(uri.expiresAt!.toUtc())) {
    UIUtil.showSnackbar('Login request expired.', context);
    return;
  }

  if (uri.nonce == null || uri.message == null || uri.callback == null) {
    UIUtil.showSnackbar('Incomplete signature request.', context);
    return;
  }

  final walletAuth = ref.read(walletAuthProvider);
  if (walletAuth.isLocked) {
    UIUtil.showSnackbar('Unlock wallet first, then scan again.', context);
    return;
  }

  final address = ref.read(addressNotifierProvider).selected;
  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(isSignedIntent
            ? 'Approve signed intent'
            : 'Approve wallet login'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isSignedIntent
                ? 'This signs the requested wallet intent only. No payment will be sent.'
                : 'This signs a login message only. No payment will be sent.'),
            const SizedBox(height: 12),
            Text(isSignedIntent
                ? 'Signing identity: stable wallet identity key'
                : 'Login identity: stable wallet identity key'),
            const SizedBox(height: 8),
            Text('Display address: ${address.encoded}'),
            if (isSignedIntent && uri.intent != null) ...[
              const SizedBox(height: 8),
              Text('Intent: ${uri.intent}'),
            ],
            if (isSignedIntent && uri.recipientAddress != null) ...[
              const SizedBox(height: 8),
              Text('Recipient: ${uri.recipientAddress}'),
            ] else if (isSignedIntent) ...[
              const SizedBox(height: 8),
              Text('Recipient: ${address.encoded}'),
            ],
            const SizedBox(height: 8),
            Text('Message: ${uri.message}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isSignedIntent ? 'Sign intent' : 'Sign login'),
          ),
        ],
      );
    },
  );

  if (approved != true) {
    return;
  }

  try {
    final signer = ref.read(walletAuthProvider.notifier);
    final identityPublicKey = await signer.publicKeyForPath(
      typeIndex: _authIdentityTypeIndex,
      index: _authIdentityIndex,
    );
    final signingPublicKey = identityPublicKey.length == 33
        ? identityPublicKey.sublist(1)
        : identityPublicKey;
    final identityKeyId = 'schnorr:${hex.encode(signingPublicKey)}';
    final selectedRecipientAddress = uri.recipientAddress ?? address.encoded;
    final signedMessage = isSignedIntent
        ? uri.message!.replaceAll(
            '__WALLET_SELECTED_ADDRESS__',
            selectedRecipientAddress,
          )
        : [
            uri.message!,
            'Identity Key: $identityKeyId',
            'Display Address: ${address.encoded}',
          ].join('\n');
    final messageHash = _hashSignedMessage(signedMessage);
    final signature = await signer.sign(
      messageHash,
      typeIndex: _authIdentityTypeIndex,
      index: _authIdentityIndex,
    );
    final addressPublicKey = await signer.publicKeyForPath(
      typeIndex: address.type.index,
      index: address.index,
    );
    final requestId = uri.requestId ?? uri.authChallengeId;

    final response = await http.post(
      uri.callback!,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        if (requestId != null) 'requestId': requestId,
        if (uri.authChallengeId != null) 'challengeId': uri.authChallengeId,
        if (uri.intent != null) 'intent': uri.intent,
        'address': address.encoded,
        if (isSignedIntent) 'recipientAddress': selectedRecipientAddress,
        if (isSignedIntent && uri.asset != null) 'asset': uri.asset,
        if (isSignedIntent) 'intentToken': uri.intentToken,
        'nonce': uri.nonce,
        'message': uri.message,
        'signedMessage': signedMessage,
        'messageHash': hex.encode(messageHash),
        'signature': hex.encode(signature),
        'publicKey': hex.encode(signingPublicKey),
        'identityKeyId': identityKeyId,
        'addressPublicKey': hex.encode(addressPublicKey),
        'signatureScheme': _signatureScheme,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(isSignedIntent
          ? 'Server rejected signed intent (${response.statusCode})'
          : 'Gateway rejected login signature (${response.statusCode})');
    }

    if (context.mounted) {
      UIUtil.showSnackbar(
          isSignedIntent
              ? 'Signed intent accepted. Return to the browser.'
              : 'Login signature accepted. Return to the browser.',
          context);
    }
  } catch (error) {
    if (context.mounted) {
      UIUtil.showSnackbar(
          isSignedIntent
              ? 'Intent signing failed: $error'
              : 'Login signing failed: $error',
          context);
    }
  }
}
