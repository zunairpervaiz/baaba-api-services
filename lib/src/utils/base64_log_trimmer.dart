/// Collapses base64 blobs out of the logger's output.
///
/// Wired in as `ApiLogOptions.logPrint` — the only hook into what the logger
/// prints. `PrettyDioLogger` has no notion of a field worth hiding: it wraps
/// every value at `maxWidth` and emits one line per 78-odd characters, so a
/// record detail carrying ten fingerprints plus two photographs is tens of
/// thousands of console lines, and the request line that caused them is long
/// gone by the time the body finishes.
///
/// This sits between the logger and the console and rewrites that stream:
///
/// ```
/// ║      "data": iVBORw0KGgoAAAANSUhEUg…
/// ║      …[412903 base64 chars elided]
/// ```
///
/// **It filters lines, not fields**, because lines are all it is given — the
/// logger has already flattened the map by the time this is called. So the
/// test is a shape test: a run of characters from the base64 alphabet, long
/// enough that it cannot be an id or a status. Anything else passes through
/// byte for byte, which is the point — a `detail` string, a case number and a
/// stack trace still read exactly as they did.
///
/// Usually you want [ApiLogOptions.trimBase64] rather than this class
/// directly:
///
/// ```dart
/// ApiServices.init(const ApiConfig(
///   logging: ApiLogOptions(trimBase64: true),
/// ));
/// ```
///
/// Construct it yourself when the defaults need tuning for your API, or to
/// place it in front of a sink of your own:
///
/// ```dart
/// ApiServices.init(ApiConfig(
///   logging: ApiLogOptions(
///     // This API returns 48-character reference codes that must stay
///     // readable, so only collapse runs longer than that.
///     logPrint: Base64LogTrimmer(sink: myLogger.debug, minRunLength: 60).call,
///   ),
/// ));
/// ```
///
/// One instance holds the running count of elided characters, so give each
/// client its own rather than sharing one across several.
class Base64LogTrimmer {
  /// Where surviving lines go. Wrap your own sink to keep it in the chain —
  /// it receives lines that have already been trimmed.
  final void Function(Object object) sink;

  /// Characters of a blob kept before the ellipsis, enough to tell a PNG from
  /// a JPEG from a JWT.
  final int keptChars;

  /// Shortest run of the base64 alphabet treated as a blob rather than as an
  /// id, a hash, or a token the reader might actually want.
  ///
  /// The default sits comfortably above the length of a typical identifier and
  /// below one wrapped line of a real image. Raise it if your API returns long
  /// reference codes that you need to read in full.
  final int minRunLength;

  Base64LogTrimmer({
    required this.sink,
    this.keptChars = 24,
    this.minRunLength = 40,
  })  : _blobTail = RegExp('([A-Za-z0-9+/]{$minRunLength,}={0,2})"?,?\$'),
        _blobChunk = RegExp('^[A-Za-z0-9+/]{$minRunLength,}={0,2}"?,?\$');

  /// The tail of a line that introduces a blob — `"data": iVBORw0KG…`.
  /// Anchored to the end so the key, the indent and the box drawing are all
  /// left alone.
  final RegExp _blobTail;

  /// A whole line of nothing but blob.
  final RegExp _blobChunk;

  /// Strips the logger's box-drawing gutter and indent, leaving the value.
  static final RegExp _gutter = RegExp(r'^[║╟╔╚╝═]\s*');

  static final RegExp _punctuation = RegExp('["\',]');

  /// Characters swallowed since the last surviving line.
  int _elided = 0;

  /// Pass this to `ApiLogOptions.logPrint`.
  void call(Object object) {
    final line = object.toString();
    final body = line.replaceFirst(_gutter, '').trim();

    // A continuation line: the logger wrapped a blob and this is the middle of
    // it, with no key to say what it belongs to. Swallow it and keep counting.
    if (_blobChunk.hasMatch(body)) {
      _elided += body.replaceAll(_punctuation, '').length;
      return;
    }

    _flush();

    // The first line of a blob still carries its key, so keep the key and a
    // recognisable head of the value, and count the rest towards the run the
    // following lines will extend.
    final head = _blobTail.firstMatch(line);
    if (head != null) {
      final blob = head.group(1)!;
      if (blob.length > keptChars) {
        _elided += blob.length - keptChars;
        sink('${line.substring(0, head.start)}'
            '${blob.substring(0, keptChars)}…');
        return;
      }
    }

    sink(line);
  }

  void _flush() {
    if (_elided == 0) return;
    final count = _elided;
    _elided = 0;
    sink('║      …[$count base64 chars elided]');
  }
}
