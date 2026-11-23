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
class ResumePhotoPickerIntegrationTest : ActivityInstrumentationTestCase2<MainActivity>(MainActivity::class.java) {
    private class Result : MethodChannel.Result {
        val done=CountDownLatch(1)
        var value: Any?=null
        var error: String?=null
        var completions=0
        override fun success(result: Any?) { completions++; value=result; done.countDown() }
        override fun error(code: String,message: String?,details: Any?) { completions++; error=code; done.countDown() }
        override fun notImplemented() { throw AssertionError("Method must exist") }
    }
    private fun uri(scenario: String)=Uri.parse("content://com.resumeallinone.resume_all_in_one_client.test.photos/$scenario")
    private fun picker(timeout:Long=20_000)=ResumePhotoImport(activity, {intent,request->
        assertEquals(Intent.ACTION_OPEN_DOCUMENT,intent.action)
        assertEquals("image/*",intent.type)
        assertEquals(ResumePhotoImport.PICK_REQUEST,request)
        assertFalse((intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)!=0)
    },timeout)
    private fun start(importer:ResumePhotoImport,scenario:String):Result {
        val result=Result()
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickResumePhoto",null),result)
            importer.onResult(ResumePhotoImport.PICK_REQUEST,Activity.RESULT_OK,Intent().setData(uri(scenario)))
        }
        assertTrue(result.done.await(5,TimeUnit.SECONDS))
        assertEquals(1,result.completions)
        return result
    }
    fun testActualProviderReadReturnsNormalizedJpeg() {
        val result=start(picker(),"valid")
        assertNull(result.error)
        val value=result.value as Map<*,*>
        assertEquals(500,value["width"])
        assertEquals(700,value["height"])
        assertEquals("image/jpeg",value["mimeType"])
        assertTrue((value["bytes"] as ByteArray).size<512*1024)
    }
    fun testKnownOversizeIsRejectedBeforeOpeningStream() {
        val before=opened("known-large")
        assertEquals("photo_too_large",start(picker(),"known-large").error)
        assertEquals(before,opened("known-large"))
    }
    fun testUnknownLengthGrowingStreamIsRejectedAt10MiB() {
        assertEquals("photo_too_large",start(picker(),"growing").error)
    }
    fun testTimeoutCancelsProviderWithoutBlockingUiAndAllowsRetry() {
        val importer=picker(250)
        assertEquals("photo_timeout",start(importer,"blocked").error)
        // The provider responds to CancellationSignal; the one reader must finish before retry.
        Thread.sleep(200)
        val retry=start(importer,"valid")
        assertNull(retry.error)
        assertNotNull(retry.value)
    }
    fun testSystemCancelAndActivityDestroyDoNotPublishPhoto() {
        val importer=picker()
        val result=Result()
        instrumentation.runOnMainSync {
            importer.handle(MethodCall("pickResumePhoto",null),result)
            importer.onResult(ResumePhotoImport.PICK_REQUEST,Activity.RESULT_CANCELED,null)
            importer.cancelPending()
        }
        assertTrue(result.done.await(2,TimeUnit.SECONDS))
        assertEquals(1,result.completions)
        assertNull(result.error)
        assertNull(result.value)
    }
    private fun opened(scenario:String):Int = activity.contentResolver.query(uri(scenario),arrayOf("opened"),null,null,null)!!.use {
        assertTrue(it.moveToFirst()); it.getInt(0)
    }
}
