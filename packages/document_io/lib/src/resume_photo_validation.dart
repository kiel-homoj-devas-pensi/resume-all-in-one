import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// JPEG 头部校验之外实际解码像素，阻止坏扫描数据进入 Word/PDF 成品。
void validatePrintPhotoBytes(Uint8List bytes) {
  try {
    _validateFrameResources(bytes);
    final decoded = image.JpegDecoder().decode(bytes);
    if (decoded == null ||
        decoded.width != 500 ||
        decoded.height != 700 ||
        decoded.exif.imageIfd.orientation != null &&
            decoded.exif.imageIfd.orientation != 1) {
      throw const FormatException('证件照像素或方向无效，请重新选择照片。');
    }
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('证件照像素无法读取，请重新选择照片。');
  }
}

void _validateFrameResources(Uint8List bytes) {
  if (bytes.length > 512 * 1024) {
    throw const FormatException('打印用照片超过 512 KiB。');
  }
  var offset = 2;
  var frames = 0;
  while (offset + 3 < bytes.length) {
    if (bytes[offset++] != 0xff) {
      throw const FormatException('证件照结构无效。');
    }
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset + 2 >= bytes.length) throw const FormatException('证件照结构不完整。');
    final marker = bytes[offset++];
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) {
      throw const FormatException('证件照结构不完整。');
    }
    if (marker == 0xc0) {
      if (++frames != 1 ||
          length < 8 ||
          bytes[offset + 2] != 8 ||
          ((bytes[offset + 3] << 8) | bytes[offset + 4]) != 700 ||
          ((bytes[offset + 5] << 8) | bytes[offset + 6]) != 500) {
        throw const FormatException('证件照画布无效。');
      }
      final count = bytes[offset + 7];
      if ((count != 1 && count != 3) || length != 8 + count * 3) {
        throw const FormatException('证件照颜色通道超出读取范围。');
      }
      final ids = <int>{};
      for (var i = 0; i < count; i++) {
        final start = offset + 8 + i * 3;
        final sampling = bytes[start + 1];
        if (!ids.add(bytes[start]) ||
            (sampling >> 4) < 1 ||
            (sampling >> 4) > 2 ||
            (sampling & 15) < 1 ||
            (sampling & 15) > 2 ||
            bytes[start + 2] > 3) {
          throw const FormatException('证件照颜色采样超出读取范围。');
        }
      }
    } else if (marker == 0xda) {
      if (frames != 1 ||
          length < 8 ||
          length != 6 + bytes[offset + 2] * 2 ||
          (bytes[offset + 2] != 1 && bytes[offset + 2] != 3) ||
          bytes[offset + length - 3] != 0 ||
          bytes[offset + length - 2] != 63 ||
          bytes[offset + length - 1] != 0) {
        throw const FormatException('证件照扫描结构无效。');
      }
      // 固定规范化 JPEG 只含一个 baseline 扫描，不能反复扫描放大解码成本。
      var cursor = offset + length;
      while (cursor < bytes.length - 2) {
        if (bytes[cursor++] != 0xff) continue;
        while (cursor < bytes.length && bytes[cursor] == 0xff) {
          cursor++;
        }
        if (cursor >= bytes.length) throw const FormatException('证件照扫描不完整。');
        final code = bytes[cursor++];
        if (code != 0 && !(code >= 0xd0 && code <= 0xd7)) {
          throw const FormatException('证件照包含额外扫描或附加对象。');
        }
      }
      return;
    }
    offset += length;
  }
  throw const FormatException('证件照缺少可读取像素。');
}
