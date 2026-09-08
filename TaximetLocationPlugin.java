package com.ev.taximetpro;

import android.Manifest;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.core.content.ContextCompat;
import com.getcapacitor.*;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

@CapacitorPlugin(
    name = "TaximetLocation",
    permissions = {
        @Permission(
            strings = {
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            },
            alias = "location"
        )
    }
)
public class TaximetLocationPlugin extends Plugin {
    private BroadcastReceiver receiver;

    @Override public void load() {
        super.load();
        receiver = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent i) {
                if ("com.ev.taximetpro.LOCATION".equals(i.getAction())) {
                    JSObject o = new JSObject();
                    o.put("latitude", i.getDoubleExtra("latitude", 0));
                    o.put("longitude", i.getDoubleExtra("longitude", 0));
                    o.put("accuracy", i.getFloatExtra("accuracy", 0));
                    o.put("speed", i.getFloatExtra("speed", -1));
                    o.put("heading", i.getFloatExtra("heading", -1));
                    o.put("timestamp", i.getLongExtra("timestamp", System.currentTimeMillis()));
                    notifyListeners("locationUpdate", o);
                } else if ("com.ev.taximetpro.LOCATION_ERROR".equals(i.getAction())) {
                    JSObject o = new JSObject();
                    o.put("message", i.getStringExtra("message"));
                    notifyListeners("locationError", o);
                }
            }
        };

        IntentFilter f = new IntentFilter();
        f.addAction("com.ev.taximetpro.LOCATION");
        f.addAction("com.ev.taximetpro.LOCATION_ERROR");
        if (Build.VERSION.SDK_INT >= 33) {
            getContext().registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED);
        } else {
            getContext().registerReceiver(receiver, f);
        }
    }

    @PluginMethod
    public void start(PluginCall call) {
        boolean fine = ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        boolean coarse = ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        if (!fine && !coarse) {
            requestPermissionForAlias("location", call, "locationPerms");
            return;
        }
        startLocationService();
        call.resolve();
    }

    @PermissionCallback
    private void locationPerms(PluginCall call) {
        boolean fine = ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        boolean coarse = ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        if (fine || coarse) {
            startLocationService();
            call.resolve();
        } else {
            call.reject("Location permission denied");
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        getContext().stopService(new Intent(getContext(), LocationService.class));
        call.resolve();
    }

    @PluginMethod
    public void getLastLocation(PluginCall call) {
        android.content.SharedPreferences p = getContext().getSharedPreferences("taximet_native_gps", Context.MODE_PRIVATE);
        if (!p.contains("time")) {
            call.resolve();
            return;
        }
        JSObject o = new JSObject();
        o.put("latitude", Double.parseDouble(p.getString("lat", "0")));
        o.put("longitude", Double.parseDouble(p.getString("lon", "0")));
        o.put("accuracy", p.getFloat("acc", 0));
        o.put("speed", p.getFloat("speed", -1));
        o.put("heading", p.getFloat("heading", -1));
        o.put("timestamp", p.getLong("time", System.currentTimeMillis()));
        call.resolve(o);
    }

    private void startLocationService() {
        Intent i = new Intent(getContext(), LocationService.class);
        if (Build.VERSION.SDK_INT >= 26) {
            ContextCompat.startForegroundService(getContext(), i);
        } else {
            getContext().startService(i);
        }
    }

    @Override protected void handleOnDestroy() {
        if (receiver != null) {
            try { getContext().unregisterReceiver(receiver); } catch (Exception ignored) {}
        }
        super.handleOnDestroy();
    }
}
