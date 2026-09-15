package com.xiu070806.taximetpro;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import android.util.Log;
import org.json.*;
import androidx.annotation.Nullable;
import androidx.core.app.*;
import com.google.android.gms.location.*;

public class TaximetLocationService extends Service {
    private static final String CH = "taximet_gps";
    private static final int NOTIFICATION_ID = 4402;

    private FusedLocationProviderClient fused;
    private LocationCallback cb;
    private static final String PREF = "taximet_gps";
    private static final String KEY_BG_MODE = "backgroundTripTracking";
    private static final String KEY_APP_FOREGROUND = "appForeground";
    private static final String KEY_BG_DISTANCE = "backgroundTripDistanceM";
    private static final String KEY_TRIP_DISTANCE = "tripDistanceM";
    private static final String KEY_BG_LAST_LAT = "backgroundLastLat";
    private static final String KEY_BG_LAST_LON = "backgroundLastLon";
    private static final String KEY_BG_LAST_TS = "backgroundLastTs";

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
         .setWaitForAccurateLocation(false)
         .setGranularity(Granularity.GRANULARITY_PERMISSION_LEVEL)
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
            requestUpdates(r);
        } catch (SecurityException e) {
            error(1, "Không có quyền truy cập vị trí");
            stopSelf();
        }
    }

    private LocationRequest buildRequest() {
        return new LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(500L)
            .setMaxUpdateDelayMillis(1500L)
            .setWaitForAccurateLocation(false)
            .setGranularity(Granularity.GRANULARITY_PERMISSION_LEVEL)
            .build();
    }

    private void requestUpdates(LocationRequest request) {
        if (fused == null || cb == null) return;
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
            && ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            throw new SecurityException("location permission missing");
        }
        fused.removeLocationUpdates(cb);
        fused.requestLocationUpdates(request, cb, Looper.getMainLooper());
        markStarted(true);
        status();
    }

    private void markStarted(boolean value) {
        getSharedPreferences("taximet_gps", 0).edit()
            .putBoolean("started", value)
            .apply();
    }

    private void publish(android.location.Location l) {
        double tripDistanceM = updateTripDistance(l);
        getSharedPreferences(PREF, 0).edit()
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
            .putExtra("timestamp", l.getTime())
            .putExtra("background", !getSharedPreferences(PREF,0).getBoolean(KEY_APP_FOREGROUND,true))
            .putExtra("tripDistanceM", tripDistanceM);

        sendBroadcast(i);
    }


    /**
     * Native single-source-of-truth trip distance engine.
     * It runs inside the foreground location service, so WebView lifecycle
     * (foreground/background) cannot stop or reset the odometer.
     */
    private double updateTripDistance(android.location.Location l) {
        android.content.SharedPreferences p=getSharedPreferences(PREF,0);
        if(!p.getBoolean(KEY_BG_MODE,false)) return p.getFloat(KEY_TRIP_DISTANCE,0f);

        double lat0=Double.longBitsToDouble(p.getLong(KEY_BG_LAST_LAT, Double.doubleToLongBits(Double.NaN)));
        double lon0=Double.longBitsToDouble(p.getLong(KEY_BG_LAST_LON, Double.doubleToLongBits(Double.NaN)));
        float acc=l.hasAccuracy()?l.getAccuracy():999f;
        double total=p.getFloat(KEY_TRIP_DISTANCE,0f);
        if(Double.isFinite(lat0)&&Double.isFinite(lon0)&&acc<=80f){
            float[] out=new float[1];
            android.location.Location.distanceBetween(lat0,lon0,l.getLatitude(),l.getLongitude(),out);
            float d=out[0];
            long lastTs=p.getLong(KEY_BG_LAST_TS,0L);
            long nowTs=l.getTime()>0?l.getTime():System.currentTimeMillis();
            double dt=Math.max(0.001,(nowTs-lastTs)/1000.0);
            double speedKmh=d/dt*3.6;
            // Reject impossible jumps, but retain small real movements.
            if(d>=0.5f && d<10000f && speedKmh<=180.0) total += d;
        }
        p.edit()
            .putFloat(KEY_TRIP_DISTANCE,(float)total)
            .putFloat(KEY_BG_DISTANCE,(float)total) // compatibility with older HTML builds
            .putLong(KEY_BG_LAST_LAT,Double.doubleToLongBits(l.getLatitude()))
            .putLong(KEY_BG_LAST_LON,Double.doubleToLongBits(l.getLongitude()))
            .putLong(KEY_BG_LAST_TS,l.getTime()).apply();
        return total;
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

    @Override public void onTaskRemoved(Intent rootIntent) {
        // Keep the location foreground service alive when the task is swiped away.
        // Android may still stop services under battery restrictions; START_STICKY is retained.
        super.onTaskRemoved(rootIntent);
    }

    @Override public void onDestroy() {
        if (fused != null && cb != null) fused.removeLocationUpdates(cb);
        markStarted(false);
        super.onDestroy();
    }

    @Override public int onStartCommand(Intent i, int flags, int id) {
        try {
            if (Build.VERSION.SDK_INT >= 26) startForeground(NOTIFICATION_ID, notification());
            requestUpdates(buildRequest());
        } catch (SecurityException e) {
            error(1, "Không có quyền truy cập vị trí");
        } catch (Exception e) {
            Log.w("TAXIMET_GPS", "restarting location updates", e);
        }
        return START_STICKY;
    }

    @Nullable @Override public IBinder onBind(Intent i) {
        return null;
    }
}
