package com.resumeallinone.resume_all_in_one_client

import android.app.Activity
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.test.ActivityInstrumentationTestCase2
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FilterInputStream
import java.io.FilterOutputStream
import java.io.IOException
import java.io.FileNotFoundException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@Suppress("DEPRECATION")
class DocumentDeliveryTest : ActivityInstrumentationTestCase2<MainActivity>(MainActivity::class.java) {
    private class Response : MethodChannel.Result {
        val done = CountDownLatch(1)
        var value: Any? = null
        var error: String? = null
        var errorMessage: String? = null
        var completions = 0
        override fun success(result: Any?) { completions++; value = result; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { completions++; error = code; errorMessage = message; done.countDown() }
        override fun notImplemented() { error = "notImplemented"; done.countDown() }
    }

    private fun source(inExports: Boolean = true): File {
        val folder = if (inExports) File(activity.applicationInfo.dataDir, "app_flutter/resume_exports") else activity.cacheDir
        folder.mkdirs()
        return File(folder, "native_delivery_test.pdf").apply { writeBytes("%PDF-synthetic-028".toByteArray()) }
    }

    private fun request(delivery: DocumentDelivery, source: File, response: Response, mime: String = "application/pdf") {
        instrumentation.runOnMainSync { delivery.handle(MethodCall("saveAs", mapOf("path" to source.path, "mimeType" to mime)), response) }
    }

    fun testRejectsSourceOutsideExportsAndWrongMime() {
        for (outside in listOf(true, false)) {
            val file = source(!outside)
            try {
                val response = Response()
                val delivery = DocumentDelivery(activity) { _, _ -> fail("Invalid input opened a picker") }
                request(delivery, file, response, if (outside) "application/pdf" else "text/plain")
                assertTrue(response.done.await(5, TimeUnit.SECONDS))
                assertEquals("file_delivery_failed", response.error)
                assertEquals("%PDF-synthetic-028", file.readText())
            } finally { file.delete() }
        }
    }

