package com.resumeallinone.resume_all_in_one_client;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.net.Uri;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** 独立测试 APK/UID，无联网权限；只读用户选定的合成文件并记录字节校验结果。 */
public class DeliveryTestViewer extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        TextView status = new TextView(this);
        status.setTextSize(20);
        status.setPadding(24, 24, 24, 24);
        column.addView(status);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        setContentView(scroll);
        try {
            Uri uri = getIntent().getParcelableExtra(Intent.EXTRA_STREAM);
            if (uri == null || !"content".equals(uri.getScheme())) throw new IllegalArgumentException();
            byte[] bytes;
            try (InputStream input = getContentResolver().openInputStream(uri)) {
                bytes = input.readNBytes(20971521);
            }
            if (bytes.length > 20971520) throw new IllegalArgumentException();
            StringBuilder hash = new StringBuilder();
            for (byte value : MessageDigest.getInstance("SHA-256").digest(bytes)) {
                hash.append(String.format("%02x", value));
            }
            JSONObject report = new JSONObject().put("mimeType", getIntent().getType())
                .put("bytes", bytes.length).put("sha256", hash.toString()).put("contentUri", true);
            if ("application/pdf".equals(getIntent().getType())) {
                try (PdfRenderer renderer = new PdfRenderer(getContentResolver().openFileDescriptor(uri, "r"))) {
                    report.put("pages", renderer.getPageCount());
                    for (int index = 0; index < renderer.getPageCount(); index++) {
                        try (PdfRenderer.Page page = renderer.openPage(index)) {
                            Bitmap bitmap = Bitmap.createBitmap(900, 1273, Bitmap.Config.ARGB_8888);
                            bitmap.eraseColor(Color.WHITE);
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                            try (FileOutputStream output = new FileOutputStream(new File(getFilesDir(), "received-page-" + (index + 1) + ".png"))) {
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output);
                            }
                            if (index == 0) {
                                ImageView image = new ImageView(this);
                                image.setImageBitmap(bitmap);
                                image.setAdjustViewBounds(true);
                                column.addView(image);
                            } else bitmap.recycle();
                        }
                    }
                }
            }
            try (FileOutputStream output = new FileOutputStream(new File(getFilesDir(), "last_received.json"))) {
                output.write(report.toString().getBytes(StandardCharsets.UTF_8));
            }
            status.setText("本机合成文件读取成功\n" + bytes.length + " 字节\n" +
                (report.has("pages") ? report.getInt("pages") + " 页 PDF" : "DOCX"));
        } catch (Exception failure) {
            status.setText("本机合成文件读取失败");
        }
    }
}
