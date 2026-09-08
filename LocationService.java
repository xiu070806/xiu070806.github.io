package com.ev.taximetpro;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.location.*;
import android.os.*;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

public class LocationService extends Service {
    private static final String CHANNEL_ID = "taximet_location";
    private static final int NOTIFICATION_ID = 1901;
    private static final String PREFS = "taximet_native_gps";
    private static final String KEY_LAT = "lat";
    private static final String KEY_LON = "lon";
    private static final String KEY_ACC = "acc";
    private static final String KEY_SPEED = "speed";
    private static final String KEY_HEADING = "heading";
    private static final String KEY_TIME = "time";

    private LocationManager locationManager;

    private final LocationListener listener = new LocationListener() {
        @Override public void onLocationChanged(Location l) {
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

        @Override public void onProviderDisabled(String provider) {
            sendError("GPS provider bị tắt");
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        createChannel();

        /*
         * Clicking the foreground-service notification opens the TAXIMET PRO
         * main Activity. GPS service keeps running; the notification is not
         * cancelled by the click.
         */
        Intent launchIntent = getPackageManager()
            .getLaunchIntentForPackage(getPackageName());

        PendingIntent contentIntent = null;

        if (launchIntent != null) {
            launchIntent.addFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP |
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            );

            contentIntent = PendingIntent.getActivity(
                this,
                1901,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT |
                PendingIntent.FLAG_IMMUTABLE
            );
        }

        NotificationCompat.Builder builder =
            new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("TAXIMET PRO")
                .setContentText("Đang nhận GPS cho chuyến đang chạy")
                .setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setAutoCancel(false);

        if (contentIntent != null) {
            builder.setContentIntent(contentIntent);
        }

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
            (LocationManager)getSystemService(LOCATION_SERVICE);

        try {
            if (fine || coarse) {
                locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    1000L,
                    1.0f,
                    listener,
                    Looper.getMainLooper()
                );
            }

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
            .putString(KEY_LAT, Double.toString(l.getLatitude()))
            .putString(KEY_LON, Double.toString(l.getLongitude()))
            .putFloat(
                KEY_ACC,
                l.hasAccuracy() ? l.getAccuracy() : 0f
            )
            .putFloat(
                KEY_SPEED,
                l.hasSpeed() ? l.getSpeed() : -1f
            )
            .putFloat(
                KEY_HEADING,
                l.hasBearing() ? l.getBearing() : -1f
            )
            .putLong(KEY_TIME, l.getTime())
            .apply();
    }

    private void sendError(String message) {
        Intent i = new Intent(
            "com.ev.taximetpro.LOCATION_ERROR"
        );

        i.setPackage(getPackageName());
        i.putExtra("message", message);
        sendBroadcast(i);
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel c = new NotificationChannel(
                CHANNEL_ID,
                "TAXIMET PRO GPS",
                NotificationManager.IMPORTANCE_LOW
            );

            NotificationManager nm =
                (NotificationManager)getSystemService(
                    NOTIFICATION_SERVICE
                );

            nm.createNotificationChannel(c);
        }
    }

    @Override public int onStartCommand(
        Intent intent,
        int flags,
        int startId
    ) {
        if (locationManager == null) {
            requestUpdates();
        }

        return START_STICKY;
    }

    @Override public void onDestroy() {
        if (locationManager != null) {
            try {
                locationManager.removeUpdates(listener);
            } catch (Exception ignored) {}
        }

        super.onDestroy();
    }

    @Nullable
    @Override public IBinder onBind(Intent intent) {
        return null;
    }
}
