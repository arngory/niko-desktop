import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';
import 'package:zxing2/qrcode.dart';

import '../l10n/strings.dart';
import '../theme/niko_theme.dart';
import 'banner.dart';
import 'dialog.dart';
import 'icons.dart';

/// Encodes [data] into a QR matrix with medium error correction, or returns null if the payload
/// exceeds QR version 40 capacity.
QrImage? encodeQrImage(String data) {
  if (data.isEmpty) return null;
  try {
    final code = QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    );
    return QrImage(code);
  } on InputTooLongException {
    return null;
  } catch (_) {
    return null;
  }
}

/// Renders [data] into a raw RGBA pixel buffer (black modules on white background with quiet zone).
/// Useful both for testing round-trip decoding and for off-screen rasterization.
({Uint8List rgba, int width, int height})? renderQrToRgba(
  String data, {
  int modulePx = 6,
  int quietModules = 4,
}) {
  final qr = encodeQrImage(data);
  if (qr == null) return null;
  final modules = qr.moduleCount;
  final totalModules = modules + quietModules * 2;
  final size = totalModules * modulePx;
  final rgba = Uint8List(size * size * 4);
  // Fill opaque white background.
  rgba.fillRange(0, rgba.length, 255);
  for (var y = 0; y < modules; y++) {
    for (var x = 0; x < modules; x++) {
      if (!qr.isDark(y, x)) continue;
      final px0 = (x + quietModules) * modulePx;
      final py0 = (y + quietModules) * modulePx;
      for (var dy = 0; dy < modulePx; dy++) {
        final rowStart = ((py0 + dy) * size + px0) * 4;
        for (var dx = 0; dx < modulePx; dx++) {
          final off = rowStart + dx * 4;
          rgba[off] = 0;
          rgba[off + 1] = 0;
          rgba[off + 2] = 0;
          rgba[off + 3] = 255;
        }
      }
    }
  }
  return (rgba: rgba, width: size, height: size);
}

/// Decodes a QR code string from raw RGBA8888 pixels using pure-Dart ZXing.
/// Tries hybrid binarizer first, then global histogram, then inverted luminance (for dark-theme QRs).
String? decodeQrFromRgba(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) return null;
  final count = width * height;
  final pixels = Int32List(count);
  for (var i = 0; i < count; i++) {
    final off = i * 4;
    final a = rgba[off + 3];
    // Alpha-composite over white so transparent-background QR PNGs stay high contrast.
    final r = a == 255 ? rgba[off] : ((rgba[off] * a + 255 * (255 - a)) ~/ 255);
    final g = a == 255 ? rgba[off + 1] : ((rgba[off + 1] * a + 255 * (255 - a)) ~/ 255);
    final b = a == 255 ? rgba[off + 2] : ((rgba[off + 2] * a + 255 * (255 - a)) ~/ 255);
    pixels[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  final source = RGBLuminanceSource(width, height, pixels);
  final reader = QRCodeReader();

  String? tryDecode(LuminanceSource src) {
    try {
      final result = reader.decode(BinaryBitmap(HybridBinarizer(src)));
      if (result.text.isNotEmpty) return result.text;
    } catch (_) {}
    try {
      final result = reader.decode(BinaryBitmap(GlobalHistogramBinarizer(src)));
      if (result.text.isNotEmpty) return result.text;
    } catch (_) {}
    return null;
  }

  return tryDecode(source) ?? tryDecode(source.invert());
}

/// Decodes a QR code from encoded image bytes (PNG, JPEG, WebP, GIF, BMP) using Flutter's built-in
/// image codec and pure-Dart ZXing. Returns null when no QR code is found or the image is invalid.
Future<String?> decodeQrFromImageBytes(Uint8List imageBytes) async {
  if (imageBytes.isEmpty) return null;
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    final rgba = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
    return decodeQrFromRgba(rgba, image.width, image.height);
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// Crisp vector QR code rendered on a white quiet-zone card so cameras scan reliably in any theme.
class NikoQrView extends StatelessWidget {
  const NikoQrView({super.key, required this.data, this.size = 240});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final qr = encodeQrImage(data);
    if (qr == null) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(NikoRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(NikoSpace.s4),
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _QrPainter(qr)),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.qr);

  final QrImage qr;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = qr.moduleCount;
    if (modules <= 0) return;
    final cell = size.shortestSide / modules;
    final offsetX = (size.width - cell * modules) / 2;
    final offsetY = (size.height - cell * modules) / 2;
    final paint = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;

    for (var y = 0; y < modules; y++) {
      for (var x = 0; x < modules; x++) {
        if (!qr.isDark(y, x)) continue;
        // Slight overlap (+0.25px) eliminates hairline subpixel seams on fractional DPI displays.
        canvas.drawRect(
          Rect.fromLTWH(offsetX + x * cell, offsetY + y * cell, cell + 0.25, cell + 0.25),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.qr != qr;
}

/// Modal dialog presenting a scannable QR code for sharing a profile or subscription link.
class NikoQrDialog extends StatelessWidget {
  const NikoQrDialog({
    super.key,
    required this.title,
    required this.data,
    required this.strings,
    required this.onCopy,
    required this.onClose,
  });

  final String title;
  final String data;
  final NikoStrings strings;
  final VoidCallback onCopy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final qr = encodeQrImage(data);
    return NikoDialog(
      title: title,
      cancelLabel: strings.close,
      saveLabel: strings.qrCopyLink,
      onClose: onClose,
      onSave: onCopy,
      maxWidth: 420,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (qr != null)
            Center(child: NikoQrView(data: data, size: 224))
          else
            NikoBanner(icon: NikoIcons.alert, title: strings.qrTooLong),
          const SizedBox(height: NikoSpace.s4),
          Text(
            data,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: NikoType.code.style(colors.ink2),
          ),
          const SizedBox(height: NikoSpace.s4),
        ],
      ),
    );
  }
}
