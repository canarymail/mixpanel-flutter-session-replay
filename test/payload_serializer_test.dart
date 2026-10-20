import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/upload/payload_serializer.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/upload/rrweb_event.dart';
import 'package:mixpanel_flutter_session_replay/src/models/session.dart';
import 'package:mixpanel_flutter_session_replay/src/models/session_event.dart';
import 'package:mixpanel_flutter_session_replay/src/models/rrweb_types.dart';

void main() {
  group('PayloadSerializer', () {
    final testToken = 'test-token-abc';
    late PayloadSerializer serializer;

    setUp(() {
      serializer = PayloadSerializer(testToken);
    });

    group('serialize', () {
      test('returns gzip-compressed payload for empty event list', () async {
        // GIVEN
        final events = <SessionReplayEvent>[];
        final session = Session(
          id: 'session-1',
          startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          status: SessionStatus.active,
        );

        // WHEN
        final result = await serializer.serialize(events, session, 'user-1', 0);

        // THEN
        expect(result.isCompressed, true);

        // Decompress and verify it's an empty JSON array
        final decompressed = gzip.decode(result.body as List<int>);
        final json = utf8.decode(decompressed);
        expect(json, '[]');
      });

      test('sets correct headers', () async {
        // GIVEN
        final expectedContentType = 'application/octet-stream';
        final events = <SessionReplayEvent>[];
        final session = Session(
          id: 'session-1',
          startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          status: SessionStatus.active,
        );

        // WHEN
        final result = await serializer.serialize(events, session, 'user-1', 0);

        // THEN
        expect(result.headers['Content-Type'], expectedContentType);
        final expectedAuth =
            'Basic ${base64Encode(utf8.encode('$testToken:'))}';
        expect(result.headers['Authorization'], expectedAuth);
      });

      test(
        'converts interaction event to rrweb incremental snapshot format',
        () async {
          // GIVEN
          final expectedRrwebType = RRWebEventType.incrementalSnapshot;
          final expectedSource = RRWebIncrementalSource.mouseInteraction;
          final expectedInteractionType = 7; // touchStart
          final expectedX = 150;
          final expectedY = 300;
          final expectedTimestampMs = 5000;

          final event = SessionReplayEvent(
            sessionId: 'session-1',
            distinctId: 'user-1',
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              expectedTimestampMs,
              isUtc: true,
            ),
            type: EventType.interaction,
            payload: InteractionPayload(
              interactionType: expectedInteractionType,
              x: expectedX.toDouble(),
              y: expectedY.toDouble(),
            ),
          );

          final session = Session(
            id: 'session-1',
            startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
            status: SessionStatus.active,
          );

          // WHEN
          final result = await serializer.serialize(
            [event],
            session,
            'user-1',
            0,
          );

          // THEN
          final decompressed = gzip.decode(result.body as List<int>);
          final json = jsonDecode(utf8.decode(decompressed)) as List<dynamic>;

          expect(json.length, 1);

          final rrwebEvent = json[0] as Map<String, dynamic>;
          expect(rrwebEvent['type'], expectedRrwebType);
          expect(rrwebEvent['timestamp'], expectedTimestampMs);

          final data = rrwebEvent['data'] as Map<String, dynamic>;
          expect(data['source'], expectedSource);
          expect(data['type'], expectedInteractionType);
          expect(data['x'], expectedX);
          expect(data['y'], expectedY);
          expect(data['id'], RRWebNodeIds.mainImage);
        },
      );

      test('converts screenshot event to rrweb full snapshot format', () async {
        // GIVEN
        final expectedRrwebType = RRWebEventType.fullSnapshot;
        final imageData = Uint8List.fromList([0xFF, 0xD8, 0x01, 0x02]);
        final expectedBase64 = base64Encode(imageData);
        final expectedTimestampMs = 5000;

        final event = SessionReplayEvent(
          sessionId: 'session-1',
          distinctId: 'user-1',
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            expectedTimestampMs,
            isUtc: true,
          ),
          type: EventType.screenshot,
          payload: ScreenshotPayload(imageData: imageData),
        );

        final session = Session(
          id: 'session-1',
          startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          status: SessionStatus.active,
        );

        // WHEN
        final result = await serializer.serialize(
          [event],
          session,
          'user-1',
          0,
        );

        // THEN
        final decompressed = gzip.decode(result.body as List<int>);
        final json = jsonDecode(utf8.decode(decompressed)) as List<dynamic>;

        expect(json.length, 1);

        final rrwebEvent = json[0] as Map<String, dynamic>;
        expect(rrwebEvent['type'], expectedRrwebType);
        expect(rrwebEvent['timestamp'], expectedTimestampMs);

        // Verify the image is embedded as base64 data URI in the DOM node tree
        final node = rrwebEvent['data']['node'] as Map<String, dynamic>;
        final jsonString = jsonEncode(node);
        expect(jsonString, contains(expectedBase64));
        expect(jsonString, contains('data:image/jpeg;base64,'));
      });

      test('converts metadata event to rrweb meta format', () async {
        // GIVEN
        final expectedRrwebType = RRWebEventType.meta;
        final expectedWidth = 375;
        final expectedHeight = 812;
        final expectedTimestampMs = 5000;

        final event = SessionReplayEvent(
          sessionId: 'session-1',
          distinctId: 'user-1',
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            expectedTimestampMs,
            isUtc: true,
          ),
          type: EventType.metadata,
          payload: MetadataPayload(
            width: expectedWidth,
            height: expectedHeight,
          ),
        );

        final session = Session(
          id: 'session-1',
          startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          status: SessionStatus.active,
        );

        // WHEN
        final result = await serializer.serialize(
          [event],
          session,
          'user-1',
          0,
        );

        // THEN
        final decompressed = gzip.decode(result.body as List<int>);
        final json = jsonDecode(utf8.decode(decompressed)) as List<dynamic>;

        expect(json.length, 1);

        final rrwebEvent = json[0] as Map<String, dynamic>;
        expect(rrwebEvent['type'], expectedRrwebType);
        expect(rrwebEvent['timestamp'], expectedTimestampMs);

        final data = rrwebEvent['data'] as Map<String, dynamic>;
        expect(data['width'], expectedWidth);
        expect(data['height'], expectedHeight);
        expect(data['discriminator'], 'dimension');
      });

      test('serializes multiple events in order', () async {
        // GIVEN
        final events = [
          SessionReplayEvent(
            sessionId: 'session-1',
            distinctId: 'user-1',
            timestamp: DateTime.fromMillisecondsSinceEpoch(100, isUtc: true),
            type: EventType.metadata,
            payload: MetadataPayload(width: 375, height: 812),
          ),
          SessionReplayEvent(
            sessionId: 'session-1',
            distinctId: 'user-1',
            timestamp: DateTime.fromMillisecondsSinceEpoch(200, isUtc: true),
            type: EventType.screenshot,
            payload: ScreenshotPayload(imageData: Uint8List.fromList([1, 2])),
          ),
          SessionReplayEvent(
            sessionId: 'session-1',
            distinctId: 'user-1',
            timestamp: DateTime.fromMillisecondsSinceEpoch(300, isUtc: true),
            type: EventType.interaction,
            payload: InteractionPayload(interactionType: 7, x: 10.0, y: 20.0),
          ),
        ];

        final session = Session(
          id: 'session-1',
          startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          status: SessionStatus.active,
        );

        // WHEN
        final result = await serializer.serialize(events, session, 'user-1', 0);

        // THEN
        final decompressed = gzip.decode(result.body as List<int>);
        final json = jsonDecode(utf8.decode(decompressed)) as List<dynamic>;

        expect(json.length, 3);
        expect(json[0]['type'], RRWebEventType.meta);
        expect(json[1]['type'], RRWebEventType.fullSnapshot);
        expect(json[2]['type'], RRWebEventType.incrementalSnapshot);
      });
    });

    group('payload format', () {
      // test/golden/rrweb_payload.json was recorded from the serializer before
      // the rrweb conversion moved to the worker isolate. Every byte of it is
      // what the Mixpanel replay API has always been sent, so any difference
      // is a format change.
      final expectedJson = File(
        'test/golden/rrweb_payload.json',
      ).readAsStringSync();
      final session = Session(
        id: 'session-1',
        startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        status: SessionStatus.active,
      );

      test('worker isolate output matches the recorded payload', () async {
        // GIVEN
        final events = _goldenEvents();

        // WHEN
        final result = await serializer.serialize(events, session, 'user-1', 0);

        // THEN
        final body = result.body as List<int>;
        expect(utf8.decode(gzip.decode(body)), expectedJson);
        expect(body, gzip.encode(utf8.encode(expectedJson)));
      });

      test('inline output matches the recorded payload', () async {
        // GIVEN
        final inlineSerializer = PayloadSerializer(
          testToken,
          compressInIsolate: false,
        );
        final events = _goldenEvents();

        // WHEN
        final result = await inlineSerializer.serialize(
          events,
          session,
          'user-1',
          0,
        );

        // THEN
        final body = result.body as List<int>;
        expect(utf8.decode(gzip.decode(body)), expectedJson);
        expect(body, gzip.encode(utf8.encode(expectedJson)));
      });

      test(
        'matches per-event rrweb conversion for a full stored batch',
        () async {
          // GIVEN
          // Rows as SqliteEventQueue returns them: every screenshot a view into
          // one shared buffer, at frame sizes a phone produces.
          final events = _storedBatch(
            screenshotCount: 40,
            screenshotBytes: 60000,
          );
          final expectedBody = gzip.encode(
            utf8.encode(
              jsonEncode(
                events
                    .map((e) => RRWebEvent.fromSessionReplayEvent(e).toJson())
                    .toList(),
              ),
            ),
          );

          // WHEN
          final result = await serializer.serialize(
            events,
            session,
            'user-1',
            0,
          );

          // THEN
          expect(result.body, expectedBody);
        },
      );

      test('leaves the events\' screenshot bytes intact', () async {
        // GIVEN
        final events = _storedBatch(screenshotCount: 3, screenshotBytes: 1000);
        final expectedImages = [
          for (final e in events)
            if (e.payload is ScreenshotPayload)
              Uint8List.fromList((e.payload as ScreenshotPayload).imageData),
        ];

        // WHEN
        await serializer.serialize(events, session, 'user-1', 0);

        // THEN
        final actualImages = [
          for (final e in events)
            if (e.payload is ScreenshotPayload)
              (e.payload as ScreenshotPayload).imageData,
        ];
        expect(actualImages, expectedImages);
      });
    });

    group('buildAuthHeader', () {
      test('creates correct Basic auth header', () {
        // GIVEN
        final expectedCredentials = base64Encode(utf8.encode('$testToken:'));
        final expectedHeader = 'Basic $expectedCredentials';

        // WHEN
        final result = serializer.buildAuthHeader(testToken);

        // THEN
        expect(result, expectedHeader);
      });
    });

    group('buildQueryParams', () {
      test('includes required static parameters', () {
        // GIVEN
        final expectedDistinctId = 'user-123';
        final expectedSequenceNumber = '5';
        final expectedSessionId = 'session-abc';
        final expectedFormat = 'gzip';
        final session = Session(
          id: expectedSessionId,
          startTime: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          status: SessionStatus.active,
        );

        // WHEN
        final params = serializer.buildQueryParams(
          session,
          expectedDistinctId,
          5,
        );

        // THEN
        expect(params['format'], expectedFormat);
        expect(params['distinct_id'], expectedDistinctId);
        expect(params['seq'], expectedSequenceNumber);
        expect(params['replay_id'], expectedSessionId);
        expect(params['\$lib_version'], endsWith('-flutter'));
      });

      test('includes dynamic timestamp parameters', () {
        fakeAsync((async) {
          // GIVEN
          final sessionStartTime = DateTime.fromMillisecondsSinceEpoch(
            1000,
            isUtc: true,
          );
          final session = Session(
            id: 'session-1',
            startTime: sessionStartTime,
            status: SessionStatus.active,
          );

          final expectedBatchStartTime =
              clock.now().millisecondsSinceEpoch / 1000.0;
          final expectedReplayLengthMs = clock
              .now()
              .difference(sessionStartTime)
              .inMilliseconds;

          // WHEN
          final params = serializer.buildQueryParams(session, 'user-1', 0);

          // THEN
          final batchStartTime = double.parse(params['batch_start_time']!);
          expect(batchStartTime, expectedBatchStartTime);

          final replayStartTime = double.parse(params['replay_start_time']!);
          expect(replayStartTime, 1.0); // 1000ms = 1.0s

          final replayLengthMs = int.parse(params['replay_length_ms']!);
          expect(replayLengthMs, expectedReplayLengthMs);
        });
      });
    });
  });
}

