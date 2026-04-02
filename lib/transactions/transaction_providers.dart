import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import '../database/boxes.dart';
import '../hoosat/hoosat.dart';
import '../wallet/wallet_types.dart';
import 'transaction_notifier.dart';
import 'transaction_types.dart';
import 'tx_cache_service.dart';
import 'recent_outpoints_provider.dart';

// All new transactions from hoosat node
final _newTransactionProvider = StreamProvider.autoDispose((ref) {
  final client = ref.watch(hoosatClientProvider);

  final newBlock = client.notifyBlockAdded();

  return newBlock.asyncExpand((message) async* {
    final isChainBlock = message.block.verboseData.isChainBlock;
    var block = message.block;

    // Some nodes send header-only blocks (no transactions) over
    // notifyBlockAdded. Fetch the full block before emitting txs.
    final headerOnly = block.verboseData.isHeaderOnly;
    if ((headerOnly || block.transactions.isEmpty) &&
        block.verboseData.hash.isNotEmpty) {
      try {
        block = await client.getBlockByHash(
          block.verboseData.hash,
          includeTransactions: true,
        );
      } catch (_) {
        // Fall back to whatever we got in the notification.
      }
    }

    for (final rpcTx in block.transactions) {
      var apiTx = ApiTransaction.fromRpc(rpcTx);
      if (isChainBlock) {
        apiTx = apiTx.copyWith(isAccepted: true);
      }
      yield apiTx;
    }
  });
});

// New transactions associated with this wallet
final _newWalletTransactionProvider = StreamProvider.autoDispose((ref) {
  final controller = StreamController<ApiTransaction>();
  ref.listen(_newTransactionProvider, (_, next) {
    final result = next.whenOrNull(data: (tx) {
      final addressNotifier = ref.read(addressNotifierProvider);
      final utxosNotifier = ref.read(utxoNotifierProvider);

      final isWalletTx = tx.outputs.any((output) {
            final address = output.scriptPublicKeyAddress;
            return addressNotifier.containsAddress(address);
          }) ||
          tx.inputs.any((input) {
            final outpoint = Outpoint(
              transactionId: input.previousOutpointHash,
              index: input.previousOutpointIndex.toInt(),
            );
            return utxosNotifier.isWalletOutpoint(outpoint);
          });
      return isWalletTx ? tx : null;
    });

    if (result != null) {
      controller.add(result);
    }
  });

  ref.onDispose(controller.close);

  return controller.stream;
});

final _acceptedTransactionIdsProvider = StreamProvider.autoDispose((ref) {
  final client = ref.watch(hoosatClientProvider);
  return client
      .notifyVirtualSelectedParentChainChanged(
    includeAcceptedTransactionIds: true,
  )
      .expand((message) {
    return message.acceptedTransactionIds;
  });
});

final _txBoxProvider =
    Provider.autoDispose.family<LazyTypedBox<Tx>, WalletInfo>((ref, wallet) {
  final db = ref.watch(dbProvider);
  final networkId = ref.watch(networkIdProvider);
  final repository = ref.watch(boxInfoRepositoryProvider);
  final boxInfo = repository.getBoxInfo(wallet.wid, networkId);
  final txBoxKey = boxInfo.tx.boxKey;
  return db.getLazyTypedBox<Tx>(txBoxKey);
});

final _txIndexBoxProvider = Provider.autoDispose
    .family<IndexedTypedBox<TxIndex>, WalletInfo>((ref, wallet) {
  final db = ref.watch(dbProvider);
  final networkId = ref.watch(networkIdProvider);
  final repository = ref.watch(boxInfoRepositoryProvider);
  final boxInfo = repository.getBoxInfo(wallet.wid, networkId);
  final txIndexBoxKey = boxInfo.txIndex.boxKey;
  return db.getIndexedTypedBox<TxIndex>(txIndexBoxKey);
});

final txCacheServiceProvider =
    Provider.autoDispose.family<TxCacheService, WalletInfo>((ref, wallet) {
  final txIndexBox = ref.watch(_txIndexBoxProvider(wallet));
  final txBox = ref.watch(_txBoxProvider(wallet));
  final log = ref.watch(loggerProvider);

  final txCache = TxCacheService(
    txIndexBox: txIndexBox,
    txBox: txBox,
    log: log,
  );

  // Provide a lightweight resolver for previous outpoint data using the current
  // wallet UTXO set to avoid transient "Missing input tx" logs when parents
  // aren't in cache yet.
  txCache.resolveOutpoint = (String txId, int index) {
    // 1) Check recently-spent outpoints cache first
    final recent = ref.read(recentOutpointsProvider);
    final recentHit = recent['$txId:$index'];
    if (recentHit != null) {
      return recentHit;
    }

    // 2) Fallback to current UTXO set
    final utxos = ref.read(utxoListProvider);
    for (final u in utxos) {
      if (u.outpoint.transactionId == txId && u.outpoint.index == index) {
        return (
          u.address,
          // Amount in sompi; TxInputData expects int
          u.utxoEntry.amount.toInt(),
        );
      }
    }
    return null;
  };

  ref.listen(
    HoosatApiServiceProvider,
    (_, api) => txCache.api = api,
    fireImmediately: true,
  );

  return txCache;
});

