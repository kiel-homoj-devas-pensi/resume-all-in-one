package com.resumeallinone.resume_all_in_one_client

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.test.ActivityInstrumentationTestCase2
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@Suppress("DEPRECATION")
class ResumeTextImportTest : ActivityInstrumentationTestCase2<MainActivity>(MainActivity::class.java) {
    private class Response : MethodChannel.Result {
        val done = CountDownLatch(1)
        var value: Any? = null
        var error: String? = null
        @Volatile var completions = 0
        override fun success(result: Any?) { completions++; value = result; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { completions++; error = code; done.countDown() }
        override fun notImplemented() { error = "notImplemented"; done.countDown() }
    }

    private fun uri(scenario: String) = Uri.parse(
        "content://com.resumeallinone.resume_all_in_one_client.test.imports/$scenario"
    )

    private fun runImport(scenario: String): Response {
        val response = Response()
        val importer = ResumeTextImport(activity) { intent, code ->
            assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
            assertEquals(ResumeTextImport.PICK_REQUEST, code)
            assertEquals("*/*", intent.type)
            assertTrue(intent.categories?.contains(Intent.CATEGORY_OPENABLE) == true)
        }
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickResumeTextFile", null), response)
            importer.onResult(
                ResumeTextImport.PICK_REQUEST,
                Activity.RESULT_OK,
                Intent().setData(uri(scenario)),
            )
        }
        assertTrue(response.done.await(5, TimeUnit.SECONDS))
        return response
    }

    fun testKnownOversizeAndUnsupportedTypeRejectBeforeOpeningBody() {
        for ((scenario, code) in listOf(
            "known-large" to "input_too_large",
            "unsupported" to "unsupported_file_type",
        )) {
            val result = runImport(scenario)
            assertEquals(code, result.error)
            assertNull(result.value)
            activity.contentResolver.query(uri(scenario), arrayOf("opened"), null, null, null)!!.use {
                assertTrue(it.moveToFirst())
                assertEquals(0, it.getInt(0))
            }
        }
    }

    fun testUnknownAndGrowingLengthRejectWithoutTruncatedSuccess() {
        for (scenario in listOf("unknown", "growing")) {
            val result = runImport(scenario)
            assertEquals("input_too_large", result.error)
            assertNull(result.value)
        }
    }

    fun testExactLimitReturnsOriginalNameAndBytes() {
        val result = runImport("exact")
        assertNull(result.error)
        val value = result.value as Map<*, *>
        assertEquals("synthetic.MD", value["fileName"])
        val bytes = value["bytes"] as ByteArray
        assertEquals(ResumeTextImport.MAX_BYTES, bytes.size)
        assertTrue(bytes.all { it == 65.toByte() })
    }

    fun testPermissionFailureRemainsFailure() {
        val result = runImport("denied")
        assertEquals("file_import_failed", result.error)
        assertNull(result.value)
    }