/// The batch test/golden/rrweb_payload.json was recorded from.
///
/// Covers each event type, PNG and JPEG detection (including a 4-byte PNG
/// signature, which is too short to count as PNG), every base64 padding
/// length, an empty screenshot, coordinates that truncate toward zero, and
/// screenshots that are views at an offset into a larger buffer, as stored
/// rows are.
List<SessionReplayEvent> _goldenEvents() {
  final buffer = Uint8List.fromList([
    0x00, 0x00, 0x00, // so every view starts mid-buffer
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, // JPEG
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
    0x89, 0x50, 0x4E, 0x47, // PNG signature alone: too short, so JPEG
    0x7F,
  ]);
  Uint8List view(int offset, int length) =>
      buffer.buffer.asUint8List(buffer.offsetInBytes + offset, length);
  SessionReplayEvent event(int ms, EventType type, EventPayload payload) =>
      SessionReplayEvent(
        sessionId: 'session-1',
        distinctId: 'user-1',
        timestamp: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        type: type,
        payload: payload,
      );
  return [
    event(1000, EventType.metadata, MetadataPayload(width: 375, height: 812)),
    event(
      1001,
      EventType.screenshot,
      ScreenshotPayload(imageData: view(3, 11)),
    ),
    event(
      1250,
      EventType.interaction,
      InteractionPayload(interactionType: 7, x: 150.7, y: 300.2),
    ),
    event(
      1251,
      EventType.interaction,
      InteractionPayload(interactionType: 9, x: -0.4, y: 811.999),
    ),
    event(
      1500,
      EventType.screenshot,
      ScreenshotPayload(imageData: view(14, 12)),
    ),
    event(
      2000,
      EventType.screenshot,
      ScreenshotPayload(imageData: view(26, 4)),
    ),
    event(
      2500,
      EventType.screenshot,
      ScreenshotPayload(imageData: view(30, 1)),
    ),
    event(2501, EventType.metadata, MetadataPayload(width: 812, height: 375)),
    event(
      3000,
      EventType.screenshot,
      ScreenshotPayload(imageData: Uint8List(0)),
    ),
  ];
}

