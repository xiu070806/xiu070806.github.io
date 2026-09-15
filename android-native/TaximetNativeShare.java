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
import java.io.File;
import java.io.FileOutputStream;

/**
 * Direct WebView -> Android share bridge.
 * This deliberately does not depend on window.Capacitor being present in the page.
 * It is only exposed to the bundled TAXIMET PRO WebView.
 */
public final class TaximetNativeShare {
    private final Activity activity;
    public TaximetNativeShare(Activity activity) { this.activity = activity; }

    @JavascriptInterface
    public void shareBase64(final String base64, final String fileName, final String mime,
                            final String title, final String text) {
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
                send.putExtra(Intent.EXTRA_TEXT, text == null ? "Hóa đơn TAXIMET PRO" : text);
                send.putExtra(Intent.EXTRA_TITLE, title == null ? "TAXIMET PRO" : title);
                send.setClipData(ClipData.newRawUri("TAXIMET PRO", uri));
                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                Intent chooser = Intent.createChooser(send, "Chia sẻ hóa đơn TAXIMET PRO");
                chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                activity.startActivity(chooser);
            } catch (Exception e) {
                // Surface a deterministic error in the WebView instead of silently failing.
                String msg = e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage());
                final String js = "window.dispatchEvent(new CustomEvent('taximetNativeShareError',{detail:" +
                        org.json.JSONObject.quote(msg) + "}));";
                try { ((WebView)activity.findViewById(com.getcapacitor.R.id.webview)).post(() ->
                        ((WebView)activity.findViewById(com.getcapacitor.R.id.webview)).evaluateJavascript(js, null)); } catch (Exception ignored) {}
            }
        });
    }
}
