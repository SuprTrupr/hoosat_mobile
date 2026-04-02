import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import '../grpc/messages.pbgrpc.dart';
import '../grpc/rpc.pb.dart';
import '../network.dart';

class RpcException implements Exception {
  final RPCError error;

  const RpcException(this.error);

  String get message => error.message;

  @override
  String toString() => message;
}

class VoidHoosatClient extends HoosatClient {
  VoidHoosatClient()
      : super(
          channel: ClientChannel(
            'localhost',
            port: 16210,
            options: ChannelOptions(
              credentials: ChannelCredentials.insecure(),
            ),
          ),
        );

  @override
  Future<HoosatdResponse> _singleRequest(HoosatdRequest message) async {
    return HoosatdResponse();
  }

  @override
  Stream<HoosatdResponse> _streamRequest(HoosatdRequest message) {
    return StreamController<HoosatdResponse>().stream;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> terminate() async {}
}

class HoosatClient {
  late final ClientChannel channel;
  late final RPCClient rpcClient;

  HoosatClient({required this.channel}) : rpcClient = RPCClient(channel);

  factory HoosatClient.url(String url, {bool isSecure = false}) {
    final components = url.split(':');
    final host = components.first;
    final port = int.tryParse(components.last) ?? kMainnetRpcPort;

    final channel = ClientChannel(
      host,
      port: port,
      options: ChannelOptions(
        credentials: isSecure
            ? ChannelCredentials.secure()
            : ChannelCredentials.insecure(),
        connectionTimeout: Duration(minutes: 10),
        idleTimeout: Duration(minutes: 10),
        connectTimeout: Duration(minutes: 10),
      ),
    );

    return HoosatClient(channel: channel);
  }

  Future<void> close() => channel.shutdown();

  Future<void> terminate() => channel.terminate();

  Future<HoosatdResponse> _singleRequest(HoosatdRequest message) async {
    final request = StreamController<HoosatdRequest>();
    final response = rpcClient.messageStream(request.stream);

    request.sink.add(message);
    final result = await response.first;

    response.cancel();
    request.close();

    return result;
  }

  Stream<HoosatdResponse> _streamRequest(HoosatdRequest message) {
    final request = StreamController<HoosatdRequest>();
    final response = rpcClient.messageStream(request.stream);

    request.sink.add(message);

    return response;
  }

  Future<List<RpcBalancesByAddressesEntry>> getBalancesByAddresses(
    Iterable<String> addresses,
  ) async {
    final message = HoosatdRequest(
      getBalancesByAddressesRequest: GetBalancesByAddressesRequestMessage(
        addresses: addresses,
      ),
    );

    final response = await _singleRequest(message);
    final error = response.getBalancesByAddressesResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }
    return response.getBalancesByAddressesResponse.entries;
  }

