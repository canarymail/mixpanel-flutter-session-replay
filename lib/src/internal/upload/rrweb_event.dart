import 'dart:convert';

import '../../models/session_event.dart';
import '../../models/rrweb_types.dart';

/// RRWeb event format for API upload
///
/// This class handles the conversion from SessionReplayEvent to rrweb's JSON format.
/// Separates serialization logic from the domain model.
class RRWebEvent {
  final int type;
  final Map<String, dynamic> data;
  final int timestamp;

  RRWebEvent({required this.type, required this.data, required this.timestamp});

  /// Convert to JSON for API upload
  Map<String, dynamic> toJson() => {
    'type': type,
    'data': data,
    'timestamp': timestamp,
  };

  /// Create RRWeb event from SessionReplayEvent (accepts both base and persisted types)
  factory RRWebEvent.fromSessionReplayEvent(SessionReplayEvent event) =>
      RRWebEvent.fromPayload(event.payload, event.timestamp);

  /// Create RRWeb event from an event's payload and capture time
  ///
  /// The upload path calls this on a worker isolate, which is sent the
  /// payloads and timestamps of a batch rather than its [SessionReplayEvent]s.
  factory RRWebEvent.fromPayload(EventPayload payload, DateTime timestamp) {
    if (payload is MetadataPayload) {
      return _buildMetaEvent(payload, timestamp);
    } else if (payload is ScreenshotPayload) {
      return _buildFullSnapshotEvent(payload, timestamp);
    } else if (payload is InteractionPayload) {
      return _buildInteractionEvent(payload, timestamp);
    }

    throw UnsupportedError('Unsupported payload type: ${payload.runtimeType}');
  }

  /// Build rrweb Meta event with screen dimensions
  static RRWebEvent _buildMetaEvent(
    MetadataPayload metadata,
    DateTime timestamp,
  ) {
    return RRWebEvent(
      type: RRWebEventType.meta,
      timestamp: timestamp.millisecondsSinceEpoch,
      data: {
        'discriminator': 'dimension',
        'width': metadata.width,
        'height': metadata.height,
      },
    );
  }

  /// Build rrweb FullSnapshot event with fake HTML DOM containing screenshot
  /// Matches Android SDK format with CSS styling and phone frame structure
  static RRWebEvent _buildFullSnapshotEvent(
    ScreenshotPayload screenshot,
    DateTime timestamp,
  ) {
    final base64Image = base64Encode(screenshot.imageData);

    // Detect format from file signature (PNG: 89 50 4E 47, JPEG: FF D8)
    final isPng =
        screenshot.imageData.length > 4 &&
        screenshot.imageData[0] == 0x89 &&
        screenshot.imageData[1] == 0x50 &&
        screenshot.imageData[2] == 0x4E &&
        screenshot.imageData[3] == 0x47;
    final mimeType = isPng ? 'image/png' : 'image/jpeg';

    // CSS styling — image fills viewport
    const cssText =
        'body { margin: 0px; padding: 0px; }'
        '.screen img { width: 100%; height: auto; display: block; }';

    return RRWebEvent(
      type: RRWebEventType.fullSnapshot,
      timestamp: timestamp.millisecondsSinceEpoch,
      data: {
        'discriminator': 'node',
        'node': {
          'type': RRWebNodeType.document,
          'childNodes': [
            {
              'type': RRWebNodeType.documentType,
              'name': 'html',
              'publicId': '',
              'systemId': '',
              'id': RRWebNodeIds.documentType,
            },
            {
              'type': RRWebNodeType.element,
              'tagName': 'html',
              'attributes': {},
              'childNodes': [
                {
                  'type': RRWebNodeType.element,
                  'tagName': 'head',
                  'attributes': {},
                  'childNodes': [
                    {
                      'type': RRWebNodeType.element,
                      'tagName': 'style',
                      'attributes': {},
                      'childNodes': [
                        {
                          'type': RRWebNodeType.text,
                          'textContent': cssText,
                          'id': RRWebNodeIds.styleText,
                        },
                      ],
                      'id': RRWebNodeIds.style,
                    },
                  ],
                  'id': RRWebNodeIds.head,
                },
                {
                  'type': RRWebNodeType.element,
                  'tagName': 'body',
                  'attributes': {},
                  'childNodes': [
                    {
                      'type': RRWebNodeType.element,
                      'tagName': 'div',
                      'attributes': {'class': 'screen'},
                      'childNodes': [
                        {
                          'type': RRWebNodeType.element,
                          'tagName': 'img',
                          'attributes': {
                            'src': 'data:$mimeType;base64,$base64Image',
                          },
                          'childNodes': [],
                          'id': RRWebNodeIds.mainImage,
                        },
                      ],
                      'id': RRWebNodeIds.imageContainer,
                    },
                  ],
                  'id': RRWebNodeIds.body,
                },
              ],
              'id': RRWebNodeIds.html,
            },
          ],
          'id': RRWebNodeIds.document,
        },
      },
    );
  }

  /// Build rrweb IncrementalSnapshot event for mouse/touch interactions
  static RRWebEvent _buildInteractionEvent(
    InteractionPayload interaction,
    DateTime timestamp,
  ) {
    return RRWebEvent(
      type: RRWebEventType.incrementalSnapshot,
      timestamp: timestamp.millisecondsSinceEpoch,
      data: {
        'source': RRWebIncrementalSource.mouseInteraction,
        'type': interaction.interactionType,
        'id': RRWebNodeIds.mainImage,
        'x': interaction.x.toInt(),
        'y': interaction.y.toInt(),
      },
    );
  }
}