    fun testCancellationAndBusyDoNotReadBody() {
        val first = Response()
        val second = Response()
        var launches = 0
        val importer = ResumeTextImport(activity) { _, _ -> launches++ }
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickResumeTextFile", null), first)
            importer.handle(MethodCall("pickResumeTextFile", null), second)
            assertFalse(importer.onResult(ResumeTextImport.PICK_REQUEST + 1, Activity.RESULT_CANCELED, null))
            importer.onResult(ResumeTextImport.PICK_REQUEST, Activity.RESULT_CANCELED, null)
        }
        assertEquals(1, launches)
        assertTrue(first.done.await(1, TimeUnit.SECONDS))
        assertTrue(second.done.await(1, TimeUnit.SECONDS))
        assertNull(first.value)
        assertNull(first.error)
        assertEquals("file_import_failed", second.error)
    }

    fun testNonContentUriRejectsAndClearsBusy() {
        val importer = ResumeTextImport(activity) { _, _ -> }
        val invalid = Response()
        val retry = Response()
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickResumeTextFile", null), invalid)
            importer.onResult(ResumeTextImport.PICK_REQUEST, Activity.RESULT_OK, Intent().setData(Uri.parse("file:///synthetic.md")))
            importer.handle(MethodCall("pickResumeTextFile", null), retry)
            importer.onResult(ResumeTextImport.PICK_REQUEST, Activity.RESULT_CANCELED, null)
        }
        assertEquals("file_import_failed", invalid.error)
        assertNull(retry.error)
        assertTrue(retry.done.await(1, TimeUnit.SECONDS))
    }

    fun testDestroyCancellationCompletesPendingAndAllowsNewPicker() {
        val importer = ResumeTextImport(activity) { _, _ -> }
        val original = Response()
        val retry = Response()
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickResumeTextFile", null), original)
            importer.cancelPending()
            assertTrue(importer.onResult(
                ResumeTextImport.PICK_REQUEST,
                Activity.RESULT_OK,
                Intent().setData(uri("exact")),
            ))
            importer.handle(MethodCall("pickResumeTextFile", null), retry)
            importer.onResult(ResumeTextImport.PICK_REQUEST, Activity.RESULT_CANCELED, null)
        }
        assertTrue(original.done.await(1, TimeUnit.SECONDS))
        assertNull(original.value)
        assertNull(original.error)
        assertTrue(retry.done.await(1, TimeUnit.SECONDS))
        assertNull(retry.value)
        assertNull(retry.error)
    }

    private fun runArchiveImport(scenario: String): Response {
        val response = Response()
        val importer = ResumeTextImport(activity, archive = true) { intent, code ->
            assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
            assertEquals(ResumeTextImport.ARCHIVE_PICK_REQUEST, code)
            assertEquals("application/json", intent.type)
            assertTrue(intent.categories?.contains(Intent.CATEGORY_OPENABLE) == true)
        }
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickLocalDataArchiveFile", null), response)
            importer.onResult(ResumeTextImport.ARCHIVE_PICK_REQUEST, Activity.RESULT_OK, Intent().setData(uri("archive-$scenario")))
        }
        assertTrue(response.done.await(10, TimeUnit.SECONDS))
        return response
    }

    fun testArchiveKnownOversizeAndUnsupportedTypeRejectBeforeOpeningBody() {
        assertEquals(8 * 1024 * 1024, ResumeTextImport.ARCHIVE_MAX_BYTES)
        for ((scenario, code) in listOf("known-large" to "input_too_large", "unsupported" to "unsupported_file_type")) {
            val result = runArchiveImport(scenario)
            assertEquals(code, result.error)
            assertNull(result.value)
            activity.contentResolver.query(uri("archive-$scenario"), arrayOf("opened"), null, null, null)!!.use {
                assertTrue(it.moveToFirst())
                assertEquals(0, it.getInt(0))
            }
        }
    }

    fun testArchiveUnknownAndGrowingLengthRejectWithoutTruncatedSuccess() {
        for (scenario in listOf("unknown", "growing")) {
            val result = runArchiveImport(scenario)
            assertEquals("input_too_large", result.error)
            assertNull(result.value)
            assertEquals(1, result.completions)
        }
    }

    fun testArchiveExactLimitReturnsOriginalNameAndBytes() {
        val result = runArchiveImport("exact")
        assertNull(result.error)
        val value = result.value as Map<*, *>
        assertEquals("synthetic.JSON", value["fileName"])
        val bytes = value["bytes"] as ByteArray
        assertEquals(ResumeTextImport.ARCHIVE_MAX_BYTES, bytes.size)
        assertTrue(bytes.all { it == 65.toByte() })
    }

    fun testArchivePermissionFailureRemainsFailure() {
        val result = runArchiveImport("denied")
        assertEquals("file_import_failed", result.error)
        assertNull(result.value)
    }

    fun testArchiveCancellationBusyAndWrongMethodDoNotOpenExtraPicker() {
        val first = Response()
        val second = Response()
        val wrongMethod = Response()
        var launches = 0
        val importer = ResumeTextImport(activity, archive = true) { _, _ -> launches++ }
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickResumeTextFile", null), wrongMethod)
            importer.handle(MethodCall("pickLocalDataArchiveFile", null), first)
            importer.handle(MethodCall("pickLocalDataArchiveFile", null), second)
            assertFalse(importer.onResult(ResumeTextImport.PICK_REQUEST, Activity.RESULT_CANCELED, null))
            importer.onResult(ResumeTextImport.ARCHIVE_PICK_REQUEST, Activity.RESULT_CANCELED, null)
        }
        assertEquals(1, launches)
        assertNull(first.value)
        assertNull(first.error)
        assertEquals("file_import_failed", second.error)
        assertEquals("notImplemented", wrongMethod.error)
    }

    fun testArchiveDestroyDuringBlockedReadSuppressesLateResultAndPreservesNewRequest() {
        val blocked = uri("archive-blocked")
        activity.contentResolver.call(blocked, "resetBlocked", null, null)
        val original = Response()
        val retry = Response()
        val importer = ResumeTextImport(activity, archive = true) { _, _ -> }
        try {
            instrumentation.runOnMainSync {
                importer.handle(MethodCall("pickLocalDataArchiveFile", null), original)
                importer.onResult(ResumeTextImport.ARCHIVE_PICK_REQUEST, Activity.RESULT_OK, Intent().setData(blocked))
            }
            assertTrue(activity.contentResolver.call(blocked, "awaitBlockedOpened", null, null)!!.getBoolean("ready"))
            instrumentation.runOnMainSync {
                importer.cancelPending()
                importer.handle(MethodCall("pickLocalDataArchiveFile", null), retry)
                importer.onResult(ResumeTextImport.ARCHIVE_PICK_REQUEST, Activity.RESULT_OK, Intent().setData(uri("archive-exact")))
            }
            activity.contentResolver.call(blocked, "releaseBlocked", null, null)
            assertTrue(activity.contentResolver.call(blocked, "awaitBlockedFinished", null, null)!!.getBoolean("ready"))
            assertTrue(original.done.await(1, TimeUnit.SECONDS))
            assertTrue(retry.done.await(10, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            assertEquals(1, original.completions)
            assertNull(original.value)
            assertNull(original.error)
            assertEquals(1, retry.completions)
            assertNull(retry.error)
            assertEquals(ResumeTextImport.ARCHIVE_MAX_BYTES, ((retry.value as Map<*, *>)["bytes"] as ByteArray).size)
        } finally {
            activity.contentResolver.call(blocked, "releaseBlocked", null, null)
        }
    }
}
