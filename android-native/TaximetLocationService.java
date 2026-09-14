package com.xiu070806.taximetpro;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import androidx.annotation.Nullable;
import androidx.core.app.*;
import com.google.android.gms.location.*;

public class TaximetLocationService extends Service {
    private static final String CH = "taximet_gps";
    private static final int NOTIFICATION_ID = 4402;

    private FusedLocationProviderClient fused;
    private LocationCallback cb;

    @Override public void onCreate() {
        super.onCreate();

        createChannel();

        // Must enter foreground immediately on Android 8+.
        startForeground(NOTIFICATION_ID, notification());

        fused = LocationServices.getFusedLocationProviderClient(this);

        LocationRequest r = new LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY, 1000L
        ).setMinUpdateIntervalMillis(500L)
         .setMaxUpdateDelayMillis(1500L)
         .build();

        cb = new LocationCallback() {
            @Override public void onLocationResult(LocationResult x) {
                if (x != null) {
                    for (android.location.Location l : x.getLocations()) publish(l);
                }
            }
        };

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
            && ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            error(1, "GPS chưa được cấp quyền");
            stopSelf();
            return;
        }

        try {
            fused.requestLocationUpdates(r, cb, Looper.getMainLooper());
            markStarted(true);
            status();
        } catch (SecurityException e) {
            error(1, "Không có quyền truy cập vị trí");
            stopSelf();
        }
    }

    private void markStarted(boolean value) {
        getSharedPreferences("taximet_gps", 0).edit()
            .putBoolean("started", value)
            .apply();
    }

    private void publish(android.location.Location l) {
        getSharedPreferences("taximet_gps", 0).edit()
            .putFloat("lat", (float)l.getLatitude())
            .putFloat("lon", (float)l.getLongitude())
            .putFloat("accuracy", Math.max(0, l.getAccuracy()))
            .putFloat("speedMps", l.hasSpeed() ? l.getSpeed() : -1)
            .putFloat("heading", l.hasBearing() ? l.getBearing() : -1)
            .putLong("timestamp", l.getTime())
            .putBoolean("started", true)
            .apply();

        Intent i = new Intent(TaximetLocationPlugin.ACTION_LOCATION)
            .setPackage(getPackageName())
            .putExtra("latitude", l.getLatitude())
            .putExtra("longitude", l.getLongitude())
            .putExtra("accuracy", (double)Math.max(0, l.getAccuracy()))
            .putExtra("speedMps", l.hasSpeed() ? (double)l.getSpeed() : -1d)
            .putExtra("heading", l.hasBearing() ? (double)l.getBearing() : -1d)
            .putExtra("timestamp", l.getTime());

        sendBroadcast(i);
    }

    private void error(int c, String m) {
        sendBroadcast(new Intent(TaximetLocationPlugin.ACTION_ERROR)
            .setPackage(getPackageName())
            .putExtra("code", c)
            .putExtra("message", m));
    }

    private void status() {
        sendBroadcast(new Intent(TaximetLocationPlugin.ACTION_STATUS)
            .setPackage(getPackageName())
            .putExtra("authorization", "AUTHORIZED")
            .putExtra("servicesEnabled", true)
            .putExtra("started", true)
            .putExtra("notificationGranted", notificationGranted()));
    }

    private boolean notificationGranted() {
        if (Build.VERSION.SDK_INT < 33) return true;
        return androidx.core.content.ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED;
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager)getSystemService(NOTIFICATION_SERVICE);
            if (nm != null) {
                NotificationChannel ch = new NotificationChannel(
                    CH, "TAXIMET PRO GPS", NotificationManager.IMPORTANCE_DEFAULT
                );
                ch.setDescription("Thông báo khi TAXIMET PRO đang nhận GPS chạy nền");
                ch.setShowBadge(false);
                nm.createNotificationChannel(ch);
            }
        }
    }

    private Notification notification() {
        Intent x = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pi = x == null ? null :
            PendingIntent.getActivity(
                this, 0, x,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT
            );

        return new NotificationCompat.Builder(this, CH)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("TAXIMET PRO")
            .setContentText("GPS đang hoạt động · đang chạy nền")
            .setOngoing(true)
            .setAutoCancel(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pi)
            .build();
    }

    @Override public void onDestroy() {
        if (fused != null && cb != null) fused.removeLocationUpdates(cb);
        markStarted(false);
        super.onDestroy();
    }

    @Override public int onStartCommand(Intent i, int flags, int id) {
        return START_STICKY;
    }

    @Nullable @Override public IBinder onBind(Intent i) {
        return null;
    }
}
