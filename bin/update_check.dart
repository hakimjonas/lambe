/// Passive, cached, opt-out "a newer `lam` is available" notice.
///
/// This lives in `bin/` because it touches the network, the filesystem,
/// and the environment — none of which belong in the `dart:io`-free
/// (WASM-clean) library. The language never checks for updates; only the
/// CLI harness does, the same way it already reads files and runs a REPL.
///
/// Design: the *notice* shown on this run is decided synchronously from a
/// small cache file (sub-millisecond, never blocks the query). The
/// *network refresh* only updates that cache for the next run, so it is
/// fire-and-forget — its result is never needed by the current process,
/// which sidesteps the "background future vs. exit()" race entirely. If
/// the process exits before the refresh finishes, one cache update is
/// skipped and retried next run.
///
/// Everything that touches IO is injected (clock, cache store, fetcher,
/// executable path, environment), so the policy is unit-testable without
/// real network or disk.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How `lam` was installed, used to pick the upgrade command.
enum InstallChannel {
  /// Homebrew tap (`brew install hakimjonas/lambe/lambe`).
  brew,

  /// Scoop (Windows).
  scoop,

  /// `dart pub global activate lambe`.
  pub,

  /// A downloaded binary, the curl installer, or build-from-source.
  manual,
}

/// The upgrade command to print for each channel.
String upgradeCommand(InstallChannel channel) => switch (channel) {
  InstallChannel.brew => 'brew upgrade lambe',
  InstallChannel.scoop => 'scoop update lambe',
  InstallChannel.pub => 'dart pub global activate lambe',
  InstallChannel.manual =>
    'curl -fsSL https://raw.githubusercontent.com/hakimjonas/lambe/main/install.sh | sh',
};

/// A pending one-line update notice for stderr.
class UpdateNotice {
  /// The currently-running version.
  final String currentVersion;

  /// The newer version available upstream.
  final String latestVersion;

  /// How `lam` was installed, selecting the upgrade command.
  final InstallChannel channel;

  /// Creates an update notice.
  const UpdateNotice(this.currentVersion, this.latestVersion, this.channel);

  /// The single stderr line, e.g.
  /// `A new lam is available: 0.13.0 -> 0.14.0. Upgrade: brew upgrade lambe`.
  String render() =>
      'A new lam is available: $currentVersion -> $latestVersion. '
      'Upgrade: ${upgradeCommand(channel)}';
}

/// Persistence seam for the update-check cache. Default wraps a file;
/// tests pass an in-memory implementation.
abstract interface class CacheStore {
  /// Returns the cache contents, or null if absent/unreadable.
  String? read();

  /// Writes the cache contents, swallowing any IO failure (a read-only
  /// cache dir must never break a query).
  void write(String contents);
}

/// Fetches the latest published version string, or null on any failure
/// (network error, timeout, malformed response). Never throws.
typedef VersionFetcher = Future<String?> Function();

/// Outcome of the synchronous notice decision.
typedef NoticeDecision = ({UpdateNotice? notice, bool stale});

/// Decide, synchronously and without network, whether to show a notice
/// on this run and whether the cache is stale enough to refresh.
///
/// Reads [store] once. A notice is returned iff the cached latest version
/// is strictly newer than [currentVersion]. A missing or malformed cache
/// yields no notice and `stale: true` (so a refresh is scheduled).
NoticeDecision decideNotice({
  required String currentVersion,
  required CacheStore store,
  required InstallChannel channel,
  required DateTime now,
  Duration staleness = const Duration(hours: 24),
}) {
  final raw = store.read();
  if (raw == null) return (notice: null, stale: true);

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return (notice: null, stale: true);
  }
  if (decoded is! Map) return (notice: null, stale: true);

  final epoch = decoded['last_check_epoch'];
  final latest = decoded['latest_version'];
  final stale =
      epoch is! int ||
      now
              .difference(
                DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true),
              )
              .abs() >
          staleness;

  if (latest is! String || !isNewer(currentVersion, latest)) {
    return (notice: null, stale: stale);
  }
  return (notice: UpdateNotice(currentVersion, latest, channel), stale: stale);
}

/// Fetch the latest version via [fetch] and write it to [store] for the
/// next run. Fire-and-forget: returns a future the caller ignores. Only
/// writes when the fetch succeeds; all errors are swallowed.
Future<void> refreshCache({
  required CacheStore store,
  required VersionFetcher fetch,
  required DateTime now,
}) async {
  final latest = await fetch();
  if (latest == null) return;
  final epoch = now.toUtc().millisecondsSinceEpoch ~/ 1000;
  store.write(
    jsonEncode({'last_check_epoch': epoch, 'latest_version': latest}),
  );
}

