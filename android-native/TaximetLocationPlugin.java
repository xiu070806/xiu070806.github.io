package com.xiu070806.taximetpro;

import android.Manifest;
import android.content.*;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.os.Build;
import android.util.Base64;
import androidx.core.content.FileProvider;
import android.net.Uri;
import android.os.Environment;
import java.io.File;
import java.io.FileOutputStream;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.getcapacitor.*;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "TaximetLocation")
public class TaximetLocationPlugin extends Plugin {
    public static final String ACTION_LOCATION = "com.taximet.pro.LOCATION";
    public static final String ACTION_ERROR = "com.taximet.pro.LOCATION_ERROR";
    public static final String ACTION_STATUS = "com.taximet.pro.GPS_STATUS";

    private static final int REQ_LOCATION = 4401;
    private BroadcastReceiver receiver;

    @Override
    public void load() {
        super.load();
        receiver = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent i) {
                String a = i.getAction();
                if (ACTION_LOCATION.equals(a)) notifyListeners("locationUpdate", payload(i));
                else if (ACTION_ERROR.equals(a)) notifyListeners("locationError", payload(i));
                else if (ACTION_STATUS.equals(a)) notifyListeners("gpsStatus", payload(i));
            }
        };
        IntentFilter f = new IntentFilter();
        f.addAction(ACTION_LOCATION);
        f.addAction(ACTION_ERROR);
        f.addAction(ACTION_STATUS);
        ContextCompat.registerReceiver(getContext(), receiver, f, ContextCompat.RECEIVER_NOT_EXPORTED);
    }

    @Override protected void handleOnDestroy() {
        if (receiver != null) {
            try { getContext().unregisterReceiver(receiver); } catch (Exception ignored) {}
            receiver = null;
        }
        super.handleOnDestroy();
    }

    private JSObject payload(Intent i) {
        JSObject o = new JSObject();
        if (i.hasExtra("latitude")) o.put("latitude", i.getDoubleExtra("latitude", 0));
        if (i.hasExtra("longitude")) o.put("longitude", i.getDoubleExtra("longitude", 0));
        if (i.hasExtra("accuracy")) o.put("accuracy", i.getDoubleExtra("accuracy", 999));
        if (i.hasExtra("speedMps")) o.put("speedMps", i.getDoubleExtra("speedMps", -1));
        if (i.hasExtra("heading")) o.put("heading", i.getDoubleExtra("heading", -1));
        if (i.hasExtra("timestamp")) o.put("timestamp", i.getLongExtra("timestamp", 0));
        if (i.hasExtra("code")) o.put("code", i.getIntExtra("code", 2));
        if (i.hasExtra("message")) o.put("message", i.getStringExtra("message"));
        if (i.hasExtra("authorization")) o.put("authorization", i.getStringExtra("authorization"));
        if (i.hasExtra("servicesEnabled")) o.put("servicesEnabled", i.getBooleanExtra("servicesEnabled", false));
        if (i.hasExtra("started")) o.put("started", i.getBooleanExtra("started", false));
        if (i.hasExtra("notificationGranted")) o.put("notificationGranted", i.getBooleanExtra("notificationGranted", false));
        if (i.hasExtra("background")) o.put("background", i.getBooleanExtra("background", false));
        if (i.hasExtra("tripDistanceM")) o.put("tripDistanceM", i.getFloatExtra("tripDistanceM", 0f));
        return o;
    }

    private boolean hasLocationPermission() {
        return ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            || ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean hasNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return true;
        return ContextCompat.checkSelfPermission(getContext(), Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
    }

    @PluginMethod
    public void start(PluginCall call) {
        if (!hasLocationPermission()) {
            ActivityCompat.requestPermissions(
                getActivity(),
                new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION},
                REQ_LOCATION
            );
            call.resolve(new JSObject().put("status", "REQUESTING_PERMISSION"));
            return;
        }

        try {
            Intent i = new Intent(getContext(), TaximetLocationService.class);
            if (Build.VERSION.SDK_INT >= 26) ContextCompat.startForegroundService(getContext(), i);
            else getContext().startService(i);

            call.resolve(new JSObject()
                .put("status", "STARTED")
                .put("notificationGranted", hasNotificationPermission()));
        } catch (Exception e) {
            call.resolve(new JSObject().put("status", "ERROR").put("message", String.valueOf(e.getMessage())));
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        getContext().stopService(new Intent(getContext(), TaximetLocationService.class));
        call.resolve(new JSObject().put("status", "STOPPED"));
    }

    @PluginMethod
    public void getLastLocation(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        JSObject o = new JSObject();
        if (!p.contains("lat") || !p.contains("lon")) {
            call.resolve(o);
            return;
        }
        o.put("latitude", p.getFloat("lat", 0));
        o.put("longitude", p.getFloat("lon", 0));
        o.put("accuracy", p.getFloat("accuracy", 999));
        o.put("speedMps", p.getFloat("speedMps", -1));
        o.put("heading", p.getFloat("heading", -1));
        o.put("timestamp", p.getLong("timestamp", 0));
        call.resolve(o);
    }


    @PluginMethod
    public void setTripActive(PluginCall call) {
        boolean active = call.getBoolean("active", false);
        boolean reset = call.getBoolean("reset", false);
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        SharedPreferences.Editor e = p.edit().putBoolean("tripActive", active);

        if (active && reset) {
            // Explicit reset is used ONLY for a brand-new trip. Clear the
            // native anchor so the first fresh GPS fix becomes the anchor;
            // never measure from a location received before START.
            e.putFloat("tripDistanceM", 0f)
             .remove("tripSmallMoveM").remove("tripSmallMoveStartTs")
             .remove("tripLastLat")
             .remove("tripLastLon")
             .remove("tripLastTs");
        } else if (active) {
            // Resume after PAUSE: keep the accumulated distance but re-anchor
            // at the newest known fix so movement during the pause is excluded.
            if (p.contains("lat") && p.contains("lon")) {
                double lat = p.getFloat("lat", 0), lon = p.getFloat("lon", 0);
                long ts = p.getLong("timestamp", System.currentTimeMillis());
                e.putLong("tripLastLat", Double.doubleToLongBits(lat))
                 .putLong("tripLastLon", Double.doubleToLongBits(lon))
                 .putLong("tripLastTs", ts);
            } else {
                e.remove("tripSmallMoveM").remove("tripSmallMoveStartTs").remove("tripLastLat").remove("tripLastLon").remove("tripLastTs");
            }
        }
        // When active=false, deliberately keep tripDistanceM for the payment
        // screen and history until the next explicit reset=true.
        e.apply();
        call.resolve(new JSObject().put("active", active).put("reset", reset)
            .put("tripDistanceM", p.getFloat("tripDistanceM", 0f)));
    }

    @PluginMethod
    public void getTripStats(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        JSObject o = new JSObject();
        o.put("active", p.getBoolean("tripActive", false));
        o.put("distanceM", p.getFloat("tripDistanceM", 0f));
        if (p.contains("lat") && p.contains("lon")) {
            o.put("latitude", p.getFloat("lat", 0));
            o.put("longitude", p.getFloat("lon", 0));
            o.put("timestamp", p.getLong("timestamp", 0));
        }
        call.resolve(o);
    }

    @PluginMethod
    public void setBackgroundTracking(PluginCall call) {
        boolean enabled=call.getBoolean("enabled",false);
        SharedPreferences p=getContext().getSharedPreferences("taximet_gps",0);
        SharedPreferences.Editor e=p.edit().putBoolean("backgroundTripTracking",enabled);
        if(enabled){
            e.putFloat("backgroundTripDistanceM", 0f);
            if(p.contains("lat") && p.contains("lon")){
                double lat=p.getFloat("lat",0), lon=p.getFloat("lon",0);
                e.putLong("backgroundLastLat",Double.doubleToLongBits(lat));
                e.putLong("backgroundLastLon",Double.doubleToLongBits(lon));
                e.putLong("backgroundLastTs",p.getLong("timestamp",System.currentTimeMillis()));
            }
        }
        e.apply();
        call.resolve(new JSObject().put("enabled",enabled));
    }

    @PluginMethod
    public void resetBackgroundTripStats(PluginCall call) {
        // Legacy API retained for compatibility. Do NOT reset the single native
        // trip accumulator here, otherwise returning to foreground would erase
        // distance accumulated in background.
        call.resolve(new JSObject().put("status", "NO_RESET_NATIVE_TRIP"));
    }

    @PluginMethod
    public void getBackgroundTripStats(PluginCall call) {
        // Legacy API now aliases the single native trip accumulator.
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        JSObject o = new JSObject();
        o.put("distanceM", p.getFloat("tripDistanceM", 0f));
        if (p.contains("lat") && p.contains("lon")) {
            o.put("latitude", p.getFloat("lat", 0));
            o.put("longitude", p.getFloat("lon", 0));
            o.put("timestamp", p.getLong("timestamp", 0));
        }
        call.resolve(o);
    }

    @PluginMethod
    public void setAppForeground(PluginCall call) {
        boolean foreground = call.getBoolean("foreground", true);
        getContext().getSharedPreferences("taximet_gps",0).edit()
            .putBoolean("appForeground", foreground).apply();
        call.resolve(new JSObject().put("foreground", foreground));
    }

    @PluginMethod
    public void shareFile(PluginCall call) {
        try {
            String data = call.getString("data", "");
            String fileName = call.getString("fileName", "taximet-invoice");
            String mime = call.getString("mime", "application/octet-stream");
            if (data == null || data.isEmpty()) {
                call.reject("Thiếu dữ liệu tệp");
                return;
            }
            int comma = data.indexOf(',');
            if (comma >= 0) data = data.substring(comma + 1);
            byte[] bytes = Base64.decode(data, Base64.DEFAULT);
            File dir = new File(getContext().getCacheDir(), "taximet-share");
            if (!dir.exists() && !dir.mkdirs()) {
                call.reject("Không tạo được thư mục chia sẻ");
                return;
            }
            File file = new File(dir, fileName.replaceAll("[^a-zA-Z0-9._-]", "_"));
            try (FileOutputStream out = new FileOutputStream(file, false)) { out.write(bytes); }
            Uri uri = FileProvider.getUriForFile(getContext(), getContext().getPackageName() + ".fileprovider", file);
            Intent send = new Intent(Intent.ACTION_SEND);
            send.setType(mime);
            send.putExtra(Intent.EXTRA_STREAM, uri);
            send.putExtra(Intent.EXTRA_TEXT, call.getString("text", "Hóa đơn CabCalc"));
            send.putExtra(Intent.EXTRA_TITLE, call.getString("title", "CabCalc"));
            send.setClipData(ClipData.newRawUri("CabCalc", uri));
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_DOCUMENT);
            Intent chooser = Intent.createChooser(send, "Chia sẻ hóa đơn CabCalc");
            chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            getActivity().startActivity(chooser);
            call.resolve(new JSObject().put("status", "SHARED").put("uri", uri.toString()));
        } catch (Exception e) {
            call.reject("Không thể chia sẻ tệp: " + e.getMessage(), e);
        }
    }

    @PluginMethod
    public void status(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        LocationManager lm = (LocationManager)getContext().getSystemService(Context.LOCATION_SERVICE);
        boolean enabled = false;
        try {
            enabled = lm != null &&
                (lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                 lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER));
        } catch (Exception ignored) {}

        call.resolve(new JSObject()
            .put("authorization", hasLocationPermission() ? "AUTHORIZED" : "DENIED")
            .put("servicesEnabled", enabled)
            .put("started", p.getBoolean("started", false))
            .put("hasFix", p.contains("lat") && p.contains("lon"))
            .put("accuracy", p.getFloat("accuracy", 999))
            .put("timestamp", p.getLong("timestamp", 0))
            .put("notificationGranted", hasNotificationPermission()));
    }
}
