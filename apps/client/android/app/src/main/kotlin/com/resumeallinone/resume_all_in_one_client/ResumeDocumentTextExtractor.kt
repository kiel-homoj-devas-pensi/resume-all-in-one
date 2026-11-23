package com.resumeallinone.resume_all_in_one_client

import android.content.Context
import android.util.Xml
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Writer
import java.util.zip.ZipInputStream

internal class DocumentImportFailure(val code: String) : Exception(code)

/** Runs only in the disposable document-import process; never executes document actions. */
internal object ResumeDocumentTextExtractor {
    const val MAX_FILE_BYTES = 4 * 1024 * 1024
    const val MAX_TEXT_BYTES = 512 * 1024
    const val MAX_EXPANDED_BYTES = 16 * 1024 * 1024
    const val MAX_XML_BYTES = 2 * 1024 * 1024
    const val MAX_PAGES = 50
    private const val WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private const val STRICT_WORD_NS = "http://purl.oclc.org/ooxml/wordprocessingml/main"

    fun extract(context: Context, bytes: ByteArray, format: String): String {
        if (bytes.size > MAX_FILE_BYTES) throw DocumentImportFailure("input_too_large")
        val text = when (format) {
            "docx" -> docx(bytes)
            "pdf" -> pdf(context, bytes)
            else -> throw DocumentImportFailure("unsupported_file_type")
        }
        if (text.isBlank()) throw DocumentImportFailure("no_document_text")
        if (text.toByteArray(Charsets.UTF_8).size > MAX_TEXT_BYTES) {
            throw DocumentImportFailure("document_too_complex")
        }
        return text
    }

