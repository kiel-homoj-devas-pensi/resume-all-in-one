import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'dart:typed_data';

import 'resume_photo_validation.dart';

/// DOCX 与两条 PDF 导出路径共用的页面尺度，单位与名称保持对应。
abstract final class ResumePageLayout {
  static const marginLeftMm = 12.0;
  static const marginRightMm = 12.0;
  static const marginTopMm = 12.0;
  static const marginBottomMm = 14.0;
  static const titleFontSize = 20.0;
  static const headingFontSize = 11.0;
  static const entryFontSize = 10.0;
  static const bodyFontSize = 10.0;
  static const metadataFontSize = 10.0;
  static const lineSpacing = 3.2;
  static const headingRuleWidth = 0.5;
  static const bulletIndent = 10.0;
  static const photoWidthMm = 25.0;
  static const photoHeightMm = 35.0;
  static const photoHeaderInsetMm = 30.0;

  /// 对称预留空间使文字仍居于 A4 中线，照片只占首页的右上角。
  static pw.Widget photoProfileHeader({
    required Uint8List bytes,
    required List<pw.Widget> text,
  }) {
    validatePrintPhotoBytes(bytes);
    return pw.Stack(
      children: [
        pw.Container(
          width: double.infinity,
          constraints: const pw.BoxConstraints(
            minHeight: photoHeightMm * PdfPageFormat.mm,
          ),
          padding: const pw.EdgeInsets.symmetric(
            horizontal: photoHeaderInsetMm * PdfPageFormat.mm,
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: text,
          ),
        ),
        pw.Positioned(
          right: 0,
          top: 0,
          child: pw.Image(
            pw.MemoryImage(bytes),
            width: photoWidthMm * PdfPageFormat.mm,
            height: photoHeightMm * PdfPageFormat.mm,
            fit: pw.BoxFit.contain,
          ),
        ),
      ],
    );
  }

  static String wrapProfileText(String text) =>
      text.replaceAllMapped(RegExp(r'[^\s\u2e80-\u9fff]{33,}'), (match) {
        final runes = match[0]!.runes.toList();
        return [
          for (var start = 0; start < runes.length; start += 32)
            String.fromCharCodes(
              runes.sublist(start, (start + 32).clamp(0, runes.length)),
            ),
        ].join('\n');
      });

  static bool canUseEntryColumns({
    required String date,
    required String title,
    required String role,
  }) {
    final parts = [date.trim(), title.trim(), role.trim()];
    // Word 制表位只有锚点，没有 PDF Row 的列宽约束；按字宽保守准入。
    return _estimatedWidth(parts[0]) <= 110 &&
        _estimatedWidth(parts[1]) <= 200 &&
        _estimatedWidth(parts[2]) <= 150 &&
        !parts.any((part) => part.contains(RegExp(r'[\r\n\t]')));
  }

  static double _estimatedWidth(String text) =>
      text.runes.fold<double>(
        0,
        (width, rune) =>
            width +
            switch (rune) {
              32 => 3,
              46 || 45 || 47 || 58 || 183 => 4,
              >= 48 && <= 57 => 6,
              77 || 87 || 109 || 119 => 10,
              >= 97 && <= 122 => 6,
              < 128 => 8,
              _ => 10,
            },
      ) *
      1.05;

  /// 长字段退为独立段落，不能把超过一页的正文困在不跨页的 Row 中。
  static List<pw.Widget> entryHeader({
    required String date,
    required String title,
    required String role,
    required pw.Font boldFont,
  }) {
    final parts = [date.trim(), title.trim(), role.trim()];
    final style = pw.TextStyle(
      font: boldFont,
      fontSize: entryFontSize,
      lineSpacing: lineSpacing,
      color: PdfColors.black,
    );
    if (!canUseEntryColumns(date: date, title: title, role: role)) {
      return [
        for (final part in parts)
          if (part.isNotEmpty)
            pw.Text(part, style: style, overflow: pw.TextOverflow.span),
      ];
    }
    return [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(width: 116, child: pw.Text(parts[0], style: style)),
          pw.Expanded(
            flex: 3,
            child: pw.Text(
              parts[1],
              style: style,
              textAlign: pw.TextAlign.center,
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Expanded(
            flex: 2,
            child: pw.Text(
              parts[2],
              style: style,
              textAlign: pw.TextAlign.right,
            ),
          ),
        ],
      ),
    ];
  }

  static pw.Widget bullet(String text) => _ResumeBullet(text);
}

/// Padding 会转发 Text 的分页上下文；续页沿用缩进但不重复第一行的圆点。
final class _ResumeBullet extends pw.Padding {
  _ResumeBullet(String text)
    : super(
        padding: const pw.EdgeInsets.only(left: ResumePageLayout.bulletIndent),
        child: pw.Text(
          text,
          style: const pw.TextStyle(
            fontSize: ResumePageLayout.bodyFontSize,
            lineSpacing: ResumePageLayout.lineSpacing,
            color: PdfColors.black,
          ),
          overflow: pw.TextOverflow.span,
        ),
      );

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final textContext =
        (child! as pw.RichText).saveContext() as pw.RichTextContext;
    if (textContext.spanStart == 0 && textContext.startOffset == 0) {
      context.canvas
        ..setFillColor(PdfColors.black)
        ..drawEllipse(box!.left + 3, box!.top - 6, 1.2, 1.2)
        ..fillPath();
    }
  }
}
