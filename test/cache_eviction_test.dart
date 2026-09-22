import 'package:api_cache_manager/api_cache_manager.dart';
import 'package:api_cache_manager/models/cache_db_model.dart';
import 'package:baaba_api_handler/src/api_cache_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// A stateful stand-in for `APICacheManager`, so eviction can be observed
/// without a database.
///
/// Mirrors the two behaviours the real one has that the helper works around:
/// `getCacheData` throws on a missing key rather than returning null, and
/// `addCacheData` overwrites by key.
class _FakeManager extends Mock implements APICacheManager {
  final Map<String, APICacheDBModel> rows = {};
  final List<String> deletes = [];

  @override
  Future<bool> addCacheData(APICacheDBModel model) async {
    model.syncTime = DateTime.now().millisecondsSinceEpoch;
    rows[model.key] = model;
    return true;
  }

  @override
  Future<APICacheDBModel> getCacheData(String key) async {
    final row = rows[key];
    if (row == null) throw StateError('No element');
    return row;
  }

  @override
  Future<bool> isAPICacheKeyExist(String key) async => rows.containsKey(key);

  @override
  Future<bool> deleteCache(String key) async {
    deletes.add(key);
    return rows.remove(key) != null;
  }

  @override
  Future<bool> emptyCache() async {
    rows.clear();
    return true;
  }

  /// Everything the helper stores that is not its own bookkeeping row.
  Iterable<String> get cachedKeys =>
      rows.keys.where((k) => k.startsWith('api_cache_'));
}