  Future<List<RpcUtxosByAddressesEntry>> getUtxosByAddresses(
    Iterable<String> addresses,
  ) async {
    final startTime = DateTime.now();
    print(
        'Starting getUtxosByAddresses for ${addresses.length} addresses at $startTime');

    final message = HoosatdRequest(
      getUtxosByAddressesRequest: GetUtxosByAddressesRequestMessage(
        addresses: addresses,
      ),
    );

    try {
      final result = await _singleRequest(message).timeout(
        Duration(seconds: 60),
        onTimeout: () {
          throw TimeoutException('Request timed out after 60 seconds');
        },
      );
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime).inMilliseconds;
      print('Received response after $duration ms');

      final error = result.getUtxosByAddressesResponse.error;
      if (error.message.isNotEmpty) {
        print('Server error: ${error.message}');
        throw RpcException(error);
      }

      final entries = result.getUtxosByAddressesResponse.entries;
      print('Received ${entries.length} UTXOs');
      final roughSizeBytes = entries.toString().length * 2; // Rough estimate
      print('Estimated response size: ${roughSizeBytes / (1024 * 1024)} MB');
      return entries;
    } catch (e, stackTrace) {
      print('Error in getUtxosByAddresses: $e\n$stackTrace');
      rethrow;
    }
  }

  Stream<UtxosChangedNotificationMessage> notifyUtxosChanged(
    Iterable<String> addresses,
  ) {
    final message = HoosatdRequest(
      notifyUtxosChangedRequest: NotifyUtxosChangedRequestMessage(
        addresses: addresses,
      ),
    );

    final response = _streamRequest(message);

    final result = response.map((event) {
      final error = event.notifyUtxosChangedResponse.error;
      if (error.message.isNotEmpty) {
        throw RpcException(error);
      }
      return event.utxosChangedNotification;
    }).skip(1);

    return result;
  }

  Future<void> stopNotifyingUtxosChanged(List<String> addresses) async {
    final message = HoosatdRequest(
      stopNotifyingUtxosChangedRequest: StopNotifyingUtxosChangedRequestMessage(
        addresses: addresses,
      ),
    );

    final response = await _singleRequest(message);
    final error = response.stopNotifyingUtxosChangedResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }
  }

  // Block Notifications

  Stream<BlockAddedNotificationMessage> notifyBlockAdded() {
    final message = HoosatdRequest(
      notifyBlockAddedRequest: NotifyBlockAddedRequestMessage(),
    );

    final response = _streamRequest(message);

    return () async* {
      await for (final event in response) {
        if (event.hasNotifyBlockAddedResponse()) {
          final error = event.notifyBlockAddedResponse.error;
          if (error.message.isNotEmpty) {
            throw RpcException(error);
          }
          continue;
        }

        if (event.hasBlockAddedNotification()) {
          yield event.blockAddedNotification;
        }
      }
    }();
  }

  // Submit Transaction

  Future<String> submitTransaction(
    RpcTransaction transaction, {
    bool allowOrphan = false,
  }) async {
    final message = HoosatdRequest(
      submitTransactionRequest: SubmitTransactionRequestMessage(
        transaction: transaction,
        allowOrphan: allowOrphan,
      ),
    );

    final result = await _singleRequest(message);
    final error = result.submitTransactionResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.submitTransactionResponse.transactionId;
  }

  Future<({String transactionId, RpcTransaction replacedTransaction})>
      submitTransactionReplacement(RpcTransaction transaction) async {
    final message = HoosatdRequest(
      submitTransactionReplacementRequest:
          SubmitTransactionReplacementRequestMessage(
        transaction: transaction,
      ),
    );

    final result = await _singleRequest(message);
    final response = result.submitTransactionReplacementResponse;

    final error = response.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return (
      transactionId: response.transactionId,
      replacedTransaction: response.replacedTransaction,
    );
  }

  // Fee Estimate

  Future<RpcFeeEstimate> getFeeEstimate() async {
    final message = HoosatdRequest(
      getFeeEstimateRequest: GetFeeEstimateRequestMessage(),
    );

    final result = await _singleRequest(message);
    final error = result.getFeeEstimateResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getFeeEstimateResponse.estimate;
  }

  // Mempool

  Future<RpcMempoolEntry> getMempoolEntry({
    required String txId,
    bool includeOrphanPool = true,
    bool filterTransactionPool = true,
  }) async {
    final message = HoosatdRequest(
      getMempoolEntryRequest: GetMempoolEntryRequestMessage(
        txId: txId,
        includeOrphanPool: includeOrphanPool,
        filterTransactionPool: filterTransactionPool,
      ),
    );

    final result = await _singleRequest(message);
    final error = result.getMempoolEntryResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getMempoolEntryResponse.entry;
  }

  Future<List<RpcMempoolEntry>> getMempoolEntries({
    bool includeOrphanPool = true,
    bool filterTransactionPool = true,
  }) async {
    final message = HoosatdRequest(
      getMempoolEntriesRequest: GetMempoolEntriesRequestMessage(
        includeOrphanPool: includeOrphanPool,
        filterTransactionPool: filterTransactionPool,
      ),
    );

    final result = await _singleRequest(message);
    final error = result.getMempoolEntriesResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getMempoolEntriesResponse.entries;
  }

  Future<List<RpcMempoolEntryByAddress>> getMempoolEntriesByAddresses(
    Iterable<String> addresses, {
    bool filterTransactionPool = true,
    bool includeOrphanPool = true,
  }) async {
    final message = HoosatdRequest(
      getMempoolEntriesByAddressesRequest:
          GetMempoolEntriesByAddressesRequestMessage(
        addresses: addresses,
        filterTransactionPool: filterTransactionPool,
        includeOrphanPool: includeOrphanPool,
      ),
    );

    final result = await _singleRequest(message);
    final error = result.getMempoolEntriesByAddressesResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getMempoolEntriesByAddressesResponse.entries;
  }

  // Network info

  Future<String> getCurrentNetwork() async {
    final message = HoosatdRequest(
      getCurrentNetworkRequest: GetCurrentNetworkRequestMessage(),
    );

    final result = await _singleRequest(message);
    final error = result.getCurrentNetworkResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getCurrentNetworkResponse.currentNetwork;
  }

  Future<GetBlockDagInfoResponseMessage> getBlockDagInfo() async {
    final message = HoosatdRequest(
      getBlockDagInfoRequest: GetBlockDagInfoRequestMessage(),
    );

    final result = await _singleRequest(message);
    final error = result.getBlockDagInfoResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getBlockDagInfoResponse;
  }

  // Get Info

  Future<GetInfoResponseMessage> getInfo() async {
    final message = HoosatdRequest(
      getInfoRequest: GetInfoRequestMessage(),
    );

    final result = await _singleRequest(message);
    final error = result.getInfoResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getInfoResponse;
  }

  // Virtual Selected Parent Chain Changed

  Stream<VirtualChainChangedNotificationMessage>
      notifyVirtualSelectedParentChainChanged({
    required includeAcceptedTransactionIds,
  }) {
    final message = HoosatdRequest(
      notifyVirtualChainChangedRequest: NotifyVirtualChainChangedRequestMessage(
        includeAcceptedTransactionIds: includeAcceptedTransactionIds,
      ),
    );

    final response = _streamRequest(message);

    final result = response.map((event) {
      final error = event.notifyVirtualChainChangedResponse.error;
      if (error.message.isNotEmpty) {
        throw RpcException(error);
      }
      return event.virtualChainChangedNotification;
    }).skip(1);

    return result;
  }

  // Virtual Selected Parent Blue Score

  Future<Int64> getVirtualSelectedParentBlueScore() async {
    final message = HoosatdRequest(
      getSinkBlueScoreRequest: GetSinkBlueScoreRequestMessage(),
    );

    final result = await _singleRequest(message);
    final error = result.getSinkBlueScoreResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getSinkBlueScoreResponse.blueScore;
  }

  Stream<Int64> notifyVirtualSelectedParentBlueScoreChanged() {
    final message = HoosatdRequest(
      notifySinkBlueScoreChangedRequest:
          NotifySinkBlueScoreChangedRequestMessage(),
    );

    final response = _streamRequest(message);

    final result = response.map((event) {
      final error = event.notifySinkBlueScoreChangedResponse.error;
      if (error.message.isNotEmpty) {
        throw RpcException(error);
      }
      return event.sinkBlueScoreChangedNotification.sinkBlueScore;
    }).skip(1);

    return result;
  }

  // Virtual DAA Score

  Stream<Int64> notifyVirtualDaaScoreChanged() {
    final message = HoosatdRequest(
      notifyVirtualDaaScoreChangedRequest:
          NotifyVirtualDaaScoreChangedRequestMessage(),
    );

    final response = _streamRequest(message);

    final result = response.map((event) {
      final error = event.notifyVirtualDaaScoreChangedResponse.error;
      if (error.message.isNotEmpty) {
        throw RpcException(error);
      }
      return event.virtualDaaScoreChangedNotification.virtualDaaScore;
    }).skip(1);

    return result;
  }

  Future<RpcBlock> getBlockByHash(
    String hash, {
    bool includeTransactions = true,
  }) async {
    final message = HoosatdRequest(
      getBlockRequest: GetBlockRequestMessage(
        hash: hash,
        includeTransactions: includeTransactions,
      ),
    );

    final result = await _singleRequest(message);
    final error = result.getBlockResponse.error;
    if (error.message.isNotEmpty) {
      throw RpcException(error);
    }

    return result.getBlockResponse.block;
  }
}
