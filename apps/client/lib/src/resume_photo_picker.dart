import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:resume_domain/resume_domain.dart';

final class ResumePhotoException implements Exception {
  const ResumePhotoException(this.message);
  final String message;
}

abstract interface class ResumePhotoPicker {
  Future<ResumePhoto?> pickPhoto();
}

final class SystemResumePhotoPicker implements ResumePhotoPicker {
  const SystemResumePhotoPicker({
    MethodChannel channel = const MethodChannel(
      'resume_all_in_one/photo_import',
    ),
  }) : _channel = channel;
  final MethodChannel _channel;

  @override
  Future<ResumePhoto?> pickPhoto() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'pickResumePhoto',
      );
      if (result == null) return null;
      final bytes = result['bytes'];
      if (bytes is! Uint8List ||
          result['mimeType'] != 'image/jpeg' ||
          result['width'] != ResumePhoto.canvasWidth ||
          result['height'] != ResumePhoto.canvasHeight) {
        throw const ResumePhotoException('照片处理结果无效，请重新选择。');
      }
      return ResumePhoto(
        dataBase64: base64Encode(bytes),
        mimeType: 'image/jpeg',
        width: ResumePhoto.canvasWidth,
        height: ResumePhoto.canvasHeight,
      );
    } on PlatformException catch (error) {
      throw ResumePhotoException(switch (error.code) {
        'photo_too_large' => '请选择不超过 10MB 的 JPG 或 PNG 照片。',
        'photo_unsupported' => '请选择 .jpg 或 .png 格式的照片。',
        'photo_invalid' => '照片损坏或扩展名与图片格式不符，请重新保存后选择。',
        'photo_dimensions' => '照片像素尺寸过大，请缩小后再选择。',
        'photo_timeout' => '读取照片超时，请将照片保存到手机后重试。',
        'photo_busy' => '上一张照片仍在读取，请稍后重试。',
        _ => '无法读取照片，请重新选择手机上的 JPG 或 PNG 文件。',
      });
    } on MissingPluginException {
      throw const ResumePhotoException('此设备暂不支持照片选择，请使用 Android 客户端。');
    } on FormatException {
      throw const ResumePhotoException('照片处理结果无效，请重新选择。');
    }
  }
}
