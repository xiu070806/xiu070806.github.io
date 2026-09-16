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
            String safe = (fileName == null ? "cabcalc-invoice" : fileName).replaceAll("[^a-zA-Z0-9._-]", "_");
            File file = new File(dir, safe);
            try (FileOutputStream out = new FileOutputStream(file, false)) { out.write(bytes); out.flush(); }
            final Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".fileprovider", file);
            final String finalMime = (mime == null || mime.isEmpty()) ? "application/octet-stream" : mime;
            final String finalText = text == null ? "Hóa đơn CabCalc" : text;
            final String finalTitle = title == null ? "CabCalc" : title;
            activity.runOnUiThread(() -> {
                try {
                    Intent send = new Intent(Intent.ACTION_SEND);
                    send.setType(finalMime);
                    send.putExtra(Intent.EXTRA_STREAM, uri);
                    send.putExtra(Intent.EXTRA_TEXT, finalText);
                    send.putExtra(Intent.EXTRA_TITLE, finalTitle);
                    send.setClipData(ClipData.newRawUri("CabCalc", uri));
                    send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    Intent chooser = Intent.createChooser(send, "Chia sẻ hóa đơn CabCalc");
                    chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    activity.startActivity(chooser);
                } catch (Exception e) {
                    android.util.Log.e("CabCalcShare", "Unable to open Android share sheet", e);
                    if (webView != null) {
                        String msg = e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage());
                        final String js = "window.dispatchEvent(new CustomEvent('taximetNativeShareError',{detail:" +
                                org.json.JSONObject.quote(msg) + "}));";
                        webView.post(() -> webView.evaluateJavascript(js, null));
                    }
                }
            });
            return "SHARE_STARTED";
        } catch (Exception e) {
            return "ERROR:" + e.getClass().getSimpleName() + ":" + String.valueOf(e.getMessage());
        }
    }
}
