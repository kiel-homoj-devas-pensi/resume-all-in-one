import 'dart:convert';
import 'dart:typed_data';

import 'json_support.dart';

/// 本地版本保存的打印用照片；导入层保留整图比例，移除源文件元数据。
final class ResumePhoto {
  ResumePhoto({
    required this.dataBase64,
    required this.mimeType,
    required this.width,
    required this.height,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions) {
    if (mimeType != 'image/jpeg' ||
        width != canvasWidth ||
        height != canvasHeight) {
      schemaError('/profile/photo', '照片必须是规范化的 500×700 JPEG');
    }
    if (dataBase64.length > ((maxBytes + 2) ~/ 3) * 4) {
      schemaError('/profile/photo/dataBase64', '打印用照片超过 512 KiB');
    }
    Uint8List data;
    try {
      data = base64Decode(dataBase64);
    } on FormatException {
      schemaError('/profile/photo/dataBase64', '照片编码无效');
    }
    if (data.length > maxBytes ||
        base64Encode(data) != dataBase64 ||
        !_matchesJpegCanvas(data)) {
      schemaError('/profile/photo', '照片数据或尺寸无效');
    }
  }

  static const canvasWidth = 500;
  static const canvasHeight = 700;
  static const maxBytes = 512 * 1024;
  final String dataBase64;
  final String mimeType;
  final int width;
  final int height;
  final JsonMap extensions;

  Uint8List get bytes => base64Decode(dataBase64);

  factory ResumePhoto.fromJson(
    JsonMap json, [
    String path = '/profile/photo',
  ]) => ResumePhoto(
    dataBase64: expectString(json['dataBase64'], '$path/dataBase64'),
    mimeType: expectString(json['mimeType'], '$path/mimeType'),
    width: expectInt(json['width'], '$path/width'),
    height: expectInt(json['height'], '$path/height'),
    extensions: unknownFields(json, const {
      'dataBase64',
      'mimeType',
      'width',
      'height',
    }),
  );

  JsonMap toJson() => {
    ...extensions,
    'dataBase64': dataBase64,
    'mimeType': mimeType,
    'width': width,
    'height': height,
  };

  static bool _matchesJpegCanvas(Uint8List data) {
    if (data.length < 16 ||
        data[0] != 0xff ||
        data[1] != 0xd8 ||
        data[data.length - 2] != 0xff ||
        data.last != 0xd9)
      return false;
    var offset = 2;
    var hasFrame = false;
    while (offset + 3 < data.length) {
      if (data[offset++] != 0xff) return false;
      while (offset < data.length && data[offset] == 0xff) {
        offset++;
      }
      if (offset + 2 >= data.length) return false;
      final marker = data[offset++];
      if (marker == 0xda)
        return hasFrame; // Scan data is decoded by the rendering layer.
      final size = (data[offset] << 8) | data[offset + 1];
      if (size < 2 || offset + size > data.length) return false;
      // Normalizer produces baseline JPEG, without metadata or external references.
      if (marker == 0xc0) {
        if (hasFrame || size < 8 || data[offset + 2] != 8) return false;
        final actualHeight = (data[offset + 3] << 8) | data[offset + 4];
        final actualWidth = (data[offset + 5] << 8) | data[offset + 6];
        if (actualWidth != canvasWidth || actualHeight != canvasHeight)
          return false;
        hasFrame = true;
      } else if (marker >= 0xc1 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc) {
        return false;
      }
      offset += size;
    }
    return false;
  }
}
