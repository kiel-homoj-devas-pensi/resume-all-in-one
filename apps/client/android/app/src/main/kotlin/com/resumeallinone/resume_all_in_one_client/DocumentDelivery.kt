package com.resumeallinone.resume_all_in_one_client

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/** 系统只接收已保存导出文件的副本；私有原件始终保留。 */
class DocumentDelivery(
    private val activity: Activity,
    private val openSnapshotInput: (File) -> InputStream = { it.inputStream() },
    private val openDestination: (Uri) -> OutputStream? = {
        activity.contentResolver.openOutputStream(it, "wt")
    },
    private val openSavePicker: (Intent, Int) -> Unit = { intent, code ->
        activity.startActivityForResult(intent, code)
    },
) {
    companion object {
        const val SAVE_REQUEST = 2801
        const val MAX_DOCUMENT_BYTES = 20 * 1024 * 1024
        const val MAX_ARCHIVE_BYTES = 8 * 1024 * 1024
    }
    private class Operation(val method: String, val result: MethodChannel.Result) {
        @Volatile var cancelled = false
        var snapshot: File? = null
        var maxBytes = MAX_DOCUMENT_BYTES
    }
    private val interruption = activity.getSharedPreferences("file_delivery", Context.MODE_PRIVATE)
    private var active: Operation? = null
    private var pendingSave: Operation? = null
    private var destroyed = false

    /** Activity销毁也必须结束仍存活的Dart请求；进程死亡留下的标记由新会话消费。 */
    fun cancelPending() {
        destroyed = true
        val operation = active ?: return
        operation.cancelled = true
        pendingSave?.snapshot?.parentFile?.deleteRecursively()
        active = null
        pendingSave = null
        operation.result.error(
            "file_delivery_interrupted", "File delivery was interrupted; check the external copy", null,
        )
    }

    private fun complete(operation: Operation, value: String? = null, message: String? = null) {
        if (active !== operation || operation.cancelled) return
        active = null
        pendingSave = null
        if (operation.method == "saveAs") {
            // 只存一位状态，绝不保存正文、外部URI或私有路径。
            if (!interruption.edit().remove("save_interrupted").commit()) {
                operation.result.error("file_delivery_interrupted", "Unable to confirm delivery state; check the external copy", null)
                return
            }
        }
        if (message == null) operation.result.success(value)
        else operation.result.error("file_delivery_failed", message, null)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "consumeInterruptedSave") {
            val interrupted = active == null && interruption.getBoolean("save_interrupted", false)
            if (interrupted && !interruption.edit().remove("save_interrupted").commit()) {
                result.error("file_delivery_failed", "Unable to read delivery state", null)
            } else {
                result.success(interrupted)
            }
            return
        }
        if (call.method != "saveAs" && call.method != "share") {
            result.notImplemented()
            return
        }
        if (destroyed) {
            result.error("file_delivery_interrupted", "The file delivery screen has closed", null)
            return
        }
        if (active != null) {
            result.error("file_delivery_busy", "Another file action is open", null)
            return
        }
        val operation = Operation(call.method, result)
        active = operation
        if (call.method == "saveAs" && !interruption.edit().putBoolean("save_interrupted", true).commit()) {
            active = null
            result.error("file_delivery_failed", "Unable to prepare delivery state", null)
            return
        }
        Thread {
            var snapshot: File? = null
            try {
                val path = call.argument<String>("path") ?: error("Missing file")
                val mime = call.argument<String>("mimeType") ?: error("Missing MIME")
                val source = File(path).canonicalFile
                val exports = File(
                    activity.applicationInfo.dataDir,
                    "app_flutter/resume_exports",
                ).canonicalFile
                val archives = File(
                    activity.applicationInfo.dataDir,
                    "app_flutter/local_data_exports",
                ).canonicalFile
                val extension = source.extension.lowercase()
                val expectedMime = when (extension) {
                    "pdf" -> "application/pdf"
                    "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                    "json" -> "application/json"
                    "md" -> "text/markdown"
                    else -> error("Unsupported format")
                }
                val isArchive = source.parentFile == archives && extension == "json"
                operation.maxBytes = if (isArchive) MAX_ARCHIVE_BYTES else MAX_DOCUMENT_BYTES
                require(
                    (source.parentFile == exports || isArchive) && source.isFile &&
                        source.length() in 1..operation.maxBytes.toLong() && mime == expectedMime
                )
                val root = File(activity.cacheDir, "shared_exports").apply { mkdirs() }.canonicalFile
                // 只清理本应用的旧临时副本，不触及应用内已保存文稿。
                val expiry = System.currentTimeMillis() - 24 * 60 * 60 * 1000
                root.listFiles()?.filter {
                    it.canonicalFile.parentFile == root && it.lastModified() < expiry
                }?.forEach { it.deleteRecursively() }
                val directory = File(root, UUID.randomUUID().toString()).apply { mkdirs() }
                val prepared = File(directory, if (isArchive) "local-data.json" else "resume.$extension")
                snapshot = prepared
                source.inputStream().use { input ->
                    prepared.outputStream().use { output ->
                        val buffer = ByteArray(8192)
                        var total = 0L
                        while (true) {
                            check(!operation.cancelled)
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= operation.maxBytes)
                            output.write(buffer, 0, count)
                        }
                        require(total > 0)
                    }
                }
                activity.runOnUiThread {
                    if (operation.cancelled || active !== operation) {
                        prepared.parentFile?.deleteRecursively()
                    } else if (activity.isFinishing || activity.isDestroyed) {
                        cancelPending()
                        prepared.parentFile?.deleteRecursively()
                    } else {
                        operation.snapshot = prepared
                        launch(operation, prepared, mime)
                    }
                }
            } catch (_: Exception) {
                snapshot?.parentFile?.deleteRecursively()
                activity.runOnUiThread {
                    complete(operation, message = "Unable to prepare the selected file")
                }
            }
        }.start()
    }

    private fun launch(operation: Operation, snapshot: File, mime: String) {
        try {
            if (operation.method == "saveAs") {
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, snapshot.name)
                }
                pendingSave = operation
                openSavePicker(intent, SAVE_REQUEST)
            } else {
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.delivery", snapshot)
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = ClipData.newRawUri("resume", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                activity.startActivity(Intent.createChooser(intent, "分享所选文件"))
                // 选择器打开不能证明用户已选择目标，更不能证明收件人收到。
                complete(operation, "shareOpened")
            }
        } catch (_: Exception) {
            snapshot.parentFile?.deleteRecursively()
            complete(operation, message = "Unable to open the system picker")
        }
    }

    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SAVE_REQUEST) return false
        val pending = pendingSave ?: return true
        pendingSave = null
        if (resultCode != Activity.RESULT_OK) {
            pending.snapshot?.parentFile?.deleteRecursively()
            complete(pending, "cancelled")
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") {
            pending.snapshot?.parentFile?.deleteRecursively()
            complete(pending, message = "No writable document selected")
            return true
        }
        Thread {
            try {
                check(!pending.cancelled)
                val output = openDestination(uri)
                    ?: error("No output stream")
                output.use { destination ->
                    openSnapshotInput(requireNotNull(pending.snapshot)).use { source ->
                        val buffer = ByteArray(8192)
                        var total = 0L
                        while (true) {
                            check(!pending.cancelled)
                            val count = source.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= pending.maxBytes)
                            destination.write(buffer, 0, count)
                        }
                        require(total > 0)
                    }
                    destination.flush()
                }
                check(!pending.cancelled)
                activity.runOnUiThread {
                    complete(pending, "saved")
                }
            } catch (_: Exception) {
                // 目标是系统刚创建的文档，失败时尽量清除半份副本；原件不参与删除。
                try {
                    DocumentsContract.deleteDocument(activity.contentResolver, uri)
                } catch (_: Exception) {
                    // 某些目标不支持删除，调用方提示用户检查可能残留的目标副本。
                }
                activity.runOnUiThread {
                    complete(pending, message = "Unable to write the selected document; check for a partial external copy")
                }
            } finally {
                pending.snapshot?.parentFile?.deleteRecursively()
            }
        }.start()
        return true
    }
}
