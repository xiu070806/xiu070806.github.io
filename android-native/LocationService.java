package com.ev.taximetpro;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.IBinder;
import android.os.Looper;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

public class LocationService extends Service {

    private static final String CHANNEL_ID = "taximet_location";
    private static final int NOTIFICATION_ID = 1901;
    private static final String PREFS = "taximet_native_gps";

    private LocationManager locationManager;

    private final LocationListener listener = new LocationListener() {
        @Override
        public void onLocationChanged(Location l) {
            saveLocation(l);

            Intent i = new Intent("com.ev.taximetpro.LOCATION");
            i.setPackage(getPackageName());
            i.putExtra("latitude", l.getLatitude());
            i.putExtra("longitude", l.getLongitude());
            i.putExtra("accuracy", l.hasAccuracy() ? l.getAccuracy() : 0f);
            i.putExtra("speed", l.hasSpeed() ? l.getSpeed() : -1f);
            i.putExtra("heading", l.hasBearing() ? l.getBearing() : -1f);
            i.putExtra("timestamp", l.getTime());
            sendBroadcast(i);
        }

        @Override
        public void onProviderDisabled(String provider) {
            sendError("GPS provider bị tắt");
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();

        createChannel();

        /*
         * Explicitly target the real launcher Activity.
         * This avoids relying on getLaunchIntentForPackage(), which can
         * become unreliable when the generated Capacitor launcher intent
         * changes.
         */
        Intent launchIntent =
                new Intent(this, com.taximet.pro.MainActivity.class);

        launchIntent.setAction(Intent.ACTION_MAIN);
        launchIntent.addCategory(Intent.CATEGORY_LAUNCHER);

        launchIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK |
                Intent.FLAG_ACTIVITY_SINGLE_TOP |
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        );

        PendingIntent contentIntent = PendingIntent.getActivity(
                this,
                NOTIFICATION_ID,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT |
                PendingIntent.FLAG_IMMUTABLE
        );

        NotificationCompat.Builder builder =
                new NotificationCompat.Builder(this, CHANNEL_ID)
                        .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                        .setContentTitle("TAXIMET PRO")
                        .setContentText("Đang nhận GPS cho chuyến đang chạy")
                        .setOngoing(true)
                        .setCategory(NotificationCompat.CATEGORY_SERVICE)
                        .setPriority(NotificationCompat.PRIORITY_LOW)
                        .setAutoCancel(false)
                        .setContentIntent(contentIntent);

        startForeground(NOTIFICATION_ID, builder.build());

        requestUpdates();
    }

    private void requestUpdates() {
        boolean fine = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED;

        boolean coarse = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED;

        if (!fine && !coarse) {
            sendError("Chưa cấp quyền GPS");
            stopSelf();
            return;
        }

        locationManager =
                (LocationManager) getSystemService(LOCATION_SERVICE);

        try {
            locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    1000L,
                    1.0f,
                    listener,
                    Looper.getMainLooper()
            );

            if (locationManager.isProviderEnabled(
                    LocationManager.NETWORK_PROVIDER
            )) {
                locationManager.requestLocationUpdates(
                        LocationManager.NETWORK_PROVIDER,
                        2000L,
                        2.0f,
                        listener,
                        Looper.getMainLooper()
                );
            }

        } catch (Exception e) {
            sendError(
                    e.getMessage() == null
                            ? "Không thể khởi động GPS"
                            : e.getMessage()
            );
        }
    }

    private void saveLocation(Location l) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putString("lat", Double.toString(l.getLatitude()))
                .putString("lon", Double.toString(l.getLongitude()))
                .putFloat("acc", l.hasAccuracy() ? l.getAccuracy() : 0f)
                .putFloat("speed", l.hasSpeed() ? l.getSpeed() : -1f)
                .putFloat("heading", l.hasBearing() ? l.getBearing() : -1f)
                .putLong("time", l.getTime())
                .apply();
    }

    private void sendError(String message) {
        Intent i = new Intent("com.ev.taximetpro.LOCATION_ERROR");
        i.setPackage(getPackageName());
        i.putExtra("message", message);
        sendBroadcast(i);
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel c = new NotificationChannel(
                    CHANNEL_ID,
                    "TAXIMET PRO GPS",
                    NotificationManager.IMPORTANCE_LOW
            );

            NotificationManager nm =
                    (NotificationManager) getSystemService(
                            NOTIFICATION_SERVICE
                    );

            nm.createNotificationChannel(c);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (locationManager == null) {
            requestUpdates();
        }

        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (locationManager != null) {
            try {
                locationManager.removeUpdates(listener);
            } catch (Exception ignored) {
            }
        }

        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
