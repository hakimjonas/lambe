/// Unit tests for the passive update-check policy (`bin/update_check.dart`).
///
/// Every IO touch point is a seam, so these run with in-memory fakes and
/// a fixed clock — no real network, no disk, CI-safe. They pin the policy:
/// when a notice fires, what it says per install channel, when the cache
/// is considered stale, and the full opt-out gate.
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../bin/update_check.dart';

/// In-memory [CacheStore] holding a single optional string.
class _FakeStore implements CacheStore {
  String? contents;
  int writes = 0;
  _FakeStore([this.contents]);

  @override
  String? read() => contents;

  @override
  void write(String c) {
    contents = c;
    writes++;
  }
}

/// Build a cache JSON string for [version] last checked [epoch] seconds
/// since the unix epoch (UTC).
String _cache(String version, int epoch) =>
    jsonEncode({'last_check_epoch': epoch, 'latest_version': version});

void main() {
  final now = DateTime.utc(2026, 6, 9, 12);
  final fresh =
      now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  final old =
      now.subtract(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000;

  group('isNewer', () {
    test('strictly newer patch / minor / major', () {
      expect(isNewer('0.13.0', '0.14.0'), isTrue);
      expect(isNewer('0.13.0', '0.13.1'), isTrue);
      expect(isNewer('0.99.0', '1.0.0'), isTrue);
      expect(isNewer('0.13.9', '0.14.0'), isTrue);
    });

    test('equal or older is not newer', () {
      expect(isNewer('0.14.0', '0.14.0'), isFalse);
      expect(isNewer('0.14.0', '0.13.9'), isFalse);
      expect(isNewer('1.0.0', '0.99.99'), isFalse);
    });

    test('pre-release / build metadata is stripped', () {
      expect(isNewer('0.13.0', '0.14.0-rc.1'), isTrue);
      expect(isNewer('0.14.0-rc.1', '0.14.0'), isFalse); // 0.14.0 == 0.14.0
    });

    test('differing component counts', () {
      expect(isNewer('0.14', '0.14.1'), isTrue);
      expect(isNewer('0.14.0', '0.14'), isFalse);
    });

    test('unparseable compares as not-newer (no bogus notice)', () {
      expect(isNewer('0.13.0', 'garbage'), isFalse);
      expect(isNewer('0.13.0', ''), isFalse);
      expect(isNewer('0.13.0', '0.x.0'), isFalse);
    });
  });

  group('decideNotice', () {
    test('newer available + fresh cache → notice, not stale', () {
      final d = decideNotice(
        currentVersion: '0.13.0',
        store: _FakeStore(_cache('0.14.0', fresh)),
        channel: InstallChannel.brew,
        now: now,
      );
      expect(d.stale, isFalse);
      expect(d.notice, isNotNull);
      expect(d.notice!.latestVersion, '0.14.0');
      expect(d.notice!.channel, InstallChannel.brew);
    });

    test('up to date → no notice', () {
      final d = decideNotice(
        currentVersion: '0.14.0',
        store: _FakeStore(_cache('0.14.0', fresh)),
        channel: InstallChannel.pub,
        now: now,
      );
      expect(d.notice, isNull);
      expect(d.stale, isFalse);
    });

    test('stale cache (>24h) → stale true', () {
      final d = decideNotice(
        currentVersion: '0.14.0',
        store: _FakeStore(_cache('0.14.0', old)),
        channel: InstallChannel.pub,
        now: now,
      );
      expect(d.stale, isTrue);
    });

    test('newer available but stale → notice AND stale', () {
      final d = decideNotice(
        currentVersion: '0.13.0',
        store: _FakeStore(_cache('0.14.0', old)),
        channel: InstallChannel.scoop,
        now: now,
      );
      expect(d.notice, isNotNull);
      expect(d.stale, isTrue);
    });

    test('absent cache → no notice, stale', () {
      final d = decideNotice(
        currentVersion: '0.13.0',
        store: _FakeStore(),
        channel: InstallChannel.manual,
        now: now,
      );
      expect(d.notice, isNull);
      expect(d.stale, isTrue);
    });

    test('malformed cache → no notice, stale, no throw', () {
      final d = decideNotice(
        currentVersion: '0.13.0',
        store: _FakeStore('not json{{'),
        channel: InstallChannel.manual,
        now: now,
      );
      expect(d.notice, isNull);
      expect(d.stale, isTrue);
    });

    test('cache missing epoch → treated as stale', () {
      final d = decideNotice(
        currentVersion: '0.13.0',
        store: _FakeStore(jsonEncode({'latest_version': '0.14.0'})),
        channel: InstallChannel.brew,
        now: now,
      );
      expect(d.notice, isNotNull);
      expect(d.stale, isTrue);
    });
  });

  group('refreshCache', () {
    test('fetch newer → store written with epoch + version', () async {
      final store = _FakeStore();
      await refreshCache(store: store, fetch: () async => '0.14.0', now: now);
      expect(store.writes, 1);
      final decoded = jsonDecode(store.contents!) as Map;
      expect(decoded['latest_version'], '0.14.0');
      expect(decoded['last_check_epoch'], now.millisecondsSinceEpoch ~/ 1000);
    });

    test('fetch null (failure) → store untouched', () async {
      final store = _FakeStore();
      await refreshCache(store: store, fetch: () async => null, now: now);
      expect(store.writes, 0);
      expect(store.contents, isNull);
    });
  });

  group('detectChannel', () {
    test('homebrew Cellar', () {
      expect(
        detectChannel(
          '/opt/homebrew/Cellar/lambe/0.13.0/bin/lam',
          isWindows: false,
        ),
        InstallChannel.brew,
      );
      expect(
        detectChannel('/home/linuxbrew/.linuxbrew/bin/lam', isWindows: false),
        InstallChannel.brew,
      );
    });

    test('scoop', () {
      expect(
        detectChannel(
          r'C:\Users\me\scoop\apps\lambe\current\lam.exe',
          isWindows: true,
        ),
        InstallChannel.scoop,
      );
    });

    test('pub-cache (unix and windows)', () {
      expect(
        detectChannel('/home/me/.pub-cache/bin/lam', isWindows: false),
        InstallChannel.pub,
      );
      expect(
        detectChannel(
          r'C:\Users\me\AppData\Local\Pub\Cache\bin\lam.exe',
          isWindows: true,
        ),
        InstallChannel.pub,
      );
    });

    test('manual / unknown', () {
      expect(
        detectChannel('/usr/local/bin/lam', isWindows: false),
        InstallChannel.manual,
      );
    });
  });

  group('UpdateNotice.render', () {
    test('one line, channel-appropriate command', () {
      expect(
        const UpdateNotice('0.13.0', '0.14.0', InstallChannel.brew).render(),
        'A new lam is available: 0.13.0 -> 0.14.0. Upgrade: brew upgrade lambe',
      );
      expect(
        const UpdateNotice('0.13.0', '0.14.0', InstallChannel.scoop).render(),
        contains('scoop update lambe'),
      );
      expect(
        const UpdateNotice('0.13.0', '0.14.0', InstallChannel.pub).render(),
        contains('dart pub global activate lambe'),
      );
      expect(
        const UpdateNotice('0.13.0', '0.14.0', InstallChannel.manual).render(),
        contains('install.sh'),
      );
    });
  });

  group('shouldCheck gate', () {
    bool gate({
      bool tty = true,
      bool env = false,
      bool flag = false,
      bool ci = false,
      bool mode = false,
    }) => shouldCheck(
      stderrIsTerminal: tty,
      optedOutByEnv: env,
      optedOutByFlag: flag,
      isCi: ci,
      suppressedMode: mode,
    );

    test('all clear → check', () {
      expect(gate(), isTrue);
    });

    test('each guard independently blocks', () {
      expect(gate(tty: false), isFalse);
      expect(gate(env: true), isFalse);
      expect(gate(flag: true), isFalse);
      expect(gate(ci: true), isFalse);
      expect(gate(mode: true), isFalse);
    });
  });

  group('resolveCachePath', () {
    test('XDG_CACHE_HOME wins on unix', () {
      expect(
        resolveCachePath({
          'XDG_CACHE_HOME': '/x',
          'HOME': '/h',
        }, isWindows: false),
        '/x/lambe/update-check.json',
      );
    });

    test('falls back to HOME/.cache', () {
      expect(
        resolveCachePath({'HOME': '/h'}, isWindows: false),
        '/h/.cache/lambe/update-check.json',
      );
    });

    test('LOCALAPPDATA on windows', () {
      expect(
        resolveCachePath({'LOCALAPPDATA': r'C:\x'}, isWindows: true),
        r'C:\x/lambe/update-check.json',
      );
    });

    test('null when no home root known', () {
      expect(resolveCachePath({}, isWindows: false), isNull);
    });
  });
}
