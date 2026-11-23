package com.resumeallinone.resume_all_in_one_client;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

/** Synthetic test APK provider; never part of the app APK. */
public class PhotoTestProvider extends ContentProvider {
    private volatile int opened;
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "image/png"; }
    @Override public Uri insert(Uri uri, ContentValues value) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues value, String s, String[] a) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String s, String[] a) { throw new UnsupportedOperationException(); }
    @Override public Cursor query(Uri uri, String[] columns, String s, String[] a, String sort) {
        return query(uri, columns, s, a, sort, null);
    }
    @Override public Cursor query(Uri uri, String[] columns, String s, String[] a, String sort, CancellationSignal signal) {
        String scenario = uri.getLastPathSegment();
        if ("blocked".equals(scenario)) {
            while (signal != null && !signal.isCanceled()) {
                try { Thread.sleep(10); } catch (InterruptedException e) { break; }
            }
            if (signal != null) signal.throwIfCanceled();
        }
        String[] keys = columns == null ? new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE,"opened"} : columns;
        MatrixCursor result = new MatrixCursor(keys);
        Object[] row = new Object[keys.length];
        for(int i=0;i<keys.length;i++) {
            if(OpenableColumns.DISPLAY_NAME.equals(keys[i])) row[i]="synthetic.png";
            else if(OpenableColumns.SIZE.equals(keys[i])) row[i]="known-large".equals(scenario) ? 10L*1024*1024+1 : null;
            else if("opened".equals(keys[i])) row[i]=opened;
        }
        result.addRow(row);
        return result;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws java.io.FileNotFoundException {
        opened++;
        File file = new File(getContext().getCacheDir(),"photo-provider-"+uri.getLastPathSegment()+".png");
        try(FileOutputStream output = new FileOutputStream(file)) {
            if("growing".equals(uri.getLastPathSegment())) {
                byte[] chunk=new byte[8192];
                for(int i=0;i<1280;i++) output.write(chunk);
                output.write(1);
            } else {
                Bitmap bitmap=Bitmap.createBitmap(100,200,Bitmap.Config.ARGB_8888);
                try { bitmap.eraseColor(Color.BLUE); bitmap.compress(Bitmap.CompressFormat.PNG,100,output); }
                finally { bitmap.recycle(); }
            }
        } catch(IOException error) { throw new java.io.FileNotFoundException("Synthetic photo unavailable"); }
        return ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY);
    }
}
