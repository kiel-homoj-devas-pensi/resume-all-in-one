package com.resumeallinone.resume_all_in_one_client

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.ExifInterface
import android.test.InstrumentationTestCase
import java.io.ByteArrayOutputStream
import java.io.File

@Suppress("DEPRECATION")
class ResumePhotoImportTest : InstrumentationTestCase() {
    private fun image(width: Int, height: Int, png: Boolean): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.BLUE)
            val paint = Paint().apply { color = Color.RED }
            canvas.drawRect(0f, 0f, width.toFloat(), height / 4f, paint)
            val output = ByteArrayOutputStream()
            assertTrue(bitmap.compress(if(png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 95, output))
            return output.toByteArray()
        } finally { bitmap.recycle() }
    }

    private fun normalize(bytes: ByteArray, name: String): Bitmap {
        val normalized = ResumePhotoNormalizer.normalize(bytes, name)
        assertTrue(normalized.size <= ResumePhotoNormalizer.MAX_OUTPUT_BYTES)
        val bitmap = BitmapFactory.decodeByteArray(normalized, 0, normalized.size)
        assertEquals(500, bitmap.width)
        assertEquals(700, bitmap.height)
        return bitmap
    }

    fun testLandscapeFullImageWithPaddingNotCropOrStretch() {
        val bitmap = normalize(image(400,200,true), "完整照片.PNG")
        try {
            assertTrue(Color.red(bitmap.getPixel(250,100)) > 245) // white padding
            assertTrue(Color.green(bitmap.getPixel(250,100)) > 245)
            assertTrue(Color.red(bitmap.getPixel(250,240)) > 230) // top content survives
            assertTrue(Color.blue(bitmap.getPixel(250,450)) > 230) // bottom content survives
            assertTrue(Color.green(bitmap.getPixel(250,600)) > 245)
        } finally { bitmap.recycle() }
    }

    fun testPortraitAndSmallJpgBothKeepAllContent() {
        for ((width,height) in listOf(100 to 400, 50 to 70)) {
            val bitmap = normalize(image(width,height,false), "合成.jpg")
            try {
                assertTrue(Color.red(bitmap.getPixel(250,40)) > 230)
                assertTrue(Color.blue(bitmap.getPixel(250,650)) > 230)
                if(width==100) assertTrue(Color.green(bitmap.getPixel(30,350)) > 245)
            } finally { bitmap.recycle() }
        }
    }

    fun testJpgExifRotationIsAppliedAndMetadataNotCopied() {
        val directory = instrumentation.targetContext.cacheDir.apply { mkdirs() }
        val file = File.createTempFile("photo-exif-", ".jpg", directory)
        try {
            file.writeBytes(image(400,200,false))
            val exif = ExifInterface(file.path)
            exif.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE, "30/1,0/1,0/1")
            exif.saveAttributes()
            val normalized = ResumePhotoNormalizer.normalize(file.readBytes(), "rotated.jpg")
            val bitmap = BitmapFactory.decodeByteArray(normalized,0,normalized.size)
            try {
                assertTrue(Color.green(bitmap.getPixel(30,350)) > 245) // rotated portrait side padding
                assertTrue(Color.red(bitmap.getPixel(400,350)) > 230)
                assertTrue(Color.blue(bitmap.getPixel(100,350)) > 230)
            } finally { bitmap.recycle() }
            val normalizedExif = ExifInterface(java.io.ByteArrayInputStream(normalized))
            assertNull(normalizedExif.getAttribute(ExifInterface.TAG_GPS_LATITUDE))
            val cleanOrientation = normalizedExif.getAttributeInt(ExifInterface.TAG_ORIENTATION,ExifInterface.ORIENTATION_NORMAL)
            // Platform ExifInterface synthesizes UNDEFINED for an image without an EXIF block.
            assertTrue(cleanOrientation == ExifInterface.ORIENTATION_NORMAL || cleanOrientation == ExifInterface.ORIENTATION_UNDEFINED)
        } finally { assertTrue(file.delete()) }
    }

    fun testOversizeMismatchAndDamagedInputAreRejected() {
        for ((bytes,name,code) in listOf(
            Triple(ByteArray(ResumePhotoNormalizer.MAX_INPUT_BYTES+1),"large.jpg","photo_too_large"),
            Triple(image(20,30,true),"wrong.jpg","photo_invalid"),
            Triple(byteArrayOf(1,2,3),"broken.png","photo_invalid"),
            Triple(image(20,30,true),"image.gif","photo_unsupported"))) {
            try { ResumePhotoNormalizer.normalize(bytes,name); fail("Must reject input") }
            catch (failure: PhotoImportFailure) { assertEquals(code,failure.code) }
        }
    }
}
