import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';

Future<Map<String, dynamic>?> pickRoomImage() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: '图片',
        extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
        uniformTypeIdentifiers: ['public.image'],
        mimeTypes: ['image/jpeg', 'image/png', 'image/webp', 'image/gif'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 20 * 1024 * 1024) {
    throw const ApiFailure('图片不能超过 20 MB');
  }
  return prepareRoomImage(await file.readAsBytes(), file.name);
}

Future<Map<String, dynamic>> prepareRoomImage(
  Uint8List source,
  String name,
) async {
  if (source.length > 20 * 1024 * 1024) throw const ApiFailure('图片不能超过 20 MB');
  final buffer = await ui.ImmutableBuffer.fromUint8List(source);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    if (descriptor.width * descriptor.height > 100000000) {
      throw const ApiFailure('图片尺寸过大');
    }
    for (var edge = 1600; edge >= 300; edge = (edge * .75).floor()) {
      final scale =
          (edge /
                  (descriptor.width > descriptor.height
                      ? descriptor.width
                      : descriptor.height))
              .clamp(0.0, 1.0);
      final codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round().clamp(1, 1600),
        targetHeight: (descriptor.height * scale).round().clamp(1, 1600),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final output = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      if (output != null && output.lengthInBytes <= 512 * 1024) {
        final bytes = output.buffer.asUint8List(
          output.offsetInBytes,
          output.lengthInBytes,
        );
        return {
          'name': name,
          'type': 'image/png',
          'size': bytes.length,
          'dataUrl': 'data:image/png;base64,${base64Encode(bytes)}',
        };
      }
    }
    throw const ApiFailure('图片压缩失败，请选择较小的图片');
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

Future<String?> importRoomFile() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: 'JSON 存档',
        extensions: ['json'],
        uniformTypeIdentifiers: ['public.json'],
        mimeTypes: ['application/json'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 20 * 1024 * 1024) {
    throw const ApiFailure('存档不能超过 20 MB');
  }
  return file.readAsString();
}

Future<bool> exportRoomFile(
  BuildContext context,
  Uint8List bytes,
  String name,
  String mime,
) async {
  final file = XFile.fromData(bytes, name: name, mimeType: mime);
  if (!kIsWeb &&
      [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ].contains(defaultTargetPlatform)) {
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await file.saveTo(location.path);
    return true;
  }
  if (!context.mounted) return false;
  final box = context.findRenderObject() as RenderBox?;
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [file],
      fileNameOverrides: [name],
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
  return result.status != ShareResultStatus.dismissed;
}
