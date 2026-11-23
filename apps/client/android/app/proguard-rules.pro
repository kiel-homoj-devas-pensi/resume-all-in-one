# PDFBox-Android 2.0.27.0 treats JPEG2000 decoding as an optional dependency.
# This app extracts the PDF text layer, without rendering images or providing OCR.
# Suppress only the absent optional decoder; retain R8 and all other diagnostics.
# https://github.com/TomRoush/PdfBox-Android/blob/v2.0.27.0/README.md#reading-jpx-images
-dontwarn com.gemalto.jp2.JP2Decoder
