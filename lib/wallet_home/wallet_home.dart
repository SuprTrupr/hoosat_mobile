import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../app_providers.dart';
import '../auth_sign/auth_sign_util.dart';
import '../hoosat/hoosat.dart';
import '../hoosat/types.dart';
import '../l10n/l10n.dart';
import '../main_card/main_card.dart';
import '../transactions/transactions_widget.dart';
import '../transactions/tx_filter_dialog.dart';
import '../util/ui_util.dart';
import '../utxos/utxos_widget.dart';
import '../widgets/gradient_widgets.dart';
import 'wallet_action_buttons.dart';
import '../settings_advanced/compound_utxos_dialog.dart';
import '../widgets/app_simpledialog.dart';

final _walletWatcherProvider = Provider.autoDispose((ref) {
  ref.watch(virtualDaaScoreProvider);
  ref.watch(virtualSelectedParentBlueScoreStreamProvider);

  ref.watch(addressNotifierProvider);
  ref.watch(balanceNotifierProvider);
  ref.watch(txNotifierProvider);
  ref.watch(utxoNotifierProvider);
  ref.watch(utxoListProvider);
  ref.watch(pendingTxsProvider);

  ref.watch(addressMonitorProvider);
});

class WalletHome extends HookConsumerWidget {
  const WalletHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    ref.watch(_walletWatcherProvider);
    // Ensure stable hook order: declare useRef outside useEffect
    final isHandling = useRef(false);

    useEffect(() {
      // Suggest compounding if UTXO count exceeds chunk size when wallet is opened.
      void maybeSuggestCompound() async {
        final walletAuth = ref.read(walletAuthProvider);
        if (walletAuth.isLocked) return;

        // Skip suggestion for view-only wallets
        final wallet = ref.read(walletProvider);
        if (wallet.isViewOnly) return;

        // Avoid suggesting while an app link is being processed.
        final appLink = ref.read(appLinkProvider);
        if (appLink != null) return;

        final utxos = ref.read(utxoListProvider);
        const chunkSize = 84;
        if (utxos.length > chunkSize) {
          // Check for pending txs to decide RBF behavior (may show a quick prompt if pending exists)
          final (:cont, :rbf) =
              await UIUtil.checkForPendingTx(context, ref: ref);
          if (!cont) {
            // user cancelled; don't show again this session
            ref.read(compoundPromptShownProvider.notifier).state = true;
            return;
          }
          if (!context.mounted) return;
          // Show a lightweight suggestion dialog that reuses the compound dialog in light mode
          await showAppDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => CompoundUtxosDialog(lightMode: true, rbf: rbf),
          );
          // Mark as shown for this session
          ref.read(compoundPromptShownProvider.notifier).state = true;
        }
      }

      void handle(String? appLink) {
        if (appLink == null) {
          return;
        }

        final walletAuth = ref.read(walletAuthProvider);
        if (walletAuth.isLocked) {
          return;
        }
        if (isHandling.value) return;
        isHandling.value = true;

        final prefix = ref.read(addressPrefixProvider);
        final authUri = HoosatAuthUri.tryParse(appLink);
        final uri = HoosatUri.tryParse(appLink, prefix: prefix);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Delay slightly to let any transient lifecycle (inactive/resumed)
          // so the sheet isn't immediately closed.
          Future.delayed(const Duration(milliseconds: 300), () {
            if (authUri != null) {
              handleAuthSignUri(context, ref: ref, uri: authUri);
              ref.read(appLinkProvider.notifier).state = null;
              isHandling.value = false;
              return;
            }

            if (uri == null) {
              UIUtil.showSnackbar(l10n.hoosatUriInvalid, context);
              // clear link and unlock handling
              ref.read(appLinkProvider.notifier).state = null;
              isHandling.value = false;
              return;
            }

            UIUtil.showSendFlow(context, ref: ref, uri: uri);
            // clear link and unlock handling
            ref.read(appLinkProvider.notifier).state = null;
            isHandling.value = false;
          });
        });
      }

      ref.listen<String?>(
        appLinkProvider,
        (_, next) => handle(next),
      );
      ref.listen(
        walletAuthProvider.select((auth) => auth.isLocked),
        (_, __) => handle(ref.read(appLinkProvider)),
      );

      // Defer initial handle to next frame to avoid modifying providers during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        handle(ref.read(appLinkProvider));
        // Also check for compound suggestion after first frame
        maybeSuggestCompound();
      });

      return null;
    }, const []);

    return Column(
      children: [
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const MainCard(),
                Container(
                  margin: const EdgeInsetsDirectional.fromSTEB(16, 2, 16, 10),
                  child: TabBar(
                    indicatorWeight: 3,
                    indicatorColor: theme.primary60,
                    indicatorPadding:
                        const EdgeInsets.symmetric(horizontal: 20),
                    tabs: [
                      Tab(
                        child: GestureDetector(
                          onLongPress: () => showTxFilterDialog(context, ref),
                          child: Container(
                            margin: const EdgeInsets.only(top: 20),
                            child: Text(
                              l10n.transactionsUppercase,
                              textAlign: TextAlign.center,
                              style: styles.textStyleTabLabel,
                            ),
                          ),
                        ),
                      ),
                      Tab(
                        child: Container(
                          padding: const EdgeInsets.only(top: 20),
                          width: double.infinity,
                          child: Text(
                            l10n.utxosUppercase,
                            textAlign: TextAlign.center,
                            style: styles.textStyleTabLabel,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      Stack(
                        children: [
                          const TransactionsWidget(),
                          const TopGradientWidget(),
                          const BottomGradientWidget(),
                        ],
                      ),
                      Stack(
                        children: [
                          const UtxosWidget(),
                          const TopGradientWidget(),
                          const BottomGradientWidget(),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const WalletActionButtons(),
      ],
    );
  }
}
