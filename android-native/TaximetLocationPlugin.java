package com.ev.taximetpro;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.core.content.ContextCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;

@CapacitorPlugin(
    name = "TaximetLocation",
    permissions = {
        @Permission(
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
        @Override
        public void onReceive(Context context, Intent intent) {
            if (intent == null) return;

            String action = intent.getAction();

            if ("com.ev.taximetpro.LOCATION".equals(action)) {
                JSObject data = new JSObject();

                data.put("latitude",
                        intent.getDoubleExtra("latitude", Double.NaN));
                data.put("longitude",
                        intent.getDoubleExtra("longitude", Double.NaN));
                data.put("accuracy",
                        intent.getFloatExtra("accuracy", 999f));
                data.put("speed",
                        intent.getFloatExtra("speed", -1f));
                data.put("heading",
                        intent.getFloatExtra("heading", -1f));
                data.put("timestamp",
                        intent.getLongExtra(
                                "timestamp",
                                System.currentTimeMillis()
                        ));

                notifyListeners("locationUpdate", data);

            } else if ("com.ev.taximetpro.LOCATION_ERROR".equals(action)) {
                JSObject data = new JSObject();

                String message = intent.getStringExtra("message");

                data.put(
                        "message",
                        message == null ? "GPS_ERROR" : message
                );

                notifyListeners("locationError", data);
            }
        }
    };

    @Override
    public void load() {
        super.load();

        permissionLauncher = getActivity().registerForActivityResult(
                new ActivityResultContracts.RequestMultiplePermissions(),
                result -> {
                    if (pendingPermissionCall == null) return;

                    boolean fine = Boolean.TRUE.equals(
                            result.get(Manifest.permission.ACCESS_FINE_LOCATION)
                    );

                    boolean coarse = Boolean.TRUE.equals(
                            result.get(Manifest.permission.ACCESS_COARSE_LOCATION)
                    );

                    PluginCall call = pendingPermissionCall;
                    pendingPermissionCall = null;

                    if (fine || coarse) {
                        call.resolve();
                    } else {
                        call.reject("LOCATION_PERMISSION_DENIED");
                    }
                }
        );

        IntentFilter filter = new IntentFilter();
        filter.addAction("com.ev.taximetpro.LOCATION");
        filter.addAction("com.ev.taximetpro.LOCATION_ERROR");

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getContext().registerReceiver(
                    receiver,
                    filter,
                    Context.RECEIVER_NOT_EXPORTED
            );
        } else {
            getContext().registerReceiver(receiver, filter);
        }
    }

    @Override
    protected void handleOnDestroy() {
        try {
            getContext().unregisterReceiver(receiver);
        } catch (Exception ignored) {
        }

        if (pendingPermissionCall != null) {
            pendingPermissionCall.reject("PLUGIN_DESTROYED");
            pendingPermissionCall = null;
        }

        super.handleOnDestroy();
    }

    @PluginMethod
    public void start(PluginCall call) {
        if (!hasLocationPermission()) {
            pendingPermissionCall = call;

            permissionLauncher.launch(new String[] {
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
            });

            return;
        }

        try {
            Intent serviceIntent =
                    new Intent(getContext(), LocationService.class);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(
                        getContext(),
                        serviceIntent
                );
            } else {
                getContext().startService(serviceIntent);
            }

            call.resolve();

        } catch (Exception e) {
            String message = e.getMessage();

            call.reject(
                    message == null
                            ? "GPS_SERVICE_START_FAILED"
                            : message
            );
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        try {
            getContext().stopService(
                    new Intent(getContext(), LocationService.class)
            );

            call.resolve();

        } catch (Exception e) {
            String message = e.getMessage();

            call.reject(
                    message == null
                            ? "GPS_SERVICE_STOP_FAILED"
                            : message
            );
        }
    }

    @PluginMethod
    public void getLastLocation(PluginCall call) {
        SharedPreferences prefs =
                getContext().getSharedPreferences(
                        PREFS,
                        Context.MODE_PRIVATE
                );

        if (!prefs.contains("lat") || !prefs.contains("lon")) {
            call.resolve();
            return;
        }

        try {
            JSObject data = new JSObject();

            data.put(
                    "latitude",
                    Double.parseDouble(
                            prefs.getString("lat", "0")
                    )
            );

            data.put(
                    "longitude",
                    Double.parseDouble(
                            prefs.getString("lon", "0")
                    )
            );

            data.put(
                    "accuracy",
                    prefs.getFloat("acc", 999f)
            );

            data.put(
                    "speed",
                    prefs.getFloat("speed", -1f)
            );

            data.put(
                    "heading",
                    prefs.getFloat("heading", -1f)
            );

            data.put(
                    "timestamp",
                    prefs.getLong(
                            "time",
                            System.currentTimeMillis()
                    )
            );

            call.resolve(data);

        } catch (Exception e) {
            call.reject("GPS_LAST_LOCATION_READ_FAILED");
        }
    }

    @PluginMethod
    public void status(PluginCall call) {
        JSObject data = new JSObject();
        data.put("permission", hasLocationPermission());
        call.resolve(data);
    }

    private boolean hasLocationPermission() {
        return ContextCompat.checkSelfPermission(
                    getContext(),
                    Manifest.permission.ACCESS_FINE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
                ||
                ContextCompat.checkSelfPermission(
                    getContext(),
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED;
    }
}
