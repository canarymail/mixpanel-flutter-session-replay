import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import '../../models/session_event.dart';
import '../../models/session.dart';
import '../../version.dart';
import 'rrweb_event.dart';

/// Result of payload serialization
class SerializedPayload {
  /// The serialized body data (JSON string or compressed bytes)
  final dynamic body;

  /// HTTP headers to send with the request
  final Map<String, String> headers;

  /// Whether the body is compressed
  final bool isCompressed;

  SerializedPayload({
    required this.body,
    required this.headers,
    required this.isCompressed,
  });
}

/// Payload serializer for session replay events
///
/// Serializes events as GZIP compressed bytes.
/// Uses format=gzip query parameter to indicate compression.
class PayloadSerializer {
  final String _token;

  /// When true (production default), JSON-encoding + gzip runs on a background
  /// isolate so it never blocks the caller (the root/UI isolate). Tests that
  /// drive the flush timer under `fakeAsync` set this false: a real isolate
  /// can't be advanced by fake time, so they run the codec inline instead.
  final bool _compressInIsolate;

  PayloadSerializer(this._token, {bool compressInIsolate = true})
    : _compressInIsolate = compressInIsolate;

  Future<SerializedPayload> serialize(
    List<SessionReplayEvent> events,
    Session session,
    String distinctId,
    int sequenceNumber,
  ) async {
    if (events.isEmpty) {
      final compressed = await _gzipCompress(jsonEncode([]));
      return SerializedPayload(
        body: compressed,
        headers: {
          'Authorization': buildAuthHeader(_token),
          'Content-Type': 'application/octet-stream',
        },
        isCompressed: true,
      );
    }

    // Convert to rrweb format, JSON-encode and GZIP-compress off the
    // caller's isolate.
    //
    // Base64-encoding every screenshot frame, jsonEncode and gzip.encode are
    // ~100ms of synchronous CPU per flush. The caller is the root/UI isolate,
    // which on Android runs on the platform main thread, so that time janks
    // the app every flushInterval and, on a slow device, can last long enough
    // for an ANR. A message sent to an isolate is copied on the sending thread
    // too, so the caller only packs the batch (see [_PackedBatch]) and every
    // per-frame step happens on the worker. The batch is already dequeued and
    // awaited by the caller, so sequence ordering is unaffected.
    final batch = _PackedBatch.pack(events);
    final compressed = _compressInIsolate
        ? await _encodeInIsolate(batch)
        : _encode(batch);

    return SerializedPayload(
      body: compressed,
      headers: {
        'Authorization': buildAuthHeader(_token),
        'Content-Type': 'application/octet-stream',
      },
      isCompressed: true,
    );
  }

  String buildAuthHeader(String token) {
    final credentials = base64Encode(utf8.encode('$token:'));
    return 'Basic $credentials';
  }

  Map<String, String> buildQueryParams(
    Session session,
    String distinctId,
    int sequenceNumber,
  ) {
    final batchStartTime = clock.now().millisecondsSinceEpoch / 1000.0;
    final replayLength = clock
        .now()
        .difference(session.startTime)
        .inMilliseconds;
    final replayStartTime = session.startTime.millisecondsSinceEpoch / 1000.0;

    return {
      'format': 'gzip', // Indicate compression via query param (not header)
      'distinct_id': distinctId,
      'seq': sequenceNumber.toString(),
      'batch_start_time': batchStartTime.toString(),
      'replay_id': session.id,
      'replay_length_ms': replayLength.toString(),
      'replay_start_time': replayStartTime.toString(),
      '\$lib_version': sdkVersion,
      '\$os': operatingSystem,
      'mp_lib': 'flutter-sr',
    };
  }

  /// GZIP compress a string
  Future<List<int>> _gzipCompress(String data) async {
    final bytes = utf8.encode(data);
    return gzip.encode(bytes);
  }

  /// Runs [_encode] on a new isolate.
  ///
  /// Kept out of [serialize] so the closure sent to the worker can capture
  /// nothing but [batch], never the events and the screenshot bytes they hold.
  static Future<List<int>> _encodeInIsolate(_PackedBatch batch) =>
      Isolate.run(() => _encode(batch));

  /// Converts [batch] to rrweb events, JSON-encodes and GZIP-compresses them.
  static List<int> _encode(_PackedBatch batch) {
    final payloads = batch.unpack();

    // Add all events (converted to rrweb format)
    // MetadataPayload events are automatically converted to RRWeb Meta events
    final result = <Map<String, dynamic>>[
      for (var i = 0; i < payloads.length; i++)
        RRWebEvent.fromPayload(payloads[i], batch.timestamps[i]).toJson(),
    ];

    return gzip.encode(utf8.encode(jsonEncode(result)));
  }
}

/// A batch of events packed to be sent to the worker isolate
///
/// A message sent to an isolate is copied on the sending thread, and
/// screenshots are nearly all of a batch's bytes. So every screenshot travels
/// in one [TransferableTypedData], whose buffer is handed to the receiver
/// rather than copied, and only its length stays in the batch. Metadata and
/// interaction payloads are a few numbers each and travel as they are.
class _PackedBatch {
  /// Each event's capture time, in batch order
  final List<DateTime> timestamps;

  /// Each event's payload, in batch order; `null` for a screenshot, whose
  /// bytes are in [_screenshots]
  final List<EventPayload?> _payloads;

  /// Each screenshot's length in bytes, in batch order
  final List<int> _screenshotLengths;

  /// Every screenshot's bytes, back to back, in batch order
  final TransferableTypedData _screenshots;

  _PackedBatch._(
    this.timestamps,
    this._payloads,
    this._screenshotLengths,
    this._screenshots,
  );

  factory _PackedBatch.pack(List<SessionReplayEvent> events) {
    final timestamps = <DateTime>[];
    final payloads = <EventPayload?>[];
    final screenshots = <Uint8List>[];
    for (final event in events) {
      final payload = event.payload;
      timestamps.add(event.timestamp);
      if (payload is ScreenshotPayload) {
        payloads.add(null);
        screenshots.add(payload.imageData);
      } else {
        payloads.add(payload);
      }
    }
    final screenshotLengths = [
      for (final screenshot in screenshots) screenshot.length,
    ];
    return _PackedBatch._(
      timestamps,
      payloads,
      screenshotLengths,
      TransferableTypedData.fromList(screenshots),
    );
  }

  /// Each event's payload, in batch order, screenshots included.
  ///
  /// Can be called only once, on whichever isolate the batch was sent to.
  List<EventPayload> unpack() {
    final bytes = _screenshots.materialize().asUint8List();
    final payloads = <EventPayload>[];
    var offset = 0;
    var screenshot = 0;
    for (final payload in _payloads) {
      if (payload != null) {
        payloads.add(payload);
        continue;
      }
      final length = _screenshotLengths[screenshot++];
      payloads.add(
        ScreenshotPayload(
          imageData: Uint8List.sublistView(bytes, offset, offset + length),
        ),
      );
      offset += length;
    }
    return payloads;
  }
}
