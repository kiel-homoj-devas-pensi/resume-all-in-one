package com.resumeallinone.resume_all_in_one_client

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.ByteArrayOutputStream

/** A bound, unexported isolated service: no app data or network privileges. */
class ResumeDocumentImportService : Service() {
    private var started = false
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what != 1 || started) return@Handler true
        started = true
        val reply = message.replyTo
        @Suppress("DEPRECATION")
        val descriptor = message.data.getParcelable<ParcelFileDescriptor>("input")
        val format = message.data.getString("format") ?: ""
        Thread {
            val result = Bundle()
            try {
                if (descriptor == null) throw DocumentImportFailure("invalid_document")
                val bytes = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                    val out = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count > ResumeDocumentTextExtractor.MAX_FILE_BYTES - out.size()) {
                            throw DocumentImportFailure("input_too_large")
                        }
                        out.write(buffer, 0, count)
                    }
                    out.toByteArray()
                }
                // UTF-8 stays under 512 KiB; a 512 KiB ASCII String would exceed Binder's
                // transaction budget after Android's UTF-16 parcel representation.
                result.putByteArray("text", ResumeDocumentTextExtractor.extract(this, bytes, format).toByteArray(Charsets.UTF_8))
            } catch (failure: DocumentImportFailure) {
                result.putString("error", failure.code)
            } catch (_: Exception) {
                result.putString("error", "invalid_document")
            }
            try {
                reply?.send(Message.obtain().apply { what = 2; data = result })
            } catch (_: Exception) { /* Caller was cancelled or destroyed. */ }
        }.start()
        true
    })

    override fun onBind(intent: Intent): IBinder = messenger.binder

    override fun onDestroy() {
        super.onDestroy()
        // Android dispatches lifecycle callbacks on this process's main thread, independently
        // of parsing. Killing only our isolated UID process also terminates a stuck parser.
        if (Process.myUid() != applicationInfo.uid) Process.killProcess(Process.myPid())
    }
}
