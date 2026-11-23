package com.resumeallinone.resume_all_in_one_client;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.os.Bundle;
import java.io.File;
import java.io.FileNotFoundException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** 只进入测试 APK，以真实 ContentResolver 验证合成文件的写入与权限失败。 */
public class DeliveryTestProvider extends ContentProvider {
    private volatile CountDownLatch deleted = new CountDownLatch(1);
    private File file() { return new File(getContext().getCacheDir(), "synthetic-chosen-028.pdf"); }
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "application/pdf"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) {
        return ("output".equals(uri.getLastPathSegment()) || "undeletable".equals(uri.getLastPathSegment())) && file().delete() ? 1 : 0;
    }
    @Override public Bundle call(String method, String arg, Bundle extras) {
        if ("android:deleteDocument".equals(method)) {
            Uri uri = extras.getParcelable("uri");
            if (uri == null || !"output".equals(uri.getLastPathSegment())) {
                throw new SecurityException("Synthetic deletion denied");
            }
            if (file().exists() && !file().delete()) {
                throw new IllegalStateException("Synthetic deletion failed");
            }
            deleted.countDown();
            return Bundle.EMPTY;
        }
        if ("awaitDeleted".equals(method)) {
            Bundle result = new Bundle();
            try {
                result.putBoolean("deleted", deleted.await(5, TimeUnit.SECONDS));
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                result.putBoolean("deleted", false);
            }
            return result;
        }
        return super.call(method, arg, extras);
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if ("denied".equals(uri.getLastPathSegment())) throw new SecurityException("Synthetic permission denied");
        if (!"output".equals(uri.getLastPathSegment()) && !"undeletable".equals(uri.getLastPathSegment())) throw new FileNotFoundException();
        if (mode.contains("w")) deleted = new CountDownLatch(1);
        return ParcelFileDescriptor.open(file(), ParcelFileDescriptor.parseMode(mode));
    }
}
