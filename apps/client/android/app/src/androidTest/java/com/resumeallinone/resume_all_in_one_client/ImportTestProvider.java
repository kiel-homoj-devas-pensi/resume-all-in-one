package com.resumeallinone.resume_all_in_one_client;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.os.Bundle;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** 仅测试 APK：合成元数据与真实流用于验证读取前和读取期间的限额。 */
public class ImportTestProvider extends ContentProvider {
    private static final int LIMIT = 512 * 1024;
    private static final int ARCHIVE_LIMIT = 8 * 1024 * 1024;
    private final Map<String, Integer> opened = new HashMap<>();
    private volatile CountDownLatch blockedOpened = new CountDownLatch(1);
    private volatile CountDownLatch releaseBlocked = new CountDownLatch(1);
    private volatile CountDownLatch blockedFinished = new CountDownLatch(1);

    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return uri.getLastPathSegment().startsWith("archive-") ? "application/json" : "text/plain"; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }

    @Override public synchronized Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        String scenario = uri.getLastPathSegment();
        boolean archive = scenario.startsWith("archive-");
        String kind = archive ? scenario.substring("archive-".length()) : scenario;
        int limit = archive ? ARCHIVE_LIMIT : LIMIT;
        String[] columns = projection == null
            ? new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE, "opened"}
            : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) {
                row[i] = "unsupported".equals(kind) ? "synthetic.exe" : archive ? "synthetic.JSON" : "synthetic.MD";
            } else if (OpenableColumns.SIZE.equals(columns[i])) {
                if ("known-large".equals(kind)) row[i] = (long) limit + 1;
                else if ("growing".equals(kind)) row[i] = 1L;
                else if ("unknown".equals(kind)) row[i] = null;
                else row[i] = (long) limit;
            } else if ("opened".equals(columns[i])) {
                row[i] = opened.containsKey(scenario) ? opened.get(scenario) : 0;
            }
        }
        cursor.addRow(row);
        return cursor;
    }

    @Override public Bundle call(String method, String arg, Bundle extras) {
        if ("resetBlocked".equals(method)) {
            blockedOpened = new CountDownLatch(1);
            releaseBlocked = new CountDownLatch(1);
            blockedFinished = new CountDownLatch(1);
            return Bundle.EMPTY;
        }
        if ("releaseBlocked".equals(method)) {
            releaseBlocked.countDown();
            return Bundle.EMPTY;
        }
        if ("awaitBlockedOpened".equals(method) || "awaitBlockedFinished".equals(method)) {
            Bundle result = new Bundle();
            try {
                CountDownLatch latch = "awaitBlockedOpened".equals(method) ? blockedOpened : blockedFinished;
                result.putBoolean("ready", latch.await(5, TimeUnit.SECONDS));
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                result.putBoolean("ready", false);
            }
            return result;
        }
        return super.call(method, arg, extras);
    }

    @Override public synchronized ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        String scenario = uri.getLastPathSegment();
        boolean archive = scenario.startsWith("archive-");
        String kind = archive ? scenario.substring("archive-".length()) : scenario;
        int limit = archive ? ARCHIVE_LIMIT : LIMIT;
        opened.put(scenario, opened.containsKey(scenario) ? opened.get(scenario) + 1 : 1);
        if ("denied".equals(kind)) throw new SecurityException("Synthetic denied import");
        if (!"r".equals(mode)) throw new FileNotFoundException("Read only");
        if ("blocked".equals(kind)) {
            try {
                ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
                CountDownLatch openedLatch = blockedOpened;
                CountDownLatch releaseLatch = releaseBlocked;
                CountDownLatch finishedLatch = blockedFinished;
                new Thread(() -> {
                    try (FileOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                        openedLatch.countDown();
                        if (!releaseLatch.await(5, TimeUnit.SECONDS)) throw new IOException("Synthetic blocked read timed out");
                        output.write(new byte[] {65, 65, 65});
                    } catch (IOException error) {
                        // Cancellation closes the read side; the writer still releases its descriptor.
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                    } finally { finishedLatch.countDown(); }
                }).start();
                return pipe[0];
            } catch (IOException error) {
                throw new FileNotFoundException("Synthetic pipe unavailable");
            }
        }
        int length = "growing".equals(kind) || "unknown".equals(kind) ? limit + 1 : limit;
        File file = new File(getContext().getCacheDir(), "synthetic-import-" + scenario + ".md");
        try (FileOutputStream output = new FileOutputStream(file)) {
            byte[] chunk = new byte[8192];
            java.util.Arrays.fill(chunk, (byte) 65);
            for (int remaining = length; remaining > 0; remaining -= Math.min(remaining, chunk.length)) {
                output.write(chunk, 0, Math.min(remaining, chunk.length));
            }
        } catch (IOException error) {
            throw new FileNotFoundException("Synthetic file unavailable");
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
    }
}
