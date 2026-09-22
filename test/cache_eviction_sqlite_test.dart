// Eviction against a REAL SQLite database, not the stateful fake.
// The fake mimics APICacheManager's two quirks; this proves the index
// survives the actual implementation, including its check-then-act writes.
import 'package:api_cache_manager/api_cache_manager.dart';
import 'package:baaba_api_handler/src/api_cache_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late ApiCacheHelper cache;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    cache = ApiCacheHelperImplementation.instanceFor(
        apiCacheManager: APICacheManager());
    await cache.clearAllCache();
  });

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

  test('maxEntries evicts against real SQLite', () async {
    for (var i = 0; i < 5; i++) {
      await cache.setCacheData('/item/$i', 'body-$i', maxEntries: 3);
      await tick();
    }
    expect(await cache.getCacheData('/item/0'), isNull, reason: 'evicted');
    expect(await cache.getCacheData('/item/1'), isNull, reason: 'evicted');
    expect((await cache.getCacheData('/item/4'))?.syncData, 'body-4');
    expect((await cache.getCacheData('/item/2'))?.syncData, 'body-2');
  });

  test('maxBytes evicts against real SQLite', () async {
    for (var i = 0; i < 4; i++) {
      await cache.setCacheData('/b/$i', '0123456789', maxBytes: 25);
      await tick();
    }
    expect(await cache.getCacheData('/b/0'), isNull);
    expect(await cache.getCacheData('/b/1'), isNull);
    expect((await cache.getCacheData('/b/3'))?.syncData, '0123456789');
  });

  test('the index survives a restart (fresh helper, same database)', () async {
    for (var i = 0; i < 3; i++) {
      await cache.setCacheData('/r/$i', 'body', maxEntries: 3);
      await tick();
    }
    // New helper == cold start: it must read the index back off disk, not
    // start from an empty one and under-count.
    final reopened = ApiCacheHelperImplementation.instanceFor(
        apiCacheManager: APICacheManager());
    await reopened.setCacheData('/r/3', 'body', maxEntries: 3);

    expect(await reopened.getCacheData('/r/0'), isNull,
        reason: 'the oldest should still be evictable after a restart');
    expect((await reopened.getCacheData('/r/3'))?.syncData, 'body');
  });

  test('concurrent writes for different keys stay consistent', () async {
    await Future.wait([
      for (var i = 0; i < 12; i++)
        cache.setCacheData('/c/$i', 'body', maxEntries: 20),
    ]);
    await tick();
    await cache.setCacheData('/c/final', 'body', maxEntries: 5);

    var survivors = 0;
    for (var i = 0; i < 12; i++) {
      if (await cache.getCacheData('/c/$i') != null) survivors++;
    }
    expect(survivors + 1, 5, reason: 'the cap must hold after a write burst');
  });

  test('unbounded writes never create an index row', () async {
    await cache.setCacheData('/u/1', 'body');
    await cache.setCacheData('/u/2', 'body');
    expect(await cache.isCacheExist('/u/1'), isTrue);
    // The index is stored WITHOUT the api_cache_ prefix, so isCacheExist
    // (which adds it) is not the right probe — read it the raw way.
    final raw = APICacheManager();
    var hasIndex = true;
    try {
      await raw.getCacheData('__baaba_cache_index__');
    } catch (_) {
      hasIndex = false;
    }
    expect(hasIndex, isFalse, reason: 'unbounded must cost nothing');
  });
}