final txNotifierForWalletProvider = ChangeNotifierProvider.autoDispose
    .family<TransactionNotifier, WalletInfo>((ref, wallet) {
  final service = ref.watch(txCacheServiceProvider(wallet));
  final log = ref.watch(loggerProvider);

  final notifier = TransactionNotifier(cache: service);
  notifier.loadMore();

  // When opening a wallet, balances may not change (cached == remote), which
  // means `lastBalanceChangesProvider` can be empty and we never discover tx ids.
  // Seed tx ids from all wallet addresses so history can render immediately.
  var historySyncTriggered = false;
  ref.listen(allAddressesProvider, (_, next) {
    if (historySyncTriggered || next.isEmpty) {
      return;
    }
    historySyncTriggered = true;
    log.d('Initial tx history sync: ${next.length} addresses');
    unawaited(notifier.syncHistoryForAddresses(next));
  }, fireImmediately: true);

  // Refresh transactions when balance changes
  ref.listen(lastBalanceChangesProvider, (_, next) {
    if (next.isEmpty) {
      return;
    }
    notifier.fetchNewTxsForAddresses(next.keys);
  }, fireImmediately: true);

  // Cache new transactions
  ref.listen(_newTransactionProvider, (_, next) {
    if (next.asData?.value case final tx?) {
      notifier.addToMemcache(tx);
    }
  });

  // Add new wallet transactions
  ref.listen(_newWalletTransactionProvider, (_, next) {
    if (next.asData?.value case final tx?) {
      log.d('New wallet tx: $tx');
      notifier.addWalletTx(tx);

      // Some nodes don't reliably emit `notifyUtxosChanged` for mempool/chain
      // events, so also trigger an explicit balance refresh when we know a
      // wallet-related tx exists.
      final balanceNotifier = ref.read(balanceNotifierProvider);
      final addresses = ref.read(allAddressesProvider);
      unawaited(balanceNotifier.refresh(addresses));
    }
  });

  // Update transaction status
  ref.listen(_acceptedTransactionIdsProvider, (_, next) {
    if (next.asData?.value case final ids?) {
      final client = ref.read(hoosatClientProvider);

      notifier.processAcceptedTxIds(
        ids.acceptedTransactionIds,
        acceptingBlockHash: ids.acceptingBlockHash,
        client: client,
      );

      // Accepted tx ids imply the UTXO set has changed; refresh balances even
      // if the utxos-changed stream didn't fire.
      final balanceNotifier = ref.read(balanceNotifierProvider);
      final addresses = ref.read(allAddressesProvider);
      unawaited(balanceNotifier.refresh(addresses));
    }
  });

  // Update pending transactions
  ref.listen(pendingTxsProvider, (_, next) {
    if (next.asData?.value case final pendingTxs?) {
      notifier.updatePendingTxs(pendingTxs);
    }
  });

  ref.onDispose(() {
    notifier.disposed = true;
  });

  return notifier;
});

final txNotifierProvider = Provider.autoDispose((ref) {
  final wallet = ref.watch(walletProvider);
  final txNotifier = ref.watch(txNotifierForWalletProvider(wallet));
  return txNotifier;
});

final txConfirmationStatusProvider =
    Provider.autoDispose.family<TxState, TxItem>((ref, txItem) {
  final blueScore = ref.watch(virtualSelectedParentBlueScoreProvider);

  final tx = txItem.tx;
  if (txItem.pending) {
    return TxState.pending();
  }
  final kNoConfirmations = BigInt.from(100);
  final txBlueScore = tx.apiTx.acceptingBlockBlueScore;

  if (!tx.apiTx.isAccepted || txBlueScore == null) {
    return const TxState.unconfirmed();
  }

  final confirmations = blueScore - BigInt.from(txBlueScore);
  if (confirmations >= kNoConfirmations) {
    return const TxState.confirmed();
  }

  return TxState.confirming(confirmations);
});
