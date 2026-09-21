package com.xiu070806.taximetpro;

import android.app.Activity;
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
    private static final int REQ_BACKGROUND_LOCATION = 4404;
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
        if (i.hasExtra("speedMps")) o.put("speedMps", i.getDoubleExtra("speedMps", 0));
        if (i.hasExtra("speedKmh")) o.put("speedKmh", i.getDoubleExtra("speedKmh", 0));
        if (i.hasExtra("rawSpeedMps")) o.put("rawSpeedMps", i.getDoubleExtra("rawSpeedMps", -1));
        if (i.hasExtra("movementConfirmed")) o.put("movementConfirmed", i.getBooleanExtra("movementConfirmed", false));
        if (i.hasExtra("gpsFixFresh")) o.put("gpsFixFresh", i.getBooleanExtra("gpsFixFresh", false));
        if (i.hasExtra("heading")) o.put("heading", i.getDoubleExtra("heading", -1));
        if (i.hasExtra("timestamp")) o.put("timestamp", i.getLongExtra("timestamp", 0));
        if (i.hasExtra("code")) o.put("code", i.getIntExtra("code", 2));
        if (i.hasExtra("message")) o.put("message", i.getStringExtra("message"));
        if (i.hasExtra("authorization")) o.put("authorization", i.getStringExtra("authorization"));
        if (i.hasExtra("servicesEnabled")) o.put("servicesEnabled", i.getBooleanExtra("servicesEnabled", false));
        if (i.hasExtra("started")) o.put("started", i.getBooleanExtra("started", false));
        if (i.hasExtra("notificationGranted")) o.put("notificationGranted", i.getBooleanExtra("notificationGranted", false));
        if (i.hasExtra("background")) o.put("background", i.getBooleanExtra("background", false));
        if (i.hasExtra("tripDistanceM")) o.put("tripDistanceM", i.getDoubleExtra("tripDistanceM", 0d));
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

        if (Build.VERSION.SDK_INT >= 30 &&
            ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_BACKGROUND_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(
                getActivity(),
                new String[]{Manifest.permission.ACCESS_BACKGROUND_LOCATION},
                REQ_BACKGROUND_LOCATION
            );
            // Do not fail GPS startup while the user is choosing the background
            // permission; the foreground service can continue until the dialog resolves.
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
        o.put("speedMps", p.getFloat("speedMps", 0));
        o.put("speedKmh", p.getFloat("speedMps", 0) * 3.6);
        o.put("rawSpeedMps", p.getFloat("rawSpeedMps", -1));
        o.put("movementConfirmed", p.getBoolean("movementConfirmed", false));
        o.put("gpsFixFresh", true);
        o.put("heading", p.getFloat("heading", -1));
        o.put("timestamp", p.getLong("timestamp", 0));
        call.resolve(o);
    }


    private void putTripDistanceM(SharedPreferences.Editor e, double d) {
        double safe = Double.isFinite(d) && d >= 0d ? d : 0d;
        e.putLong("tripDistanceBits", Double.doubleToLongBits(safe)).remove("tripDistanceM");
    }

    private boolean hasFineLocationPermission() {
        return ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private double getTripDistanceM(SharedPreferences p) {
        if (p.contains("tripDistanceBits")) {
            double d=Double.longBitsToDouble(p.getLong("tripDistanceBits", Double.doubleToLongBits(0d)));
            return Double.isFinite(d) && d>=0 ? d : 0d;
        }
        float legacy=p.getFloat("tripDistanceM",0f);
        return Float.isFinite(legacy) && legacy>=0 ? legacy : 0d;
    }

    private void setNativeTripActive(boolean active, boolean reset) {
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        SharedPreferences.Editor e = p.edit().putBoolean("tripActive", active);
        if (active && reset) {
            e.putLong("tripDistanceBits", Double.doubleToLongBits(0d))
             .remove("tripDistanceM")
             .putBoolean("tripNeedsAnchor", true)
             .remove("tripSmallMoveM").remove("tripSmallMoveStartTs")
             .remove("tripLastLat").remove("tripLastLon").remove("tripLastTs")
             .remove("speedLastLat").remove("speedLastLon").remove("speedLastTs")
             .putInt("speedMovingFixes", 0).putFloat("speedDisplayMps", 0f)
             .putFloat("speedMps", 0f).putFloat("rawSpeedMps", -1f)
             .putBoolean("movementConfirmed", false);
        } else {
            // Resume, pause and finish never erase the accumulated distance.
            // They only invalidate the previous GPS segment anchor.
            e.putBoolean("tripNeedsAnchor", true)
             .remove("tripSmallMoveM").remove("tripSmallMoveStartTs")
             .remove("tripLastLat").remove("tripLastLon").remove("tripLastTs")
             .remove("speedLastLat").remove("speedLastLon").remove("speedLastTs")
             .putInt("speedMovingFixes", 0).putFloat("speedDisplayMps", 0f)
             .putFloat("speedMps", 0f).putFloat("rawSpeedMps", -1f)
             .putBoolean("movementConfirmed", false);
        }
        e.apply();
    }

    private void ensureGpsService() {
        Intent i = new Intent(getContext(), TaximetLocationService.class);
        if (Build.VERSION.SDK_INT >= 26) ContextCompat.startForegroundService(getContext(), i);
        else getContext().startService(i);
    }

    @PluginMethod
    public void startTrip(PluginCall call) {
        if (!hasLocationPermission()) {
            call.reject("GPS permission missing");
            return;
        }
        try {
            setNativeTripActive(true, true);
            ensureGpsService();
            call.resolve(new JSObject().put("active", true).put("reset", true)
                .put("tripDistanceM", getTripDistanceM(getContext().getSharedPreferences("taximet_gps", 0))));
        } catch (Exception e) {
            setNativeTripActive(false, false);
            call.reject("Không thể bắt đầu native trip: " + e.getMessage(), e);
        }
    }

    @PluginMethod
    public void pauseTrip(PluginCall call) {
        setNativeTripActive(false, false);
        call.resolve(new JSObject().put("active", false)
            .put("tripDistanceM", getTripDistanceM(getContext().getSharedPreferences("taximet_gps", 0))));
    }

    @PluginMethod
    public void resumeTrip(PluginCall call) {
        if (!hasLocationPermission()) {
            call.reject("GPS permission missing");
            return;
        }
        try {
            setNativeTripActive(true, false);
            ensureGpsService();
            call.resolve(new JSObject().put("active", true).put("reset", false)
                .put("tripDistanceM", getTripDistanceM(getContext().getSharedPreferences("taximet_gps", 0))));
        } catch (Exception e) {
            call.reject("Không thể tiếp tục native trip: " + e.getMessage(), e);
        }
    }

    @PluginMethod
    public void finishTrip(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        setNativeTripActive(false, false);
        call.resolve(new JSObject().put("active", false).put("finished", true)
            .put("distanceM", getTripDistanceM(p)));
    }

    @PluginMethod
    public void clearFinishedTrip(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        p.edit().putBoolean("tripActive", false)
         .putBoolean("tripNeedsAnchor", true)
         .putLong("tripDistanceBits", Double.doubleToLongBits(0d))
         .remove("tripDistanceM")
         .remove("tripLastLat").remove("tripLastLon").remove("tripLastTs")
         .remove("tripSmallMoveM").remove("tripSmallMoveStartTs")
         .apply();
        call.resolve(new JSObject().put("status", "CLEARED").put("distanceM", 0d));
    }

    @PluginMethod
    public void setTripActive(PluginCall call) {
        boolean active = call.getBoolean("active", false);
        boolean reset = call.getBoolean("reset", false);
        setNativeTripActive(active, active && reset);
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        call.resolve(new JSObject().put("active", active).put("reset", reset)
            .put("tripDistanceM", getTripDistanceM(p)));
    }

    @PluginMethod
    public void getTripStats(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences("taximet_gps", 0);
        JSObject o = new JSObject();
        o.put("active", p.getBoolean("tripActive", false));
        double distance=0d;
        if(p.contains("tripDistanceBits")) distance=Double.longBitsToDouble(p.getLong("tripDistanceBits",Double.doubleToLongBits(0d)));
        else distance=Math.max(0d,p.getFloat("tripDistanceM",0f));
        o.put("distanceM", Double.isFinite(distance)&&distance>=0?distance:0d);
        o.put("speedMps", p.getFloat("speedMps", 0));
        o.put("speedKmh", p.getFloat("speedMps", 0) * 3.6);
        o.put("movementConfirmed", p.getBoolean("movementConfirmed", false));
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
            final String finalMime=mime;
            final String finalText=call.getString("text", "Hóa đơn CabCalc");
            final String finalTitle=call.getString("title", "CabCalc");
            final Activity activity=getActivity();
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
                    notifyListeners("shareStarted", new JSObject().put("uri", uri.toString()));
                } catch (Exception e) {
                    notifyListeners("shareError", new JSObject().put("message", String.valueOf(e.getMessage())));
                }
            });
            call.resolve(new JSObject().put("status", "SHARE_STARTED").put("uri", uri.toString()));
        } catch (Exception e) {
            call.reject("Không thể chia sẻ tệp: " + e.getMessage(), e);
        }
    }

    @PluginMethod
    public void requestAlways(PluginCall call) {
        // Android has no iOS-style Always authorization prompt. Background
        // location is requested by MainActivity/OS separately.
        call.resolve(new JSObject()
            .put("authorization", hasLocationPermission() ? "AUTHORIZED" : "DENIED")
            .put("background", ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED));
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
            .put("preciseLocation", hasFineLocationPermission())
            .put("servicesEnabled", enabled)
            .put("started", p.getBoolean("started", false))
            .put("hasFix", p.contains("lat") && p.contains("lon"))
            .put("accuracy", p.getFloat("accuracy", 999))
            .put("timestamp", p.getLong("timestamp", 0))
            .put("notificationGranted", hasNotificationPermission()));
    }
}
