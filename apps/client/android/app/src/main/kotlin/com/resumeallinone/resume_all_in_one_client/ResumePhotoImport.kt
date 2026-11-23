package com.resumeallinone.resume_all_in_one_client

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.media.ExifInterface
import android.os.Handler
import android.os.CancellationSignal
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.Locale
import kotlin.math.min

internal class PhotoImportFailure(val code: String) : Exception()

/** No original file, EXIF, location or URI is persisted; the full image fits a white canvas. */
internal object ResumePhotoNormalizer {
    const val MAX_INPUT_BYTES = 10 * 1024 * 1024
    const val MAX_OUTPUT_BYTES = 512 * 1024
    const val WIDTH = 500
    const val HEIGHT = 700

    fun normalize(bytes: ByteArray, fileName: String): ByteArray {
        if (bytes.size > MAX_INPUT_BYTES) throw PhotoImportFailure("photo_too_large")
        val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val mime = when (extension) {
            "jpg" -> "image/jpeg"
            "png" -> "image/png"
            else -> throw PhotoImportFailure("photo_unsupported")
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outMimeType != mime || bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw PhotoImportFailure("photo_invalid")
        }
        if (bounds.outWidth > 32768 || bounds.outHeight > 32768 ||
            bounds.outWidth.toLong() * bounds.outHeight > 100_000_000L) {
            throw PhotoImportFailure("photo_dimensions")
        }
        val orientation = if (mime == "image/jpeg") {
            if (bytes.size < 4 || bytes[bytes.size - 2] != 0xff.toByte() ||
                bytes.last() != 0xd9.toByte()) throw PhotoImportFailure("photo_invalid")
            ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
            )
        } else ExifInterface.ORIENTATION_NORMAL
        var sample = 1
        while (bounds.outWidth / sample > 1600 || bounds.outHeight / sample > 1600) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample })
            ?: throw PhotoImportFailure("photo_invalid")
        var oriented: Bitmap? = null
        var canvasBitmap: Bitmap? = null
        try {
            val matrix = Matrix().apply {
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> setScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(270f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(270f)
                }
            }
            oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
            canvasBitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(canvasBitmap)
            canvas.drawColor(Color.WHITE)
            val scale = min(WIDTH.toFloat() / oriented.width, HEIGHT.toFloat() / oriented.height)
            val width = oriented.width * scale
            val height = oriented.height * scale
            val left = (WIDTH - width) / 2
            val top = (HEIGHT - height) / 2
            canvas.drawBitmap(oriented, null, RectF(left, top, left + width, top + height),
                Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
            val output = ByteArrayOutputStream()
            if (!canvasBitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)) {
                throw PhotoImportFailure("photo_invalid")
            }
            val result = output.toByteArray()
            if (result.size > MAX_OUTPUT_BYTES) throw PhotoImportFailure("photo_too_large")
            return result
        } finally {
            canvasBitmap?.recycle()
            if (oriented !== decoded) oriented?.recycle()
            decoded.recycle()
        }
    }
}

/** One bounded SAF read at a time, no broad storage permission or retained URI grant. */
internal class ResumePhotoImport(
    private val activity: Activity,
    private val openPicker: (Intent, Int) -> Unit = { intent, code -> activity.startActivityForResult(intent, code) },
    private val readTimeoutMillis: Long = 20_000,
) {
    companion object { const val PICK_REQUEST = 47013 }
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var pending: MethodChannel.Result? = null
    @Volatile private var reading = false
    @Volatile private var stream: InputStream? = null
    @Volatile private var cancellation: CancellationSignal? = null
    private var cancelRequested = false
    private var timeout: Runnable? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancelPhotoImport") { cancelPending(); result.success(null); return }
        if (call.method != "pickResumePhoto") { result.notImplemented(); return }
        if (pending != null || reading) { result.error("photo_busy", "Photo import is busy", null); return }
        pending = result
        try {
            openPicker(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/jpeg", "image/png"))
            }, PICK_REQUEST)
        } catch (_: Exception) { finish(result, "photo_read_failed") }
    }

    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val result = pending ?: return true
        if (resultCode != Activity.RESULT_OK) { finish(result); return true }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") { finish(result, "photo_read_failed"); return true }
        reading = true
        cancelRequested = false
        val signal = CancellationSignal()
        cancellation = signal
        timeout = Runnable { if (pending === result) { finish(result, "photo_timeout"); cancelRead() } }
            .also { handler.postDelayed(it, readTimeoutMillis) }
        Thread {
            try {
                val resolver = activity.contentResolver
                var name: String? = null
                var size: Long? = null
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null, signal)?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                        if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                    }
                }
                if (pending !== result) return@Thread
                if ((size ?: 0L) > ResumePhotoNormalizer.MAX_INPUT_BYTES) throw PhotoImportFailure("photo_too_large")
                val fileName = name ?: throw PhotoImportFailure("photo_unsupported")
                if (fileName.length > 1024) throw PhotoImportFailure("photo_unsupported")
                signal.throwIfCanceled()
                val descriptor = resolver.openAssetFileDescriptor(uri, "r", signal) ?: throw PhotoImportFailure("photo_read_failed")
                if (pending !== result) { descriptor.close(); return@Thread }
                val input = try { descriptor.createInputStream() } catch (error: Exception) { descriptor.close(); throw error }
                stream = input
                val bytes = input.use {
                    val output = ByteArrayOutputStream(8192)
                    val buffer = ByteArray(8192)
                    while (true) {
                        if (pending !== result) return@Thread
                        val count = it.read(buffer)
                        if (pending !== result) return@Thread
                        if (count < 0) break
                        if (count > ResumePhotoNormalizer.MAX_INPUT_BYTES - output.size()) throw PhotoImportFailure("photo_too_large")
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                stream = null
                if (pending !== result) return@Thread
                val photo = ResumePhotoNormalizer.normalize(bytes, fileName)
                activity.runOnUiThread {
                    if (pending === result) finish(result, bytes = photo)
                }
            } catch (failure: PhotoImportFailure) {
                activity.runOnUiThread { if (pending === result) finish(result, failure.code) }
            } catch (_: OutOfMemoryError) {
                activity.runOnUiThread { if (pending === result) finish(result, "photo_dimensions") }
            } catch (_: Exception) {
                activity.runOnUiThread { if (pending === result) finish(result, "photo_read_failed") }
            } finally { stream = null; cancellation = null; reading = false }
        }.start()
        return true
    }

    private fun finish(result: MethodChannel.Result, code: String? = null, bytes: ByteArray? = null) {
        if (pending !== result) return
        timeout?.let(handler::removeCallbacks)
        timeout = null
        pending = null
        if (code != null) result.error(code, "Unable to import photo", null)
        else result.success(bytes?.let { mapOf("bytes" to it, "mimeType" to "image/jpeg", "width" to 500, "height" to 700) })
    }

    private fun cancelRead() {
        if (cancelRequested) return
        val oldSignal = cancellation
        val oldStream = stream
        if (oldSignal == null && oldStream == null) return
        cancelRequested = true
        // A remote provider's cancellation/close must never block the Activity main thread.
        // Keep `reading` until the sole reader exits; do not create unbounded replacement readers.
        Thread {
            try { oldSignal?.cancel() } catch (_: Exception) {}
            try { oldStream?.close() } catch (_: Exception) {}
        }.start()
    }
    fun cancelPending() { pending?.let { finish(it) }; cancelRead() }
}
