import 'dart:convert';
import 'dart:isolate';

/// Decodes a large JSON document off the UI isolate.
///
/// Bettbox moves group building, tracker parsing and log parsing to
/// `Isolate.run`. This module is the equivalent entry point for the editor and
/// import paths: a multi-megabyte subscription or config no longer stalls a
/// frame while `jsonDecode` walks it. Callers should keep the existing
/// synchronous `rows()` for small channel payloads — spawning an isolate costs
/// more than parsing those.
Future<Object?> decodeJsonInBackground(String source) =>
    Isolate.run<Object?>(() => jsonDecode(source));