    fun testSaveCancellationKeepsPrivateOriginal() {
        val file = source()
        try {
            val ready = CountDownLatch(1)
            val response = Response()
            val delivery = DocumentDelivery(activity) { intent, code ->
                assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
                assertEquals(DocumentDelivery.SAVE_REQUEST, code)
                ready.countDown()
            }
            request(delivery, file, response)
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_CANCELED, null) }
            assertTrue(response.done.await(5, TimeUnit.SECONDS))
            assertEquals("cancelled", response.value)
            assertEquals("%PDF-synthetic-028", file.readText())
        } finally { file.delete() }
    }

    fun testChosenContentUriWritesSameBytesAndDeniedPermissionKeepsOriginal() {
        val file = source()
        try {
            for (path in listOf("output", "denied")) {
                val ready = CountDownLatch(1)
                val response = Response()
                val delivery = DocumentDelivery(activity) { _, _ -> ready.countDown() }
                request(delivery, file, response)
                assertTrue(ready.await(5, TimeUnit.SECONDS))
                val uri = Uri.parse("content://com.resumeallinone.resume_all_in_one_client.test.documents/$path")
                instrumentation.runOnMainSync { delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(uri)) }
                assertTrue(response.done.await(5, TimeUnit.SECONDS))
                if (path == "output") {
                    assertEquals("saved", response.value)
                    val bytes = activity.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                    assertTrue(file.readBytes().contentEquals(bytes))
                } else {
                    assertEquals("file_delivery_failed", response.error)
                }
                assertEquals("%PDF-synthetic-028", file.readText())
            }
        } finally { file.delete() }
    }

    fun testTextAndArchiveCopiesKeepMimeNameBytesAndPrivateOriginal() {
        val cases = listOf(
            Triple("resume_exports", "json", "application/json"),
            Triple("resume_exports", "md", "text/markdown"),
            Triple("local_data_exports", "json", "application/json"),
        )
        for ((folder, extension, mime) in cases) {
            val directory = File(activity.applicationInfo.dataDir, "app_flutter/$folder").apply { mkdirs() }
            val file = File(directory, "synthetic_test.$extension").apply {
                writeText("合成档案：未知字段、稳定 ID 与历史原样保留")
            }
            try {
                val expectedBytes = file.readBytes()
                val ready = CountDownLatch(1)
                val response = Response()
                val delivery = DocumentDelivery(activity) { intent, _ ->
                    assertEquals(mime, intent.type)
                    assertEquals(
                        if (folder == "local_data_exports") "local-data.json" else "resume.$extension",
                        intent.getStringExtra(Intent.EXTRA_TITLE),
                    )
                    ready.countDown()
                }
                request(delivery, file, response, mime)
                assertTrue(ready.await(5, TimeUnit.SECONDS))
                val uri = Uri.parse("content://com.resumeallinone.resume_all_in_one_client.test.documents/output")
                instrumentation.runOnMainSync {
                    delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(uri))
                }
                assertTrue(response.done.await(5, TimeUnit.SECONDS))
                assertEquals("saved", response.value)
                val saved = activity.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                assertTrue(expectedBytes.contentEquals(saved))
                assertTrue(expectedBytes.contentEquals(file.readBytes()))
            } finally { file.delete() }
        }
    }

    fun testArchiveDirectoryDoesNotPermitOtherFormatsOrOversizeFiles() {
        val directory = File(activity.applicationInfo.dataDir, "app_flutter/local_data_exports").apply { mkdirs() }
        for ((extension, mime) in listOf("md" to "text/markdown", "json" to "application/json")) {
            val file = File(directory, "rejected.$extension")
            try {
                if (extension == "json") {
                    java.io.RandomAccessFile(file, "rw").use { it.setLength(DocumentDelivery.MAX_ARCHIVE_BYTES.toLong() + 1) }
                } else {
                    file.writeText("synthetic")
                }
                val length = file.length()
                val response = Response()
                val delivery = DocumentDelivery(activity) { _, _ -> fail("Invalid archive opened a picker") }
                request(delivery, file, response, mime)
                assertTrue(response.done.await(5, TimeUnit.SECONDS))
                assertEquals("file_delivery_failed", response.error)
                assertEquals(length, file.length())
            } finally { file.delete() }
        }
    }

    private val outputUri: Uri
        get() = Uri.parse("content://com.resumeallinone.resume_all_in_one_client.test.documents/output")

    private fun consumeInterruption(delivery: DocumentDelivery): Boolean {
        val response = Response()
        instrumentation.runOnMainSync { delivery.handle(MethodCall("consumeInterruptedSave", null), response) }
        assertNull(response.error)
        return response.value as Boolean
    }

    private fun assertExternalCopyRemoved() {
        try {
            activity.contentResolver.openInputStream(outputUri)?.close()
            fail("Partial external copy remains")
        } catch (_: FileNotFoundException) {
            // DocumentsContract deletion was observed through the actual provider.
        }
    }

    fun testDestroyedPickerEndsRequestAndReopenedSessionReportsInterruptionOnce() {
        val file = source()
        try {
            val ready = CountDownLatch(1)
            val response = Response()
            val delivery = DocumentDelivery(activity) { _, _ -> ready.countDown() }
            request(delivery, file, response)
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                delivery.cancelPending()
                delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(outputUri))
                delivery.cancelPending()
            }
            assertTrue(response.done.await(5, TimeUnit.SECONDS))
            assertEquals("file_delivery_interrupted", response.error)
            assertEquals(1, response.completions)
            val reopened = DocumentDelivery(activity)
            assertTrue(consumeInterruption(reopened))
            assertFalse(consumeInterruption(reopened))
            val retryReady = CountDownLatch(1)
            val retry = Response()
            val next = DocumentDelivery(activity) { _, _ -> retryReady.countDown() }
            request(next, file, retry)
            assertTrue(retryReady.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { next.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(outputUri)) }
            assertTrue(retry.done.await(5, TimeUnit.SECONDS))
            assertEquals("saved", retry.value)
            assertFalse(consumeInterruption(DocumentDelivery(activity)))
            assertEquals("%PDF-synthetic-028", file.readText())
        } finally { file.delete() }
    }

    fun testDestroyDuringPreparationEndsRequestAndRejectsReuseOfClosedScreen() {
        val file = source()
        try {
            val response = Response()
            val delivery = DocumentDelivery(activity) { _, _ -> fail("Closed screen opened a picker") }
            instrumentation.runOnMainSync {
                delivery.handle(MethodCall("saveAs", mapOf("path" to file.path, "mimeType" to "application/pdf")), response)
                delivery.cancelPending()
            }
            assertTrue(response.done.await(5, TimeUnit.SECONDS))
            assertEquals("file_delivery_interrupted", response.error)
            assertEquals(1, response.completions)
            val rejected = Response()
            request(delivery, file, rejected)
            assertTrue(rejected.done.await(5, TimeUnit.SECONDS))
            assertEquals("file_delivery_interrupted", rejected.error)
            assertTrue(consumeInterruption(DocumentDelivery(activity)))
            assertEquals("%PDF-synthetic-028", file.readText())
        } finally { file.delete() }
    }

    fun testInputOutputFlushAndCloseFailuresRejectSuccessAndRemovePartialCopy() {
        for (failure in listOf("read", "inputClose", "write", "flush", "outputClose")) {
            val file = source().apply { appendText("x".repeat(10000)) }
            try {
                val original = file.readBytes()
                val ready = CountDownLatch(1)
                val response = Response()
                val delivery = DocumentDelivery(
                    activity,
                    openSnapshotInput = { snapshot ->
                        object : FilterInputStream(snapshot.inputStream()) {
                            private var reads = 0
                            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                                if (failure == "read" && reads++ > 0) throw IOException("Synthetic read failure")
                                return super.read(buffer, offset, length)
                            }
                            override fun close() {
                                super.close()
                                if (failure == "inputClose") throw IOException("Synthetic input close failure")
                            }
                        }
                    },
                    openDestination = { uri ->
                        object : FilterOutputStream(activity.contentResolver.openOutputStream(uri, "wt")!!) {
                            override fun write(buffer: ByteArray, offset: Int, length: Int) {
                                if (failure == "write") {
                                    out.write(buffer, offset, minOf(length, 2))
                                    throw IOException("Synthetic partial write failure")
                                }
                                out.write(buffer, offset, length)
                            }
                            override fun flush() {
                                super.flush()
                                if (failure == "flush") throw IOException("Synthetic flush failure")
                            }
                            override fun close() {
                                // Close the underlying descriptor even when flush is the failing boundary.
                                out.close()
                                if (failure == "outputClose") throw IOException("Synthetic output close failure")
                            }
                        }
                    },
                    openSavePicker = { _, _ -> ready.countDown() },
                )
                request(delivery, file, response)
                assertTrue(ready.await(5, TimeUnit.SECONDS))
                instrumentation.runOnMainSync { delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(outputUri)) }
                assertTrue(response.done.await(5, TimeUnit.SECONDS))
                assertEquals("file_delivery_failed", response.error)
                assertNull(response.value)
                assertEquals(1, response.completions)
                assertTrue(original.contentEquals(file.readBytes()))
                assertExternalCopyRemoved()
                assertFalse(consumeInterruption(DocumentDelivery(activity)))
            } finally { file.delete() }
        }
    }

    fun testDestroyDuringCopyNeverPublishesLateSuccessAndCleansPartialTarget() {
        verifyDestroyDuringCopyNeverPublishesLateSuccessAndCleansPartialTarget()
    }

    // The legacy JUnit3 scanner otherwise mistakes Kotlin's parameterless lambda helper
    // with a test* name for a non-public test method.
    private fun verifyDestroyDuringCopyNeverPublishesLateSuccessAndCleansPartialTarget() {
        val file = source()
        val writing = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closed = CountDownLatch(1)
        try {
            val ready = CountDownLatch(1)
            val response = Response()
            val delivery = DocumentDelivery(
                activity,
                openDestination = { uri ->
                    object : FilterOutputStream(activity.contentResolver.openOutputStream(uri, "wt")!!) {
                        override fun write(buffer: ByteArray, offset: Int, length: Int) {
                            out.write(buffer, offset, length)
                            writing.countDown()
                            check(release.await(5, TimeUnit.SECONDS))
                        }
                        override fun close() { out.close(); closed.countDown() }
                    }
                },
                openSavePicker = { _, _ -> ready.countDown() },
            )
            request(delivery, file, response)
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(outputUri)) }
            assertTrue(writing.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { delivery.cancelPending() }
            assertTrue(response.done.await(5, TimeUnit.SECONDS))
            assertEquals("file_delivery_interrupted", response.error)
            release.countDown()
            assertTrue(closed.await(5, TimeUnit.SECONDS))
            assertTrue(activity.contentResolver.call(outputUri, "awaitDeleted", null, null)!!.getBoolean("deleted"))
            instrumentation.runOnMainSync { }
            assertEquals(1, response.completions)
            assertNull(response.value)
            assertExternalCopyRemoved()
            assertTrue(consumeInterruption(DocumentDelivery(activity)))
            assertEquals("%PDF-synthetic-028", file.readText())
        } finally { release.countDown(); file.delete() }
    }

    fun testArchiveExactLimitCopiesAndGrowthDuringDeliveryRejectsSuccess() {
        val directory = File(activity.applicationInfo.dataDir, "app_flutter/local_data_exports").apply { mkdirs() }
        val file = File(directory, "synthetic-boundary.json")
        try {
            assertEquals(8 * 1024 * 1024, DocumentDelivery.MAX_ARCHIVE_BYTES)
            java.io.RandomAccessFile(file, "rw").use { it.setLength(DocumentDelivery.MAX_ARCHIVE_BYTES.toLong()) }
            for (grow in listOf(false, true)) {
                val ready = CountDownLatch(1)
                val response = Response()
                val delivery = DocumentDelivery(
                    activity,
                    openSnapshotInput = { snapshot ->
                        if (grow) snapshot.appendBytes(byteArrayOf(65))
                        snapshot.inputStream()
                    },
                    openSavePicker = { _, _ -> ready.countDown() },
                )
                request(delivery, file, response, "application/json")
                assertTrue(ready.await(10, TimeUnit.SECONDS))
                instrumentation.runOnMainSync { delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(outputUri)) }
                assertTrue(response.done.await(10, TimeUnit.SECONDS))
                if (grow) {
                    assertEquals("file_delivery_failed", response.error)
                    assertNull(response.value)
                    assertExternalCopyRemoved()
                } else {
                    assertEquals("saved", response.value)
                    activity.contentResolver.openInputStream(outputUri)!!.use { input ->
                        file.inputStream().use { expected ->
                            val actualBuffer = ByteArray(8192)
                            val expectedBuffer = ByteArray(8192)
                            while (true) {
                                val count = input.read(actualBuffer)
                                assertEquals(count, expected.read(expectedBuffer))
                                if (count < 0) break
                                assertTrue(actualBuffer.copyOf(count).contentEquals(expectedBuffer.copyOf(count)))
                            }
                        }
                    }
                }
                assertEquals(DocumentDelivery.MAX_ARCHIVE_BYTES.toLong(), file.length())
                assertFalse(consumeInterruption(DocumentDelivery(activity)))
            }
        } finally { file.delete() }
    }

    fun testNullOutputAndUnsupportedDeleteRemainFailuresWithoutLosingOriginal() {
        val file = source()
        val undeletable = Uri.parse("content://com.resumeallinone.resume_all_in_one_client.test.documents/undeletable")
        try {
            for (noOutput in listOf(true, false)) {
                val destination = if (noOutput) outputUri else undeletable
                val ready = CountDownLatch(1)
                val response = Response()
                val delivery = DocumentDelivery(
                    activity,
                    openDestination = { uri ->
                        val opened = activity.contentResolver.openOutputStream(uri, "wt")!!
                        if (noOutput) { opened.close(); null }
                        else object : FilterOutputStream(opened) {
                            override fun write(buffer: ByteArray, offset: Int, length: Int) {
                                out.write(buffer, offset, 2)
                                throw IOException("Synthetic write to non-deletable target failed")
                            }
                        }
                    },
                    openSavePicker = { _, _ -> ready.countDown() },
                )
                request(delivery, file, response)
                assertTrue(ready.await(5, TimeUnit.SECONDS))
                instrumentation.runOnMainSync { delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(destination)) }
                assertTrue(response.done.await(5, TimeUnit.SECONDS))
                assertEquals("file_delivery_failed", response.error)
                assertNull(response.value)
                assertTrue(response.errorMessage!!.contains("partial external copy"))
                if (noOutput) assertExternalCopyRemoved()
                else activity.contentResolver.openInputStream(undeletable)!!.use { assertEquals(2, it.readBytes().size) }
                assertEquals("%PDF-synthetic-028", file.readText())
            }
        } finally {
            activity.contentResolver.delete(undeletable, null, null)
            file.delete()
        }
    }

    fun testSavedIsPublishedOnlyAfterDestinationCloseFinishes() {
        val file = source()
        val closing = CountDownLatch(1)
        val release = CountDownLatch(1)
        try {
            val ready = CountDownLatch(1)
            val response = Response()
            val delivery = DocumentDelivery(
                activity,
                openDestination = { uri ->
                    object : FilterOutputStream(activity.contentResolver.openOutputStream(uri, "wt")!!) {
                        override fun close() {
                            closing.countDown()
                            check(release.await(5, TimeUnit.SECONDS))
                            out.close()
                        }
                    }
                },
                openSavePicker = { _, _ -> ready.countDown() },
            )
            request(delivery, file, response)
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { delivery.onResult(DocumentDelivery.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(outputUri)) }
            assertTrue(closing.await(5, TimeUnit.SECONDS))
            assertEquals(1L, response.done.count)
            assertEquals(0, response.completions)
            release.countDown()
            assertTrue(response.done.await(5, TimeUnit.SECONDS))
            assertEquals("saved", response.value)
            assertFalse(consumeInterruption(DocumentDelivery(activity)))
        } finally { release.countDown(); file.delete() }
    }

    private val original: File
        get() = File(activity.applicationInfo.dataDir, "app_flutter/resume_exports/process-death-synthetic.pdf")
    private val ready: File
        get() = File(activity.cacheDir, "process-death-ready.txt")
    private val originalBytes = "%PDF-synthetic-process-death-preserve-original".toByteArray()

    private fun actualActivityDelivery(): DocumentDelivery {
        // Keep production access private; acceptance must use the instance receiving real Activity results.
        val getter = MainActivity::class.java.getDeclaredMethod("getDocumentDelivery")
        getter.isAccessible = true
        return getter.invoke(activity) as DocumentDelivery
    }

    fun prepareForExternalForceStop() {
        original.parentFile!!.mkdirs()
        original.writeBytes(originalBytes)
        ready.delete()
        val response = Response()
        val delivery = actualActivityDelivery()
        instrumentation.runOnMainSync {
            delivery.handle(MethodCall("saveAs", mapOf("path" to original.path, "mimeType" to "application/pdf")), response)
        }
        // The host must additionally verify DocumentsUI is foreground before force-stop.
        assertFalse("Save finished before external kill was prepared", response.done.await(2, TimeUnit.SECONDS))
        assertTrue(activity.getSharedPreferences("file_delivery", Context.MODE_PRIVATE).getBoolean("save_interrupted", false))
        assertTrue(originalBytes.contentEquals(original.readBytes()))
        ready.writeText("pending-system-save; private-synthetic-original-preserved")
        Log.i("DeliveryProcessDeath", "READY_FOR_EXTERNAL_FORCE_STOP")
        // Intentional named-driver wait; timeout is a visible failure, never a synthetic success.
        assertTrue("Host did not force-stop the pending process within 60 seconds", response.done.await(60, TimeUnit.SECONDS))
        fail("Preparation must be terminated by an external process kill, not completed in-process")
    }

    fun retryPrivateOriginalWithSystemPicker() {
        assertTrue("Original missing after process death", original.isFile)
        assertTrue(originalBytes.contentEquals(original.readBytes()))
        assertFalse("Startup did not consume the persisted interruption marker", activity.getSharedPreferences("file_delivery", Context.MODE_PRIVATE).getBoolean("save_interrupted", false))
        val delivery = actualActivityDelivery()
        repeat(2) {
            val consumed = Response()
            instrumentation.runOnMainSync { delivery.handle(MethodCall("consumeInterruptedSave", null), consumed) }
            assertNull(consumed.error)
            assertEquals(false, consumed.value)
        }
        val response = Response()
        instrumentation.runOnMainSync {
            delivery.handle(MethodCall("saveAs", mapOf("path" to original.path, "mimeType" to "application/pdf")), response)
        }
        Log.i("DeliveryProcessDeath", "READY_FOR_REAL_SYSTEM_RESAVE")
        assertTrue("Host did not select a real destination within 60 seconds", response.done.await(60, TimeUnit.SECONDS))
        assertNull(response.error)
        assertEquals("saved", response.value)
        assertTrue(originalBytes.contentEquals(original.readBytes()))
        assertFalse(activity.getSharedPreferences("file_delivery", Context.MODE_PRIVATE).getBoolean("save_interrupted", false))
        ready.delete()
        Log.i("DeliveryProcessDeath", "REAL_SYSTEM_RESAVE_SUCCEEDED_ORIGINAL_UNCHANGED")
    }
}
