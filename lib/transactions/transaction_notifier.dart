import 'dart:async';

import 'package:collection/collection.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:logger/logger.dart';

import '../hoosat/hoosat.dart';
import '../util/safe_change_notifier.dart';
import 'transaction_types.dart';
import 'tx_cache_service.dart';

class TransactionNotifier extends SafeChangeNotifier {
  final TxCacheService cache;

  HoosatApiService get api => cache.api;
  Logger get log => cache.log;

  var loadedTxs = IList<Tx>();
  bool get hasMore => loadedTxs.length < cache.txCount;

  var pendingTxs = IList<Tx>();

  bool _loading = false;
  bool get loading => _loading;
  String? _lastLoadedTxId;

  bool _firstLoad = true;
  bool get firstLoad => _firstLoad;

  TransactionNotifier({required this.cache});

  Future<void> ensureInitialLoad({int count = 20}) async {
    if (disposed) {
      return;
    }
    if (loadedTxs.isEmpty && hasMore && !_loading) {
      await loadMore(count);
    }
  }

  /// Fetch tx ids for wallet addresses and store them in the index.
  ///
  /// This is designed to be called when a wallet is opened so the history list
  /// can page in transactions even if balances didn't change.
  Future<void> syncHistoryForAddresses(
    Iterable<String> addresses, {
    int warmPageSize = 50,
    int pageSize = 500,
    int concurrency = 8,
    int retryCount = 3,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    final addrList = addresses.where((a) => a.isNotEmpty).toList(growable: false);
    if (addrList.isEmpty || disposed) {
      return;
    }

    final beforeCount = cache.txCount;
    log.d(
      'History sync: start (addresses=${addrList.length}, beforeTxCount=$beforeCount)',
    );

    // 1) Warm-start: only fetch the first page for addresses that have any txs.
    for (final batch in addrList.slices(concurrency)) {
      if (disposed) {
        return;
      }

      final pages = await Future.wait(batch.map((address) async {
        try {
          final remoteCount = await api.getTxCountForAddress(
            address,
            retryCount: retryCount,
            retryDelay: retryDelay,
          );
          if (remoteCount <= 0) {
            return const <ApiTxId>[];
          }

          final limit = remoteCount < warmPageSize ? remoteCount : warmPageSize;
          return api.getTxIdsForAddressPage(
            address,
            limit: limit,
            offset: 0,
            retryCount: retryCount,
            retryDelay: retryDelay,
          );
        } catch (e, st) {
          log.e('History sync: warm page failed for $address',
              error: e, stackTrace: st);
          return const <ApiTxId>[];
        }
      }));

      final warmIds = pages.expand((e) => e).toList(growable: false);
      if (warmIds.isNotEmpty) {
        await cache.addWalletTxIds(warmIds);
      }
    }

    if (disposed) {
      return;
    }

    if (cache.txCount != beforeCount) {
      notifyListeners();
    }

    // Kick an initial page load now that ids exist.
    await ensureInitialLoad(count: 20);

    // 2) Full sync: paginate all tx ids per address.
    for (final address in addrList) {
      if (disposed) {
        return;
      }

      int remoteCount;
      try {
        remoteCount = await api.getTxCountForAddress(
          address,
          retryCount: retryCount,
          retryDelay: retryDelay,
        );
      } catch (e, st) {
        log.e('History sync: failed to get txCount for $address',
            error: e, stackTrace: st);
        continue;
      }

      if (remoteCount <= 0) {
        continue;
      }

      for (var offset = 0; offset < remoteCount; offset += pageSize) {
        if (disposed) {
          return;
        }

        final limit = (remoteCount - offset) < pageSize
            ? (remoteCount - offset)
            : pageSize;

        try {
          final txPage = await api.getTxIdsForAddressPage(
            address,
            limit: limit,
            offset: offset,
            retryCount: retryCount,
            retryDelay: retryDelay,
          );
          if (txPage.isEmpty) {
            break;
          }

          final prevCount = cache.txCount;
          await cache.addWalletTxIds(txPage);
          if (cache.txCount != prevCount) {
            notifyListeners();
          }
        } catch (e, st) {
          log.e('History sync: page failed for $address (offset=$offset)',
              error: e, stackTrace: st);
          break;
        }
      }
    }

    log.d('History sync: done (txCount=${cache.txCount})');
  }

  Future<void> updatePendingTxs(Iterable<ApiTransaction> pendingTxs) async {
    if (pendingTxs.isEmpty) {
      this.pendingTxs = this.pendingTxs.clear();
    } else {
      final txs = await cache.txsForApiTxs(pendingTxs);
      this.pendingTxs = txs.toIList();
    }

    notifyListeners();
  }

  void addToMemcache(ApiTransaction tx) {
    // Don't cache coinbase transactions
    if (tx.inputs.isEmpty) {
      return;
    }
    cache.addToMemcache(tx);
  }

  Future<void> addWalletTx(ApiTransaction apiTx) async {
    if (cache.isWalletTxId(apiTx.transactionId)) {
      return;
    }

    log.d('Adding wallet transaction ${apiTx.transactionId}');

    final tx = await cache.addWalletTx(apiTx);
    loadedTxs = loadedTxs.insert(0, tx);

    notifyListeners();
  }

  Future<void> processAcceptedTxIds(
    Iterable<String> acceptedTxIds, {
    required String acceptingBlockHash,
    required HoosatClient client,
  }) async {
    final walletIds = acceptedTxIds.where(cache.isWalletTxId);
    if (walletIds.isEmpty) {
      return;
    }

    final block = await client.getBlockByHash(
      acceptingBlockHash,
      includeTransactions: false,
    );

    await cache.updateAcceptedTxs(
      walletIds,
      acceptingBlockHash: acceptingBlockHash,
      acceptingBlockBlueScore: block.verboseData.blueScore.toInt(),
    );

    await reload();
  }

  Future<void> fetchNewTxsForAddresses(Iterable<String> addresses) async {
    final apiTxs = <ApiTransaction>[];
    try {
      for (final address in addresses) {
        final txsForAddress = await api.getTxsForAddress(
          address,
          pageSize: 20,
          maxPages: 100,
          shouldLoadMore: (txs) {
            return !cache.isWalletTxId(txs.last.transactionId);
          },
        );
        apiTxs.addAll(txsForAddress);
      }
    } catch (e) {
      log.e('Failed to update transactions', error: e);
    }

    if (apiTxs.isEmpty) {
      return;
    }

    try {
      final newTxs = await cache.cacheWalletTxs(apiTxs);

      loadedTxs = await _loadTxs(count: loadedTxs.length + newTxs.length);
      _lastLoadedTxId = loadedTxs.lastOrNull?.id;

      notifyListeners();
    } catch (e) {
      log.e('Failed to update transactions', error: e);
    }
  }

  Future<IList<Tx>> _loadTxs({String? startId, int count = 10}) async {
    final it = await cache.getWalletTxsAfter(txId: startId, count: count);
    final txs = it.toIList();

    return txs;
  }

  Future<void> loadMore([int count = 10]) async {
    if (_loading || !hasMore) {
      return;
    }
    _loading = true;
    _firstLoad = loadedTxs.isEmpty;
    try {
      final txs = await _loadTxs(startId: _lastLoadedTxId, count: count);

      loadedTxs = loadedTxs.addAll(txs);
      _lastLoadedTxId = txs.lastOrNull?.id ?? _lastLoadedTxId;

      notifyListeners();
    } catch (e) {
      log.e(e);
    }
    _loading = false;
  }

  Future<void> reload() async {
    if (_loading) {
      return;
    }
    _loading = true;
    _firstLoad = loadedTxs.isEmpty;
    try {
      loadedTxs = await _loadTxs(count: loadedTxs.length);
      _lastLoadedTxId = loadedTxs.lastOrNull?.id;

      notifyListeners();
    } catch (e) {
      log.e(e);
    }
    _loading = false;
  }

  Future<IList<String>> refreshWalletTxs({
    required IMap<String, BigInt> balances,
    required IList<String> pendingAddresses,
  }) async {
    if (_loading) {
      return IList();
    }
    _loading = true;

    final refreshAddresses = <String>{};

    try {
      final cachedBalances = await cache.getCachedBalances();

      for (final address in pendingAddresses) {
        final balance = balances[address] ?? BigInt.zero;
        final cached = cachedBalances[address] ?? (BigInt.zero, 0);

        if (balance == cached.$1 &&
            (balance != BigInt.zero || cached.$2 != 0)) {
          continue;
        }

        final txCount = await api.getTxCountForAddress(address);
        if (txCount != cached.$2) {
          refreshAddresses.add(address);
        }
      }

      if (refreshAddresses.isNotEmpty) {
        await fetchNewTxsForAddresses(refreshAddresses);
      }
    } catch (e) {
      log.e(e);
    }
    _loading = false;

    return refreshAddresses.toIList();
  }
}
