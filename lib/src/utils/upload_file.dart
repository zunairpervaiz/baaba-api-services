import 'package:dio/dio.dart';

/// One file in a multipart upload.
///
/// Two constructors, because the two platforms disagree about what a file is:
/// [UploadFile.fromPath] for mobile and desktop, [UploadFile.fromBytes] for
/// web (where a picked file has no filesystem path) and for anything already
/// held in memory.
///
/// ```dart
/// await api.upload(
///   endpoint: '/documents',
///   fields: {'title': 'Q3 report', 'visibility': 'team'},
///   files: [
///     UploadFile.fromPath(field: 'document', path: pickedFile.path),
///     UploadFile.fromBytes(
///       field: 'thumbnail',
///       bytes: thumbnailBytes,
///       filename: 'thumb.png',
///     ),
///   ],
///   onSendProgress: (sent, total) => progress.value = sent / total,
/// );
/// ```
class UploadFile {
  /// The multipart field name the server expects, e.g. `avatar`.
  final String field;

  /// Filesystem path. Mutually exclusive with [bytes].
  final String? path;

  /// In-memory contents. Mutually exclusive with [path].
  final List<int>? bytes;

  /// Name sent to the server. Required for [UploadFile.fromBytes] — there is
  /// no path to derive one from. Defaults to the basename of [path]
  /// otherwise.
  final String? filename;

  /// MIME type, e.g. `image/png`.
  ///
  /// Leave `null` and Dio infers it from the filename extension, which is
  /// right often enough that setting it is usually unnecessary.
  final String? contentType;

  const UploadFile._({
    required this.field,
    this.path,
    this.bytes,
    this.filename,
    this.contentType,
  });

  /// A file on disk. Not available on web — use [UploadFile.fromBytes] there.
  const UploadFile.fromPath({
    required String field,
    required String path,
    String? filename,
    String? contentType,
  }) : this._(
          field: field,
          path: path,
          filename: filename,
          contentType: contentType,
        );

  /// A file already in memory. Works on every platform, including web.
  const UploadFile.fromBytes({
    required String field,
    required List<int> bytes,
    required String filename,
    String? contentType,
  }) : this._(
          field: field,
          bytes: bytes,
          filename: filename,
          contentType: contentType,
        );

  DioMediaType? get _mediaType {
    final type = contentType;
    if (type == null) return null;
    try {
      // parse() rather than splitting on '/', so a value carrying parameters
      // ('text/csv; charset=utf-8') keeps them instead of ending up as a
      // subtype of 'csv; charset=utf-8'.
      return DioMediaType.parse(type);
    } catch (_) {
      // An unparseable type falls back to Dio inferring one from the
      // filename, which beats failing the upload over a log-level detail.
      return null;
    }
  }

  /// Converts to the Dio representation. Reads the file from disk when this
  /// was built with [UploadFile.fromPath].
  Future<MultipartFile> toMultipartFile() async {
    final bytes = this.bytes;
    if (bytes != null) {
      return MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: _mediaType,
      );
    }

    return MultipartFile.fromFile(
      path!,
      filename: filename ?? path!.split(RegExp(r'[/\\]')).last,
      contentType: _mediaType,
    );
  }
}
