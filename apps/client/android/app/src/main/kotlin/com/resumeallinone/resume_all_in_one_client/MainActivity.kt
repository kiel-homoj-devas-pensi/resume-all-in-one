package com.resumeallinone.resume_all_in_one_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent

class MainActivity : FlutterActivity() {
    private val documentDelivery by lazy { DocumentDelivery(this) }
    private val resumeTextImport by lazy { ResumeTextImport(this) }
    private val localDataArchiveImport by lazy { ResumeTextImport(this, archive = true) }
    private val resumePhotoImport by lazy { ResumePhotoImport(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resume_all_in_one/file_delivery")
            .setMethodCallHandler(documentDelivery::handle)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resume_all_in_one/text_import")
            .setMethodCallHandler(resumeTextImport::handle)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resume_all_in_one/archive_import")
            .setMethodCallHandler(localDataArchiveImport::handle)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resume_all_in_one/photo_import")
            .setMethodCallHandler(resumePhotoImport::handle)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!documentDelivery.onResult(requestCode, resultCode, data) &&
            !resumeTextImport.onResult(requestCode, resultCode, data) &&
            !localDataArchiveImport.onResult(requestCode, resultCode, data) &&
            !resumePhotoImport.onResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onDestroy() {
        resumeTextImport.cancelPending()
        localDataArchiveImport.cancelPending()
        resumePhotoImport.cancelPending()
        documentDelivery.cancelPending()
        super.onDestroy()
    }
}
