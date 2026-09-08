package com.ev.taximetpro;

import android.Manifest;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.core.content.ContextCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(
    name = "TaximetLocation",
    permissions = {
        @CapacitorPlugin.Permission(
            alias = "location",
            strings = {
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            }
        )
    }
)
public class TaximetLocationPlugin extends Plugin {
    private static final String PREFS = "taximet_native_gps";
    private ActivityResultLauncher<String[]> permissionLauncher;
    private PluginCall pendingPermissionCall;

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (intent == null) return;
            String action = intent.getAction();

            if ("com.ev.taximetpro.LOCATION".equals(action)) {
                JSObject d = new JSObject();
                d.put("latitude", intent.getDoubleExtra("latitude", Double.NaN));
                d.put("longitude", intent.getDoubleExtra("longitude", Double.NaN));
                d.put("accuracy", intent.getFloatExtra("accuracy", 999f));
                d.put("speed", intent.getFloatExtra("speed", -1f));
                d.put("heading", intent.getFloatExtra("heading", -1f));
                d.put("timestamp", intent.getLongExtra("timestamp", System.currentTimeMillis()));
                notifyListeners("locationUpdate", d);
            } else if ("com.ev.taximetpro.LOCATION_ERROR".equals(action)) {
                JSObject d = new JSObject();
                d.put("message", intent.getStringExtra("message"));
                notifyListeners("locationError", d);
            }
        }
    };

    @Override public void load() {
        super.load();

        permissionLauncher = getActivity().registerForActivityResult(
            new ActivityResultContracts.RequestMultiplePermissions(),
            result -> {
                if (pendingPermissionCall == null) return;
                boolean fine = Boolean.TRUE.equals(result.get(Manifest.permission.ACCESS_FINE_LOCATION));
                boolean coarse = Boolean.TRUE.equals(result.get(Manifest.permission.ACCESS_COARSE_LOCATION));
                if (fine || coarse) pendingPermissionCall.resolve();
                else pendingPermissionCall.reject("LOCATION_PERMISSION_DENIED");
                pendingPermissionCall = null;
            }
        );

        IntentFilter f = new IntentFilter();
        f.addAction("com.ev.taximetpro.LOCATION");
        f.addAction("com.ev.taximetpro.LOCATION_ERROR");

        if (Build.VERSION.SDK_INT >= 33)
            getContext().registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED);
        else
            getContext().registerReceiver(receiver, f);
    }

    @Override protected void handleOnDestroy() {
        try { getContext().unregisterReceiver(receiver); } catch (Exception ignored) {}
        super.handleOnDestroy();
    }

    @PluginMethod public void start(PluginCall call) {
        if (!hasLocationPermission()) {
            pendingPermissionCall = call;
            permissionLauncher.launch(new String[] {
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            });
            return;
        }

        try {
            Intent service = new Intent(getContext(), LocationService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                ContextCompat.startForegroundService(getContext(), service);
            else
                getContext().startService(service);
            call.resolve();
        } catch (Exception e) {
            call.reject(e.getMessage() == null ? "GPS_SERVICE_START_FAILED" : e.getMessage());
        }
    }

    @PluginMethod public void stop(PluginCall call) {
        getContext().stopService(new Intent(getContext(), LocationService.class));
        call.resolve();
    }

    @PluginMethod public void getLastLocation(PluginCall call) {
        SharedPreferences p = getContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (!p.contains("lat") || !p.contains("lon")) {
            call.resolve();
            return;
        }
        JSObject d = new JSObject();
        d.put("latitude", Double.parseDouble(p.getString("lat", "0")));
        d.put("longitude", Double.parseDouble(p.getString("lon", "0")));
        d.put("accuracy", p.getFloat("acc", 999f));
        d.put("speed", p.getFloat("speed", -1f));
        d.put("heading", p.getFloat("heading", -1f));
        d.put("timestamp", p.getLong("time", System.currentTimeMillis()));
        call.resolve(d);
    }

    @PluginMethod public void status(PluginCall call) {
        JSObject d = new JSObject();
        d.put("permission", hasLocationPermission());
        call.resolve(d);
    }

    private boolean hasLocationPermission() {
        return ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION)
                == PackageManager.PERMISSION_GRANTED
            || ContextCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_COARSE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
    }
}
