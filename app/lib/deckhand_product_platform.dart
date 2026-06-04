import 'dart:async';

import 'package:deckhand_ui/deckhand_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printdeck_product_platform/printdeck_product_platform.dart';

import 'deckhand_product_module.dart';

final deckhandProductModuleProvider = Provider<DeckhandProductModule>((ref) {
  return DeckhandProductModule(
    doctorService: ref.watch(doctorServiceProvider),
    flashService: ref.watch(flashServiceProvider),
  );
});

final deckhandProductRuntimeProvider = FutureProvider<ProductAgentRuntime>((
  ref,
) async {
  final registry = ProductModuleRegistry();
  await registry.register(ref.watch(deckhandProductModuleProvider));
  return ProductAgentRuntime(registry: registry);
});

final deckhandProductModuleServerProvider =
    Provider<ProductModuleJsonRpcServer>((ref) {
      final server = ProductModuleJsonRpcServer(
        module: ref.watch(deckhandProductModuleProvider),
      );
      ref.onDispose(() {
        unawaited(server.close());
      });
      return server;
    });

class DeckhandProductPlatformBootstrap extends ConsumerWidget {
  const DeckhandProductPlatformBootstrap({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(deckhandProductRuntimeProvider);
    return child;
  }
}
