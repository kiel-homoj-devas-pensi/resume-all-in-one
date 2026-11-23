import 'package:pdf/pdf.dart';
// PdfInfo exposes its dictionary, but pdf.dart does not export its string value
// constructor in the pinned pdf 3.13.1. Keep this narrow dependency in one place.
// ignore: implementation_imports
import 'package:pdf/src/pdf/format/string.dart';
import 'package:resume_domain/resume_domain.dart';

void addResumeAigcPdfMetadata(
  PdfDocument document,
  ResumeAigcMetadata metadata,
) {
  final infos = document.objects.whereType<PdfInfo>().toList();
  if (infos.length != 1 || infos.single.params['/AIGC'] != null) {
    throw const FormatException('PDF 元数据字典缺失、重复或已包含 AIGC 标识。');
  }
  infos.single.params['/AIGC'] = PdfString.fromString(metadata.toJsonString());
}