/// A batch as SqliteEventQueue returns it: a metadata row, then
/// [screenshotCount] screenshots of [screenshotBytes] each, every one
/// followed by a touch, with all screenshot bytes views into one buffer.
List<PersistedSessionReplayEvent> _storedBatch({
  required int screenshotCount,
  required int screenshotBytes,
}) {
  final buffer = Uint8List(screenshotCount * screenshotBytes);
  for (var i = 0; i < buffer.length; i++) {
    buffer[i] = (i * 31 + i ~/ 7) & 0xFF;
  }
  var id = 0;
  Map<String, Object?> row(int type, String metadata, Uint8List? binary) => {
    'id': ++id,
    'data_size': metadata.length + (binary?.length ?? 0),
    'session_id': 'session-1',
    'distinct_id': 'user-1',
    'timestamp': 1000 + id * 250,
    'type': type,
    'payload_metadata': metadata,
    'payload_binary': binary,
  };
  return [
    PersistedSessionReplayEvent.fromDbRow(
      row(
        EventType.metadata.index,
        '{"width":360,"height":640,"version":1}',
        null,
      ),
    ),
    for (var i = 0; i < screenshotCount; i++) ...[
      PersistedSessionReplayEvent.fromDbRow(
        row(
          EventType.screenshot.index,
          '{"version":1}',
          buffer.buffer.asUint8List(i * screenshotBytes, screenshotBytes),
        ),
      ),
      PersistedSessionReplayEvent.fromDbRow(
        row(
          EventType.interaction.index,
          '{"type":7,"x":${i * 3.5},"y":${i * 7.25},"version":1}',
          null,
        ),
      ),
    ],
  ];
}