/// Whether [latest] is a strictly-newer dotted version than [current].
///
/// Compares numeric `X.Y.Z` components. Pre-release/build metadata after
/// `-` or `+` is stripped (releases are plain `X.Y.Z`). Anything that
/// does not parse as numeric components compares as not-newer, so a
/// malformed upstream response can never produce a bogus notice.
bool isNewer(String current, String latest) {
  final a = _parseVersion(current);
  final b = _parseVersion(latest);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (b[i] > a[i]) return true;
    if (b[i] < a[i]) return false;
  }
  return b.length > a.length && b.skip(a.length).any((c) => c > 0);
}

List<int>? _parseVersion(String v) {
  final core = v.trim().split(RegExp(r'[-+]')).first;
  final parts = core.split('.');
  if (parts.isEmpty) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0) return null;
    out.add(n);
  }
  return out;
}

/// Detect how `lam` was installed from its [resolvedExecutable] path
/// (pass `Platform.resolvedExecutable`). [isWindows] selects path
/// conventions. Unknown locations fall back to [InstallChannel.manual].
InstallChannel detectChannel(String resolvedExecutable, {bool? isWindows}) {
  final win = isWindows ?? Platform.isWindows;
  final p = resolvedExecutable.toLowerCase().replaceAll(r'\', '/');
  if (p.contains('/cellar/') ||
      p.contains('/homebrew/') ||
      p.contains('/.linuxbrew/')) {
    return InstallChannel.brew;
  }
  if (p.contains('/scoop/')) return InstallChannel.scoop;
  // pub-cache: `.pub-cache` on unix, `pub/cache` on Windows.
  if (p.contains('.pub-cache') || (win && p.contains('/pub/cache/'))) {
    return InstallChannel.pub;
  }
  return InstallChannel.manual;
}

/// The full gating predicate: check for updates only when every guard
/// allows it. Pure — takes the already-resolved booleans.
bool shouldCheck({
  required bool stderrIsTerminal,
  required bool optedOutByEnv,
  required bool optedOutByFlag,
  required bool isCi,
  required bool suppressedMode,
}) =>
    stderrIsTerminal &&
    !optedOutByEnv &&
    !optedOutByFlag &&
    !isCi &&
    !suppressedMode;

// ---------------------------------------------------------------------------
// Default IO wiring. None of this runs under test (tests inject fakes).
// ---------------------------------------------------------------------------

/// Resolve the cache file path from [env], honoring XDG / platform
/// conventions. Returns null if no writable home/cache root is known.
String? resolveCachePath(Map<String, String> env, {bool? isWindows}) {
  final win = isWindows ?? Platform.isWindows;
  String join(String dir) => '$dir/lambe/update-check.json';
  if (win) {
    final local = env['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) return join(local);
  }
  final xdg = env['XDG_CACHE_HOME'];
  if (xdg != null && xdg.isNotEmpty) return join(xdg);
  final home = env['HOME'];
  if (home != null && home.isNotEmpty) return join('$home/.cache');
  return null;
}

/// File-backed [CacheStore] at [path]. A null path makes every read
/// return null and every write a no-op (no writable cache location).
class FileCacheStore implements CacheStore {
  /// The resolved cache file path, or null if none is available.
  final String? path;

  /// Creates a file-backed store at [path].
  const FileCacheStore(this.path);

  @override
  String? read() {
    final p = path;
    if (p == null) return null;
    try {
      final f = File(p);
      return f.existsSync() ? f.readAsStringSync() : null;
    } on IOException {
      return null;
    }
  }

  @override
  void write(String contents) {
    final p = path;
    if (p == null) return;
    try {
      final f = File(p);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(contents);
    } on IOException {
      // Read-only or sandboxed cache dir: skip silently.
    }
  }
}

/// Default network fetcher: pub.dev's package API, short timeout, every
/// error swallowed to null. pub.dev returns the bare semver in
/// `latest.version` (GitHub release tags would need the `v` stripped).
VersionFetcher defaultFetcher({
  Duration timeout = const Duration(seconds: 2),
  String currentVersion = '',
}) => () async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client
        .getUrl(Uri.parse('https://pub.dev/api/packages/lambe'))
        .timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, 'lam/$currentVersion');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 200) return null;
    final body = await resp.transform(utf8.decoder).join().timeout(timeout);
    final decoded = jsonDecodeOrNull(body);
    if (decoded is! Map) return null;
    final latest = decoded['latest'];
    if (latest is! Map) return null;
    final version = latest['version'];
    return version is String ? version : null;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
};

/// jsonDecode that returns null instead of throwing on malformed input.
Object? jsonDecodeOrNull(String s) {
  try {
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
}
