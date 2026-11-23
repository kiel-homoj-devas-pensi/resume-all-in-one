package com.resumeallinone.resume_all_in_one_client

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Called from the file-reader thread, after the user has finished choosing a file. */
internal object IsolatedDocumentImport {
    const val TIMEOUT_MILLIS = 15000L

    @Synchronized
    fun extract(context: Context, bytes: ByteArray, format: String,
        timeoutMillis: Long = TIMEOUT_MILLIS, active: () -> Boolean): String {
        require(timeoutMillis in 1..TIMEOUT_MILLIS)
        check(Looper.myLooper() != Looper.getMainLooper())
        if (!active()) throw DocumentImportFailure("document_cancelled")
        val completed = CountDownLatch(1)
        val processExited = CountDownLatch(1)
        val processBinder = AtomicReference<IBinder?>(null)
        val closed = AtomicBoolean(false)
        val delivered = AtomicBoolean(false)
        val pipe = ParcelFileDescriptor.createPipe()
        var extracted: String? = null
        var failure: String? = null
        fun finish(text: String?, error: String?) {
            if (!closed.get() && delivered.compareAndSet(false, true)) {
                extracted = text
                failure = error
                completed.countDown()
            }
        }
        val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (!closed.get() && message.what == 2) {
                finish(message.data.getByteArray("text")?.toString(Charsets.UTF_8), message.data.getString("error"))
            }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                if (closed.get()) return
                try {
                    processBinder.set(service)
                    service.linkToDeath({ processExited.countDown() }, 0)
                    Messenger(service).send(Message.obtain().apply {
                        what = 1
                        replyTo = reply
                        data = Bundle().apply {
                            putParcelable("input", pipe[0])
                            putString("format", format)
                        }
                    })
                    pipe[0].close()
                    Thread {
                        try {
                            ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { it.write(bytes) }
                        } catch (_: Exception) {
                            if (!closed.get()) {
                                finish(null, "invalid_document")
                            }
                        }
                    }.start()
                } catch (_: Exception) {
                    finish(null, "invalid_document")
                }
            }
            override fun onServiceDisconnected(name: ComponentName) {
                processExited.countDown()
                if (!closed.get()) {
                    finish(null, "document_too_complex")
                }
            }
            override fun onNullBinding(name: ComponentName) {
                finish(null, "invalid_document")
            }
        }
        var bound = false
        try {
            bound = context.bindService(Intent(context, ResumeDocumentImportService::class.java), connection, Context.BIND_AUTO_CREATE)
            if (!bound) throw DocumentImportFailure("invalid_document")
            val deadline = SystemClock.elapsedRealtime() + timeoutMillis
            while (!completed.await(100, TimeUnit.MILLISECONDS)) {
                if (!active()) throw DocumentImportFailure("document_cancelled")
                if (SystemClock.elapsedRealtime() >= deadline) throw DocumentImportFailure("document_timeout")
            }
            if (!active()) throw DocumentImportFailure("document_cancelled")
            if (SystemClock.elapsedRealtime() >= deadline) throw DocumentImportFailure("document_timeout")
            failure?.let { throw DocumentImportFailure(it) }
            return extracted ?: throw DocumentImportFailure("invalid_document")
        } finally {
            closed.set(true)
            for (descriptor in pipe) try { descriptor.close() } catch (_: Exception) { }
            if (bound) {
                context.unbindService(connection)
                // Do not let an immediate retry rebind the one-shot service while its old
                // worker is being destroyed. Death notification comes from Binder, not polling.
                if (processBinder.get()?.isBinderAlive == true) {
                    processExited.await(2, TimeUnit.SECONDS)
                }
            }
        }
    }
}