void main() {
  late _FakeManager manager;
  late ApiCacheHelper cache;

  setUp(() {
    manager = _FakeManager();
    cache = ApiCacheHelperImplementation.instanceFor(apiCacheManager: manager);
  });

  /// Writes are timestamped with millisecond resolution, so entries written in
  /// the same tick cannot be ordered. Space them out where order matters.
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

  group('unbounded (the default)', () {
    test('keeps everything and writes no index', () async {
      for (var i = 0; i < 20; i++) {
        await cache.setCacheData('/item/$i', 'body-$i');
      }

      expect(manager.cachedKeys, hasLength(20));
      expect(manager.deletes, isEmpty);
      expect(manager.rows.containsKey('__baaba_cache_index__'), isFalse,
          reason: 'an unbounded cache should pay nothing for bookkeeping');
    });
  });

  group('maxEntries', () {
    test('evicts oldest-first once the cap is passed', () async {
      for (var i = 0; i < 5; i++) {
        await cache.setCacheData('/item/$i', 'body-$i', maxEntries: 3);
        await tick();
      }

      expect(manager.cachedKeys, hasLength(3));
      expect(
        manager.cachedKeys,
        containsAll(
            ['api_cache_/item/2', 'api_cache_/item/3', 'api_cache_/item/4']),
      );
      expect(manager.rows.containsKey('api_cache_/item/0'), isFalse);
      expect(manager.rows.containsKey('api_cache_/item/1'), isFalse);
    });

    test('never evicts the entry the current write just stored', () async {
      await cache.setCacheData('/only', 'body', maxEntries: 1);
      await tick();
      await cache.setCacheData('/newest', 'body', maxEntries: 1);

      expect(manager.cachedKeys, ['api_cache_/newest']);
    });

    test('rewriting a key refreshes its age instead of duplicating it',
        () async {
      await cache.setCacheData('/a', 'v1', maxEntries: 2);
      await tick();
      await cache.setCacheData('/b', 'v1', maxEntries: 2);
      await tick();
      // /a is now the oldest — touch it so /b becomes the eviction candidate.
      await cache.setCacheData('/a', 'v2', maxEntries: 2);
      await tick();
      await cache.setCacheData('/c', 'v1', maxEntries: 2);

      expect(manager.cachedKeys, hasLength(2));
      expect(manager.cachedKeys, containsAll(['api_cache_/a', 'api_cache_/c']));
    });

    test('the bookkeeping row is never itself evicted or counted', () async {
      for (var i = 0; i < 6; i++) {
        await cache.setCacheData('/item/$i', 'body', maxEntries: 2);
        await tick();
      }

      expect(manager.rows.containsKey('__baaba_cache_index__'), isTrue);
      expect(manager.deletes, isNot(contains('__baaba_cache_index__')));
      expect(manager.cachedKeys, hasLength(2));
    });
  });

  group('maxBytes', () {
    test('evicts oldest-first until the total fits', () async {
      // Four 10-byte bodies against a 25-byte cap leaves the newest two.
      for (var i = 0; i < 4; i++) {
        await cache.setCacheData('/item/$i', '0123456789', maxBytes: 25);
        await tick();
      }

      expect(manager.cachedKeys, hasLength(2));
      expect(manager.cachedKeys,
          containsAll(['api_cache_/item/2', 'api_cache_/item/3']));
    });

    test('a single body larger than the cap is still stored', () async {
      await cache.setCacheData('/big', 'x' * 500, maxBytes: 100);

      expect(manager.cachedKeys, ['api_cache_/big'],
          reason: 'refusing to cache would fail silently and confusingly');
    });

    test('whichever bound binds first wins', () async {
      for (var i = 0; i < 6; i++) {
        await cache.setCacheData('/item/$i', '0123456789',
            maxEntries: 5, maxBytes: 25);
        await tick();
      }

      // maxBytes (25 / 10 = 2 entries) is tighter than maxEntries (5).
      expect(manager.cachedKeys, hasLength(2));
    });
  });

  group('bookkeeping stays consistent', () {
    test('clearCache drops the key from the index', () async {
      await cache.setCacheData('/a', '0123456789', maxBytes: 25);
      await tick();
      await cache.setCacheData('/b', '0123456789', maxBytes: 25);
      await tick();

      await cache.clearCache('/a');

      // /a's bytes must stop counting, or writing /c would evict live /b to
      // make room for a row that no longer exists.
      await cache.setCacheData('/c', '0123456789', maxBytes: 25);

      expect(manager.cachedKeys, containsAll(['api_cache_/b', 'api_cache_/c']));
    });

    test('clearAllCache resets the index too', () async {
      for (var i = 0; i < 3; i++) {
        await cache.setCacheData('/item/$i', '0123456789', maxBytes: 100);
        await tick();
      }

      await cache.clearAllCache();
      expect(manager.rows, isEmpty);

      // A stale in-memory index would price these against entries that are
      // gone and evict one of them immediately.
      await cache.setCacheData('/fresh/0', '0123456789', maxBytes: 100);
      await tick();
      await cache.setCacheData('/fresh/1', '0123456789', maxBytes: 100);

      expect(manager.cachedKeys, hasLength(2));
    });

    test('concurrent writes for different keys do not lose index entries',
        () async {
      // Per-key write chaining does not cover the index: these all mutate the
      // same bookkeeping row.
      await Future.wait([
        for (var i = 0; i < 10; i++)
          cache.setCacheData('/item/$i', 'body', maxEntries: 50),
      ]);

      expect(manager.cachedKeys, hasLength(10));

      // If entries had been lost, the cache would under-count and fail to
      // evict down to the cap here.
      await cache.setCacheData('/final', 'body', maxEntries: 4);

      expect(manager.cachedKeys, hasLength(4));
    });

    test('survives a corrupt index rather than failing the write', () async {
      await cache.setCacheData('/a', 'body', maxEntries: 5);

      manager.rows['__baaba_cache_index__'] =
          APICacheDBModel(key: '__baaba_cache_index__', syncData: 'not json');

      // A fresh helper, so it reads the corrupt row instead of using the copy
      // it already has in memory.
      final reopened =
          ApiCacheHelperImplementation.instanceFor(apiCacheManager: manager);

      expect(await reopened.setCacheData('/b', 'body', maxEntries: 5), isTrue);
      expect(manager.rows.containsKey('api_cache_/b'), isTrue);
    });
  });
}