    private fun docx(bytes: ByteArray): String {
        if (bytes.size < 4 || bytes[0] != 80.toByte() || bytes[1] != 75.toByte()) {
            throw DocumentImportFailure("invalid_document")
        }
        val directory = zipDirectory(bytes)
        var documentXml: ByteArray? = null
        var hasContentTypes = false
        var expanded = 0
        val names = mutableSetOf<String>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val expected = directory[entry.name] ?: throw DocumentImportFailure("invalid_document")
                if (names.size >= 1000 || !names.add(entry.name) ||
                    entry.name.startsWith('/') || entry.name.contains('\\') ||
                    entry.name.split('/').any { it == ".." }) {
                    throw DocumentImportFailure("invalid_document")
                }
                if (entry.size > MAX_EXPANDED_BYTES) throw DocumentImportFailure("document_too_complex")
                val body = if (entry.name == "word/document.xml") ByteArrayOutputStream() else null
                if (entry.name == "[Content_Types].xml") hasContentTypes = true
                val buffer = ByteArray(8192)
                while (true) {
                    val count = zip.read(buffer)
                    if (count < 0) break
                    if (count > MAX_EXPANDED_BYTES - expanded ||
                        (body != null && count > MAX_XML_BYTES - body.size())) {
                        throw DocumentImportFailure("document_too_complex")
                    }
                    expanded += count
                    body?.write(buffer, 0, count)
                }
                if (body != null) documentXml = body.toByteArray()
                zip.closeEntry() // CRC is verified by ZipInputStream before accepting any text.
                if (entry.size != expected.first || entry.crc != expected.second) {
                    throw DocumentImportFailure("invalid_document")
                }
            }
        }
        if (names != directory.keys) throw DocumentImportFailure("invalid_document")
        val xml = documentXml ?: throw DocumentImportFailure("invalid_document")
        if (!hasContentTypes) throw DocumentImportFailure("invalid_document")
        val parser = Xml.newPullParser().apply {
            setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
            setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
            setInput(ByteArrayInputStream(xml), null)
        }
        val output = BoundedTextWriter()
        var event = parser.eventType
        var inText = false
        var hasDocument = false
        var bodyDepth = -1
        var excludedDepth = -1
        var nodes = 0
        while (event != XmlPullParser.END_DOCUMENT) {
            if (++nodes > 100000 || parser.depth > 64) throw DocumentImportFailure("document_too_complex")
            if (event == XmlPullParser.DOCDECL ||
                (event == XmlPullParser.ENTITY_REF && parser.text == null)) {
                throw DocumentImportFailure("invalid_document")
            }
            val word = parser.namespace == WORD_NS || parser.namespace == STRICT_WORD_NS
            if (event == XmlPullParser.START_TAG) {
                if (parser.depth == 1) {
                    if (!word || parser.name != "document") throw DocumentImportFailure("invalid_document")
                    hasDocument = true
                }
                if (word && parser.name == "body") bodyDepth = parser.depth
                if (bodyDepth >= 0 && word && parser.name in setOf("del", "moveFrom")) excludedDepth = parser.depth
                if (bodyDepth >= 0 && excludedDepth < 0 && word) {
                    when (parser.name) {
                        "t" -> inText = true
                        "tab" -> output.write("\t")
                        "br", "cr" -> output.write("\n")
                        // Embedded documents cannot be faithfully extracted without another parser.
                        "altChunk" -> throw DocumentImportFailure("unsupported_document_content")
                    }
                }
            } else if (event == XmlPullParser.END_TAG) {
                if (word && parser.name == "t") inText = false
                if (bodyDepth >= 0 && excludedDepth < 0 && word && parser.name == "p") output.write("\n")
                if (parser.depth == excludedDepth) excludedDepth = -1
                if (parser.depth == bodyDepth) bodyDepth = -1
            } else if ((event == XmlPullParser.TEXT || event == XmlPullParser.CDSECT || event == XmlPullParser.ENTITY_REF) && inText && excludedDepth < 0) {
                output.write(parser.text)
            }
            event = parser.nextToken()
        }
        if (!hasDocument) throw DocumentImportFailure("invalid_document")
        return output.toString()
    }

    /** ZipInputStream alone accepts a truncated file with no central directory. Reject it
     * before extraction, and bound declared sizes as well as actual expanded stream bytes. */
    private fun zipDirectory(bytes: ByteArray): Map<String, Pair<Long, Long>> {
        fun u16(offset: Int): Int {
            if (offset < 0 || offset + 2 > bytes.size) throw DocumentImportFailure("invalid_document")
            return (bytes[offset].toInt() and 255) or ((bytes[offset + 1].toInt() and 255) shl 8)
        }
        fun u32(offset: Int): Long = u16(offset).toLong() or (u16(offset + 2).toLong() shl 16)
        var end = bytes.size - 22
        val minimum = maxOf(0, end - 65535)
        while (end >= minimum && (u32(end) != 0x06054b50L || end + 22 + u16(end + 20) != bytes.size)) end--
        if (end < minimum || u16(end + 4) != 0 || u16(end + 6) != 0) throw DocumentImportFailure("invalid_document")
        val count = u16(end + 10)
        val size = u32(end + 12)
        val start = u32(end + 16)
        if (count !in 1..1000 || u16(end + 8) != count || start + size != end.toLong()) {
            throw DocumentImportFailure("invalid_document")
        }
        val entries = linkedMapOf<String, Pair<Long, Long>>()
        var cursor = start.toInt()
        var expanded = 0L
        repeat(count) {
            if (cursor < 0 || cursor + 46 > end || u32(cursor) != 0x02014b50L) throw DocumentImportFailure("invalid_document")
            val flags = u16(cursor + 8)
            val compression = u16(cursor + 10)
            val length = u32(cursor + 24)
            val nameLength = u16(cursor + 28)
            val recordLength = 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
            val local = u32(cursor + 42)
            if (flags and 1 != 0 || compression !in setOf(0, 8) || u16(cursor + 34) != 0 ||
                local >= start || u32(local.toInt()) != 0x04034b50L || cursor + recordLength > end) {
                throw DocumentImportFailure("invalid_document")
            }
            expanded += length
            if (expanded > MAX_EXPANDED_BYTES) throw DocumentImportFailure("document_too_complex")
            val name = String(bytes, cursor + 46, nameLength, Charsets.UTF_8)
            if (entries.put(name, length to u32(cursor + 16)) != null) throw DocumentImportFailure("invalid_document")
            cursor += recordLength
        }
        if (cursor != end) throw DocumentImportFailure("invalid_document")
        return entries
    }

    private fun pdf(context: Context, bytes: ByteArray): String {
        if (bytes.size < 5 || String(bytes, 0, 5, Charsets.US_ASCII) != "%PDF-") {
            throw DocumentImportFailure("invalid_document")
        }
        PDFBoxResourceLoader.init(context.applicationContext)
        try {
            // This caps stream scratch storage, not the complete parser heap. Process isolation
            // and a parent-enforced timeout protect the editor from parser crashes or runaway work.
            PDDocument.load(ByteArrayInputStream(bytes), MemoryUsageSetting.setupMainMemoryOnly(MAX_EXPANDED_BYTES.toLong())).use { doc ->
                if (doc.isEncrypted || !doc.currentAccessPermission.canExtractContent()) {
                    throw DocumentImportFailure("encrypted_document")
                }
                if (doc.numberOfPages > MAX_PAGES) throw DocumentImportFailure("document_too_complex")
                val output = BoundedTextWriter()
                val stripper = PDFTextStripper().apply { sortByPosition = true }
                stripper.writeText(doc, output)
                return output.toString()
            }
        } catch (_: InvalidPasswordException) {
            throw DocumentImportFailure("encrypted_document")
        }
    }

    private class BoundedTextWriter : Writer() {
        private val text = StringBuilder()
        override fun write(chars: CharArray, offset: Int, length: Int) {
            if (length > MAX_TEXT_BYTES - text.length) throw DocumentImportFailure("document_too_complex")
            text.append(chars, offset, length)
        }
        override fun flush() = Unit
        override fun close() = Unit
        override fun toString() = text.toString()
    }
}
