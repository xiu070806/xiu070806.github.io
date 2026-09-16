package com.xiu070806.taximetpro;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import android.util.Base64;
import androidx.core.content.FileProvider;
import androidx.annotation.Keep;
import java.io.File;
import java.io.FileOutputStream;

/**
 * Direct WebView -> Android share bridge.
 * This deliberately does not depend on window.Capacitor being present in the page.
 * It is only exposed to the bundled CabCalc WebView.
 */
@Keep
public final class TaximetNativeShare {
    private final Activity activity;
    private final WebView webView;
    public TaximetNativeShare(Activity activity, WebView webView) { this.activity = activity; this.webView = webView; }

    @JavascriptInterface
    public String shareBase64(final String base64, final String fileName, final String mime,
                            final String title, final String text) {
        try {
            if (base64 == null || base64.isEmpty()) throw new IllegalArgumentException("Thiếu dữ liệu tệp");
            String clean = base64;
            int comma = clean.indexOf(',');
            if (comma >= 0) clean = clean.substring(comma + 1);
            byte[] bytes = Base64.decode(clean, Base64.DEFAULT);
            File dir = new File(activity.getCacheDir(), "taximet-share");
            if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException("Không tạo được thư mục chia sẻ");
            String safe = (fileName == null ? "taximet-invoice" : fileName).replaceAll("[^a-zA-Z0-9._-]", "_");
            File file = new File(dir, safe);
            try (FileOutputStream out = new FileOutputStream(file, false)) { out.write(bytes); out.flush(); }
            Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".fileprovider", file);
            Intent send = new Intent(Intent.ACTION_SEND);
            send.setType(mime == null || mime.isEmpty() ? "application/octet-stream" : mime);
            send.putExtra(Intent.EXTRA_STREAM, uri);
            send.putExtra(Intent.EXTRA_TEXT, text == null ? "Hóa đơn CabCalc" : text);
            send.putExtra(Intent.EXTRA_TITLE, title == null ? "CabCalc" : title);
            send.setClipData(ClipData.newRawUri("CabCalc", uri));
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            Intent chooser = Intent.createChooser(send, "Chia sẻ hóa đơn CabCalc");
            chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            activity.startActivity(chooser);
            return "SHARED";
        } catch (Exception e) {
            return "ERROR:" + e.getClass().getSimpleName() + ":" + String.valueOf(e.getMessage());
        }
        /*
        activity.runOnUiThread(() -> {
            try {
                if (base64 == null || base64.isEmpty()) throw new IllegalArgumentException("Thiếu dữ liệu tệp");
                String clean = base64;
                int comma = clean.indexOf(',');
                if (comma >= 0) clean = clean.substring(comma + 1);
                byte[] bytes = Base64.decode(clean, Base64.DEFAULT);
                File dir = new File(activity.getCacheDir(), "taximet-share");
                if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException("Không tạo được thư mục chia sẻ");
                String safe = (fileName == null ? "taximet-invoice" : fileName).replaceAll("[^a-zA-Z0-9._-]", "_");
                File file = new File(dir, safe);
                try (FileOutputStream out = new FileOutputStream(file, false)) { out.write(bytes); out.flush(); }
                Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".fileprovider", file);
                Intent send = new Intent(Intent.ACTION_SEND);
                send.setType(mime == null || mime.isEmpty() ? "application/octet-stream" : mime);
                send.putExtra(Intent.EXTRA_STREAM, uri);
                send.putExtra(Intent.EXTRA_TEXT, text == null ? "Hóa đơn CabCalc" : text);
                send.putExtra(Intent.EXTRA_TITLE, title == null ? "CabCalc" : title);
                send.setClipData(ClipData.newRawUri("CabCalc", uri));
                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                Intent chooser = Intent.createChooser(send, "Chia sẻ hóa đơn CabCalc");
                chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                activity.startActivity(chooser);
            } catch (Exception e) {
                // Surface a deterministic error in the WebView instead of silently failing.
                String msg = e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage());
                final String js = "window.dispatchEvent(new CustomEvent('taximetNativeShareError',{detail:" +
                        org.json.JSONObject.quote(msg) + "}));";
                try { if (webView != null) webView.post(() -> webView.evaluateJavascript(js, null)); } catch (Exception ignored) {}
            }
        });
        */
    }
}
