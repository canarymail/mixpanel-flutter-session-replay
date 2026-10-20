import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/logger.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/screenshot_capturer.dart';
import 'package:mixpanel_flutter_session_replay/src/models/configuration.dart';
import 'package:mixpanel_flutter_session_replay/src/models/masking_directive.dart';
import 'package:mixpanel_flutter_session_replay/src/models/results.dart';

/// What the engine hands back when its raster snapshot fails under Skia: an
/// Image with nothing behind it, which reports 0x0. Encoding a real one
/// crashes the process natively, so this records whether it was attempted.
class _EmptySnapshotImage extends Fake implements ui.Image {
  bool disposed = false;
  bool encoded = false;

  @override
  int get width => 0;

  @override
  int get height => 0;

  @override
  Future<ByteData?> toByteData({
    ui.ImageByteFormat format = ui.ImageByteFormat.rawRgba,
  }) async {
    encoded = true;
    return null;
  }

  @override
  void dispose() => disposed = true;
}

class _FakeBoundary extends RenderRepaintBoundary {
  _FakeBoundary(this.image);

  final ui.Image image;

  @override
  Future<ui.Image> toImage({double pixelRatio = 1.0}) async => image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenshotCapturer', () {
    testWidgets('skips an empty snapshot without encoding it', (tester) async {
      // GIVEN
      final image = _EmptySnapshotImage();
      final capturer = ScreenshotCapturer(
        directive: MaskingDirective(autoMaskTypes: {}),
        logger: MixpanelLogger(LogLevel.none),
        debugOverlayEnabled: false,
        compressionMode: CompressionMode.dartPng,
      );

      // WHEN
      final pending = capturer.capture(_FakeBoundary(image));
      await tester.pump();
      final result = await pending;

      // THEN
      expect(image.encoded, isFalse);
      expect(result, isA<CaptureFailure>());
      expect(
        (result as CaptureFailure).error,
        CaptureError.renderBoundaryNotFound,
      );
      expect(image.disposed, isTrue);
    });
  });
}
