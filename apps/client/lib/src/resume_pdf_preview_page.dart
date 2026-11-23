import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import 'resume_workspace_controller.dart';
import 'resume_file_delivery.dart';

final class ResumePdfPreviewPage extends StatefulWidget {
  const ResumePdfPreviewPage({
    super.key,
    required this.controller,
    required this.preparedPdf,
  });

  final ResumeWorkspaceController controller;
  final PreparedResumePdf preparedPdf;

  @override
  State<ResumePdfPreviewPage> createState() => _ResumePdfPreviewPageState();
}

final class _ResumePdfPreviewPageState extends State<ResumePdfPreviewPage> {
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'PDF 预览',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const Key('另存预览PDF'),
            tooltip: '另存 PDF 到选择的位置',
            onPressed: _isExporting
                ? null
                : () => _deliver(ResumeFileDeliveryAction.saveAs),
            icon: const Icon(Icons.save_alt),
          ),
          IconButton(
            key: const Key('分享预览PDF'),
            tooltip: '分享当前 PDF',
            onPressed: _isExporting
                ? null
                : () => _deliver(ResumeFileDeliveryAction.share),
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            key: const Key('导出预览PDF'),
            tooltip: '导出到应用目录',
            onPressed: _isExporting ? null : _exportPreviewedPdf,
            icon: _isExporting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: '正在导出 PDF',
                    ),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.verified_outlined, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.preparedPdf.wordSourcePath == null
                          ? '已保存版本 · A4 文档\n另存与分享使用当前预览的相同内容。'
                          : '来源：已保存的 Word 文稿 · A4\n导出与当前预览一致。需要修改时，请返回 Word 文稿。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PdfPreview(
                key: const Key('本地PDF预览'),
                build: (_) async => widget.preparedPdf.bytes,
                initialPageFormat: PdfPageFormat.a4,
                allowPrinting: false,
                allowSharing: false,
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
                useActions: false,
                padding: const EdgeInsets.all(16),
                scrollViewDecoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                ),
                // 应用主题只影响阅读背景；PDF 本身的白色纸张和导出字节不变。
                pdfPreviewPageDecoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: 0.12),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                loadingWidget: const Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: '正在加载 PDF 预览',
                  ),
                ),
                onError: (context, _) => SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.picture_as_pdf_outlined,
                        size: 40,
                        color: colors.error,
                      ),
                      const SizedBox(height: 16),
                      const Text('无法显示 PDF 预览，请返回后重试。'),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('返回简历'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportPreviewedPdf() async {
    setState(() => _isExporting = true);
    await widget.controller.exportPreparedPdf(widget.preparedPdf);
    if (!mounted) {
      return;
    }
    setState(() => _isExporting = false);
    final feedbackMessage = widget.controller.takeFeedback();
    if (feedbackMessage != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(feedbackMessage)));
    }
  }

  Future<void> _deliver(ResumeFileDeliveryAction action) async {
    setState(() => _isExporting = true);
    await widget.controller.deliverPreparedPdf(widget.preparedPdf, action);
    if (!mounted) return;
    setState(() => _isExporting = false);
    final feedback = widget.controller.takeFeedback();
    if (feedback != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(feedback)));
    }
  }
}
