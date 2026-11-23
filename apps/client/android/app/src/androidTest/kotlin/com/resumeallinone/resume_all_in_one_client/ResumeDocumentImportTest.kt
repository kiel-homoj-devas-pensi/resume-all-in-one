package com.resumeallinone.resume_all_in_one_client

import android.test.ActivityInstrumentationTestCase2
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@Suppress("DEPRECATION")
class ResumeDocumentImportTest : ActivityInstrumentationTestCase2<MainActivity>(MainActivity::class.java) {
    private fun docx(xml: String, extra: Pair<String, ByteArray>? = null): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            for ((name, content) in listOf(
                "[Content_Types].xml" to "<Types/>".toByteArray(),
                "word/document.xml" to xml.toByteArray(Charsets.UTF_8),
            ) + listOfNotNull(extra)) {
                zip.putNextEntry(ZipEntry(name)); zip.write(content); zip.closeEntry()
            }
        }
        return output.toByteArray()
    }

    private fun xml(body: String) = """<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$body</w:body></w:document>"""

    private fun extract(bytes: ByteArray, format: String): String =
        IsolatedDocumentImport.extract(activity.applicationContext, bytes, format) { true }

    private fun failure(code: String, block: () -> Unit) {
        try { block(); fail("Expected $code") } catch (error: DocumentImportFailure) { assertEquals(code, error.code) }
    }

    fun testChineseDocxParagraphTableEntitiesAndDeletedText() {
        val content = xml("""<w:p><w:r><w:t>姓名：合成用户 &amp; 示例</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>项目表格</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:del><w:r><w:delText>不导入删除内容</w:delText></w:r></w:del><w:p><w:r><w:t>保留原文</w:t></w:r></w:p>""")
        val result = extract(docx(content), "docx")
        assertTrue(result.contains("姓名：合成用户 & 示例"))
        assertTrue(result.contains("项目表格"))
        assertTrue(result.contains("保留原文"))
        assertFalse(result.contains("不导入删除内容"))
    }

    fun testZipExpansionAndDoctypeRejectWithoutPartialText() {
        failure("document_too_complex") {
            extract(docx(xml("<w:p><w:r><w:t>before</w:t></w:r></w:p>"),
                "word/media/large.bin" to ByteArray(ResumeDocumentTextExtractor.MAX_EXPANDED_BYTES + 1)), "docx")
        }
        failure("invalid_document") {
            extract(docx("<!DOCTYPE document [<!ENTITY x SYSTEM 'file:///data/private'>]>" + xml("<w:p><w:r><w:t>&x;</w:t></w:r></w:p>")), "docx")
        }
    }

    fun testTruncatedZipAndDuplicateDirectoryCannotProducePartialSuccess() {
        val original = docx(xml("<w:p><w:r><w:t>must not import partial ZIP</w:t></w:r></w:p>"))
        failure("invalid_document") { extract(original.copyOf(original.size - 22), "docx") }
        val corrupt = original.clone()
        // EOCD central-directory count disagrees with the entries on disk.
        corrupt[corrupt.size - 12] = 3
        failure("invalid_document") { extract(corrupt, "docx") }
    }

    private fun pdf(pages: Int = 1, text: Boolean = true, encrypted: Boolean = false): ByteArray {
        PDFBoxResourceLoader.init(activity.applicationContext)
        return PDDocument().use { doc ->
            repeat(pages) { index ->
                val page = PDPage(); doc.addPage(page)
                if (text) PDPageContentStream(doc, page).use {
                    it.beginText(); it.setFont(PDType1Font.HELVETICA, 12f)
                    it.newLineAtOffset(40f, 700f); it.showText("SYNTHETIC PAGE ${index + 1}"); it.endText()
                }
            }
            if (encrypted) doc.protect(StandardProtectionPolicy("owner", "reader", AccessPermission()))
            ByteArrayOutputStream().also { doc.save(it) }.toByteArray()
        }
    }

    fun testMultipagePdfExtractsRealTextInIsolatedService() {
        val text = extract(pdf(pages = 2), "pdf")
        assertTrue(text.contains("SYNTHETIC PAGE 1"))
        assertTrue(text.contains("SYNTHETIC PAGE 2"))
    }

    fun testPdfEncryptedEmptyDamagedAndTooManyPagesFail() {
        failure("encrypted_document") { extract(pdf(encrypted = true), "pdf") }
        failure("no_document_text") { extract(pdf(text = false), "pdf") }
        failure("invalid_document") { extract("%PDF-not-a-document".toByteArray(), "pdf") }
        failure("document_too_complex") { extract(pdf(pages = 51), "pdf") }
    }

    fun testCancellationDoesNotPublishTextAndNextRequestStillWorks() {
        failure("document_cancelled") {
            IsolatedDocumentImport.extract(activity.applicationContext, docx(xml("<w:p><w:r><w:t>cancelled</w:t></w:r></w:p>")), "docx") { false }
        }
        assertTrue(extract(docx(xml("<w:p><w:r><w:t>next request</w:t></w:r></w:p>")), "docx").contains("next request"))
    }

    fun testTimeoutCannotPublishLateResultAndImmediateRetryWorks() {
        failure("document_timeout") {
            IsolatedDocumentImport.extract(activity.applicationContext,
                docx(xml("<w:p><w:r><w:t>late text</w:t></w:r></w:p>")),
                "docx", timeoutMillis = 1) { true }
        }
        assertTrue(extract(docx(xml("<w:p><w:r><w:t>fresh after timeout</w:t></w:r></w:p>")), "docx").contains("fresh after timeout"))
    }

    fun testUnbindingTerminatesBlockedParserProcessWithoutClosingActivity() {
        val context = activity.applicationContext
        val connected = CountDownLatch(1)
        val died = CountDownLatch(1)
        val pipe = ParcelFileDescriptor.createPipe()
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                service.linkToDeath({ died.countDown() }, 0)
                Messenger(service).send(Message.obtain().apply {
                    what = 1
                    data = Bundle().apply {
                        putParcelable("input", pipe[0]); putString("format", "pdf")
                    }
                })
                connected.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName) = Unit
        }
        var bound = context.bindService(Intent(context, ResumeDocumentImportService::class.java), connection, Context.BIND_AUTO_CREATE)
        assertTrue(bound)
        try {
            assertTrue(connected.await(5, TimeUnit.SECONDS))
            // The isolated worker is blocked reading a pipe whose writer has not sent EOF.
            context.unbindService(connection)
            bound = false
            assertTrue("Isolated parser must die after unbind", died.await(5, TimeUnit.SECONDS))
            assertFalse(activity.isDestroyed)
            assertFalse(activity.isFinishing)
        } finally {
            if (bound) context.unbindService(connection)
            pipe.forEach { it.close() }
        }
    }
}
