package com.resumeallinone.resume_all_in_one_client

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale

/** 在 ContentResolver 读取边界限制正文，不经会先分配整文件的选择器插件。 */
class ResumeTextImport(
    private val activity: Activity,
    private val archive: Boolean = false,
    private val openPicker: (Intent, Int) -> Unit = { intent, code ->
        activity.startActivityForResult(intent, code)
    },
) {
    companion object {
        const val PICK_REQUEST = 2802
        const val MAX_BYTES = 512 * 1024
        const val ARCHIVE_PICK_REQUEST = 2803
        const val ARCHIVE_MAX_BYTES = 8 * 1024 * 1024
    }

    private class InputTooLarge(val document: Boolean = false) : Exception()
    private class UnsupportedType : Exception()
    private var busy = false
    private var reading = false
    @Volatile
    private var pending: MethodChannel.Result? = null
    private val requestCode get() = if (archive) ARCHIVE_PICK_REQUEST else PICK_REQUEST

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != if (archive) "pickLocalDataArchiveFile" else "pickResumeTextFile") {
            result.notImplemented()
            return
        }
        if (busy) {
            result.error("file_import_failed", "Another import is open", null)
            return
        }
        busy = true
        pending = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = if (archive) "application/json" else "*/*"
                // Providers often report DOCX/PDF as generic or incorrect MIME types.
                // Keep the picker open; validate the chosen extension and actual content below.
            }
            openPicker(intent, requestCode)
        } catch (_: Exception) {
            pending = null
            busy = false
            result.error("file_import_failed", "Unable to open the file picker", null)
        }
    }

    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != this.requestCode) return false
        val result = pending ?: return true
        if (reading) return true
        if (resultCode != Activity.RESULT_OK) {
            pending = null
            busy = false
            result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") {
            pending = null
            busy = false
            result.error("file_import_failed", "No readable document selected", null)
            return true
        }
        reading = true
        Thread {
            try {
                if (pending !== result) return@Thread
                val resolver = activity.contentResolver
                var fileName: String? = null
                var declaredSize: Long? = null
                resolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                            fileName = cursor.getString(nameIndex)
                        }
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                            declaredSize = cursor.getLong(sizeIndex)
                        }
                    }
                }
                val name = fileName ?: throw UnsupportedType()
                val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                if (name.isBlank() || name.length > 1024 ||
                    extension !in if (archive) setOf("json") else setOf("txt", "md", "docx", "pdf", "doc")) {
                    throw UnsupportedType()
                }
                if (!archive && extension == "doc") throw DocumentImportFailure("legacy_word_document")
                val isDocument = !archive && extension in setOf("docx", "pdf")
                val maxBytes = if (archive) ARCHIVE_MAX_BYTES else if (isDocument) ResumeDocumentTextExtractor.MAX_FILE_BYTES else MAX_BYTES
                // Provider 长度不可信：已知超限在分配前拒绝，未知/增长再逐块检查。
                if ((declaredSize ?: 0L) > maxBytes) throw InputTooLarge(isDocument)
                if (pending !== result) return@Thread
                val bytes = resolver.openInputStream(uri)?.use { input ->
                    val output = ByteArrayOutputStream(8192)
                    val buffer = ByteArray(8192)
                    var total = 0
                    while (true) {
                        if (pending !== result) return@Thread
                        val count = input.read(buffer)
                        if (pending !== result) return@Thread
                        if (count < 0) break
                        if (count > maxBytes - total) throw InputTooLarge(isDocument)
                        output.write(buffer, 0, count)
                        total += count
                    }
                    output.toByteArray()
                } ?: error("No input stream")
                val text = if (isDocument) IsolatedDocumentImport.extract(
                    activity.applicationContext, bytes, extension,
                ) { pending === result } else null
                activity.runOnUiThread {
                    if (pending !== result) return@runOnUiThread
                    pending = null
                    busy = false
                    reading = false
                    if (activity.isFinishing || activity.isDestroyed) {
                        result.success(null)
                    } else {
                        result.success(mapOf("fileName" to name,
                            "bytes" to if (text == null) bytes else ByteArray(0),
                            "extractedText" to text,
                            "format" to if (text == null) null else extension))
                    }
                }
            } catch (failure: DocumentImportFailure) {
                fail(result, failure.code, "Unable to extract this document")
            } catch (failure: InputTooLarge) {
                fail(result, if (failure.document) "document_input_too_large" else "input_too_large", "Import exceeds the allowed size")
            } catch (_: UnsupportedType) {
                fail(result, "unsupported_file_type", "Unsupported import type")
            } catch (_: Exception) {
                fail(result, "file_import_failed", "Unable to read the selected file")
            }
        }.start()
        return true
    }

    private fun fail(result: MethodChannel.Result, code: String, message: String) {
        activity.runOnUiThread {
            if (pending !== result) return@runOnUiThread
            pending = null
            busy = false
            reading = false
            result.error(code, message, null)
        }
    }

    /** Activity 销毁时解除 Dart 等待；旧读取不再发布结果或继续累积字节。 */
    fun cancelPending() {
        val result = pending
        pending = null
        busy = false
        reading = false
        result?.success(null)
    }
}
