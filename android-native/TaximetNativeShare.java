          package com.xiu070806.taximetpro;

          import android.app.Activity;
          import android.content.ClipData;
          import android.content.Intent;
          import android.net.Uri;
          import android.webkit.JavascriptInterface;
          import android.webkit.WebView;
          import android.util.Base64;
          import androidx.core.content.FileProvider;
          import androidx.annotation.Keep;
          import java.io.File;
          import java.io.FileOutputStream;

          @Keep
          public final class TaximetNativeShare {
              private final Activity activity;
              private final WebView webView;
              private FileOutputStream pendingOut;
              private File pendingFile;
              private String pendingMime;
              private String pendingTitle;
              private String pendingText;

              public TaximetNativeShare(Activity activity, WebView webView) { this.activity = activity; this.webView = webView; }

              @JavascriptInterface
              public synchronized String beginShareBase64(String fileName, String mime, String title, String text) {
                  try {
                      cancelPending();
                      File dir = new File(activity.getCacheDir(), "taximet-share");
                      if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException("Không tạo được thư mục chia sẻ");
                      String safe = (fileName == null ? "cabcalc-invoice" : fileName).replaceAll("[^a-zA-Z0-9._-]", "_");
                      pendingFile = new File(dir, safe);
                      pendingOut = new FileOutputStream(pendingFile, false);
                      pendingMime = (mime == null || mime.isEmpty()) ? "application/octet-stream" : mime;
                      pendingTitle = title == null ? "CabCalc" : title;
                      pendingText = text == null ? "Hóa đơn CabCalc" : text;
                      return "SHARE_READY";
                  } catch (Exception e) { cancelPending(); return "ERROR:" + e.getClass().getSimpleName() + ":" + String.valueOf(e.getMessage()); }
              }

              @JavascriptInterface
              public synchronized String appendShareBase64(String base64) {
                  try {
                      if (pendingOut == null) throw new IllegalStateException("Chưa khởi tạo tệp chia sẻ");
                      if (base64 == null || base64.isEmpty()) return "CHUNK_OK";
                      pendingOut.write(Base64.decode(base64, Base64.DEFAULT));
                      return "CHUNK_OK";
                  } catch (Exception e) { return "ERROR:" + e.getClass().getSimpleName() + ":" + String.valueOf(e.getMessage()); }
              }

              @JavascriptInterface
              public synchronized String finishShareBase64() {
                  try {
                      if (pendingOut == null || pendingFile == null) throw new IllegalStateException("Tệp chia sẻ chưa hoàn tất");
                      pendingOut.flush(); pendingOut.close(); pendingOut = null;
                      File file = pendingFile;
                      String mime = pendingMime, title = pendingTitle, text = pendingText;
                      pendingFile = null; pendingMime = pendingTitle = pendingText = null;
                      final Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".fileprovider", file);
                      activity.runOnUiThread(() -> openShare(uri, mime, title, text));
                      return "SHARE_STARTED";
                  } catch (Exception e) { cancelPending(); return "ERROR:" + e.getClass().getSimpleName() + ":" + String.valueOf(e.getMessage()); }
              }

              @JavascriptInterface
              public synchronized void cancelShareBase64() { cancelPending(); }

              @JavascriptInterface
              public synchronized String shareBase64(final String base64, final String fileName, final String mime,
                                      final String title, final String text) {
                  try {
                      String r=beginShareBase64(fileName,mime,title,text); if (r.startsWith("ERROR:")) return r;
                      r=appendShareBase64(base64); if (r.startsWith("ERROR:")) { cancelPending(); return r; }
                      return finishShareBase64();
                  } catch(Exception e) { cancelPending(); return "ERROR:"+e.getClass().getSimpleName()+":"+String.valueOf(e.getMessage()); }
              }

              private void openShare(final Uri uri, final String mime, final String title, final String text) {
                  try {
                      Intent send = new Intent(Intent.ACTION_SEND);
                      send.setType(mime);
                      send.putExtra(Intent.EXTRA_STREAM, uri);
                      send.putExtra(Intent.EXTRA_TEXT, text);
                      send.putExtra(Intent.EXTRA_TITLE, title);
                      send.setClipData(ClipData.newRawUri("CabCalc", uri));
                      send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                      Intent chooser = Intent.createChooser(send, "Chia sẻ hóa đơn CabCalc");
                      chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                      activity.startActivity(chooser);
                  } catch (Exception e) {
                      android.util.Log.e("CabCalcShare", "Unable to open Android share sheet", e);
                      if (webView != null) {
                          String msg = e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage());
                          final String js = "window.dispatchEvent(new CustomEvent('taximetNativeShareError',{detail:" + org.json.JSONObject.quote(msg) + "}));";
                          webView.post(() -> webView.evaluateJavascript(js, null));
                      }
                  }
              }

              private synchronized void cancelPending() {
                  try { if (pendingOut != null) pendingOut.close(); } catch (Exception ignored) {}
                  pendingOut = null; pendingFile = null; pendingMime = pendingTitle = pendingText = null;
              }
          }
