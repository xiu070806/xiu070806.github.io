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
    private HandlerThread locationThread;
    private static final String PREF = "taximet_gps";
    private static final String KEY_APP_FOREGROUND = "appForeground"; // UI state only; NEVER gates distance accumulation
    private static final String KEY_TRIP_ACTIVE = "tripActive";
    private static final String KEY_TRIP_DISTANCE = "tripDistanceM";
    private static final String KEY_TRIP_LAST_LAT = "tripLastLat";
    private static final String KEY_TRIP_LAST_LON = "tripLastLon";
    private static final String KEY_TRIP_LAST_TS = "tripLastTs";
    private static final String KEY_SMALL_MOVE_M = "tripSmallMoveM";
    private static final String KEY_SMALL_MOVE_START_TS = "tripSmallMoveStartTs";
    private static final String KEY_TRIP_DISTANCE_BITS = "tripDistanceBits";
    private static final String KEY_NEEDS_ANCHOR = "tripNeedsAnchor";
    private static final double MIN_TRIP_DIRECT_M = 2.5;
    private static final double MIN_TRIP_COMMIT_M = 2.0;
    private static final float MAX_TRIP_ACCURACY_M = 50f;
    private static final float MAX_TRIP_DELTA_M = 10000f;
    private static final long MAX_TRIP_GAP_MS = 30000L;
    private static final double MAX_TRIP_SPEED_MPS = 55.0;
    private static final double MIN_SMALL_AVG_SPEED_MPS = 0.45;
    private static final double CONFIDENT_SPEED_MPS = 0.8;
    // Speed is UI telemetry, not raw GPS truth.  A cached/one-off Android
    // Location.getSpeed() value must never appear as vehicle movement.
    private static final String KEY_SPEED_LAST_LAT = "speedLastLat";
    private static final String KEY_SPEED_LAST_LON = "speedLastLon";
    private static final String KEY_SPEED_LAST_TS = "speedLastTs";
    private static final String KEY_SPEED_MOVING_FIXES = "speedMovingFixes";
    private static final String KEY_SPEED_DISPLAY_MPS = "speedDisplayMps";
    private static final long SPEED_MAX_FIX_AGE_MS = 5000L;
    private static final int MIN_MOVING_SPEED_FIXES = 3;
    private static final double SPEED_MOVING_MPS = 1.20;
    private static final double SPEED_DERIVED_MIN_MPS = 0.70;
    private static final double SPEED_STOP_MPS = 0.35;

    @Override public void onCreate() {
        super.onCreate();

        locationThread = new HandlerThread("CabCalc-GPS-LOCATION");
        locationThread.start();

        createChannel();

        // Must enter foreground immediately on Android 8+.
        startForeground(NOTIFICATION_ID, notification());

        fused = LocationServices.getFusedLocationProviderClient(this);
        SharedPreferences bootPrefs = getSharedPreferences(PREF, 0);
        if (bootPrefs.getBoolean(KEY_TRIP_ACTIVE, false)) {
            // Service/process restart: preserve accumulated distance but reset
            // transient speed confirmation so stale speed can never reappear.
            bootPrefs.edit().putInt(KEY_SPEED_MOVING_FIXES, 0).putFloat(KEY_SPEED_DISPLAY_MPS, 0f)
                .remove(KEY_SPEED_LAST_LAT).remove(KEY_SPEED_LAST_LON).remove(KEY_SPEED_LAST_TS).apply();
            // Service/process restart: preserve accumulated distance but never
            // connect a pre-restart coordinate to the first post-restart fix.
            bootPrefs.edit().putBoolean(KEY_NEEDS_ANCHOR, true)
                .remove(KEY_TRIP_LAST_LAT).remove(KEY_TRIP_LAST_LON).remove(KEY_TRIP_LAST_TS)
                .remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS).apply();
        }

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
                    java.util.List<android.location.Location> batch=new java.util.ArrayList<>(x.getLocations());
                    java.util.Collections.sort(batch,(a,b)->Long.compare(a.getTime(),b.getTime()));
                    for (android.location.Location l : batch) publish(l);
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
        Looper locationLooper = locationThread != null ? locationThread.getLooper() : Looper.getMainLooper();
        fused.requestLocationUpdates(request, cb, locationLooper)
            .addOnSuccessListener(v -> {
                markStarted(true);
                status();
                // Bootstrap the WebView/native bridge immediately from a cached fix.
                // The normal 1s Fused stream remains the authoritative source.
                try {
                    fused.getLastLocation().addOnSuccessListener(last -> {
                        if (last != null) publish(last);
                    });
                } catch (Exception ignored) {}
                // Ask for one fresh high-accuracy fix so first-launch does not sit at
                // “ĐANG LẤY GPS…” merely because no cached fix existed.
                try {
                    fused.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
                        .addOnSuccessListener(current -> {
                            if (current != null) publish(current);
                        })
                        .addOnFailureListener(e -> error(2, String.valueOf(e.getMessage())));
                } catch (Exception ignored) {}
            })
            .addOnFailureListener(e -> {
                markStarted(false);
                error(2, String.valueOf(e.getMessage()));
            });
    }

    private void markStarted(boolean value) {
        getSharedPreferences("taximet_gps", 0).edit()
            .putBoolean("started", value)
            .apply();
    }

    private void publish(android.location.Location l) {
        updateTripDistance(l);
        SharedPreferences gpsPrefs = getSharedPreferences(PREF, 0);
        double displaySpeedMps = resolveDisplaySpeedMps(l, gpsPrefs);
        double rawSpeedMps = l.hasSpeed() && Float.isFinite(l.getSpeed()) && l.getSpeed() >= 0 ? l.getSpeed() : -1d;
        boolean movementConfirmed = displaySpeedMps > 0d;
        gpsPrefs.edit()
            .putFloat("lat", (float)l.getLatitude())
            .putFloat("lon", (float)l.getLongitude())
            .putFloat("accuracy", Math.max(0, l.getAccuracy()))
            .putFloat("speedMps", (float)displaySpeedMps)
            .putFloat("rawSpeedMps", (float)rawSpeedMps)
            .putBoolean("movementConfirmed", movementConfirmed)
            .putFloat("heading", l.hasBearing() ? l.getBearing() : -1)
            .putLong("timestamp", l.getTime())
            .putBoolean("started", true)
            .apply();

        Intent i = new Intent(TaximetLocationPlugin.ACTION_LOCATION)
            .setPackage(getPackageName())
            .putExtra("latitude", l.getLatitude())
            .putExtra("longitude", l.getLongitude())
            .putExtra("accuracy", (double)Math.max(0, l.getAccuracy()))
            .putExtra("speedMps", displaySpeedMps)
            .putExtra("speedKmh", displaySpeedMps * 3.6d)
            .putExtra("rawSpeedMps", rawSpeedMps)
            .putExtra("movementConfirmed", movementConfirmed)
            .putExtra("gpsFixFresh", isFreshGpsFix(l))
            .putExtra("heading", l.hasBearing() ? (double)l.getBearing() : -1d)
            .putExtra("timestamp", l.getTime())
            .putExtra("background", !getSharedPreferences(PREF,0).getBoolean(KEY_APP_FOREGROUND,true))
            .putExtra("tripDistanceM", getTripDistanceM(getSharedPreferences(PREF,0)));

        sendBroadcast(i);
    }


    /**
     * Single native distance engine for the whole trip.
     * It deliberately does NOT check appForeground/backgroundTripTracking.
     * Therefore the exact same accumulator continues while the Activity/WebView
     * is foregrounded, backgrounded, locked, or recreated.
     */
    /**
     * Single native distance engine for the whole trip.
     * Foreground/background/locked screen all use this exact same accumulator.
     * A rejected GPS point is used only as a recovery anchor when necessary;
     * it is NEVER added to distance.
     */
    private double getTripDistanceM(SharedPreferences p) {
        if (p.contains(KEY_TRIP_DISTANCE_BITS)) {
            double d=Double.longBitsToDouble(p.getLong(KEY_TRIP_DISTANCE_BITS, Double.doubleToLongBits(0d)));
            return Double.isFinite(d) && d>=0 ? d : 0d;
        }
        float legacy=p.getFloat(KEY_TRIP_DISTANCE,0f);
        return Float.isFinite(legacy) && legacy>=0 ? legacy : 0d;
    }

    private void putTripDistanceM(SharedPreferences.Editor e,double d) {
        double safe=Double.isFinite(d)&&d>=0?d:0d;
        e.putLong(KEY_TRIP_DISTANCE_BITS,Double.doubleToLongBits(safe)).remove(KEY_TRIP_DISTANCE);
    }

    private boolean isFreshGpsFix(android.location.Location l) {
        long age = System.currentTimeMillis() - l.getTime();
        return l.getTime() > 0L && age >= -2000L && age <= SPEED_MAX_FIX_AGE_MS;
    }

    private double resolveDisplaySpeedMps(android.location.Location l, SharedPreferences p) {
        if (!p.getBoolean(KEY_TRIP_ACTIVE, false)) {
            return 0d;
        }
        float acc = l.hasAccuracy() ? l.getAccuracy() : 999f;
        if (!Float.isFinite(acc) || acc < 0f || acc > MAX_TRIP_ACCURACY_M || !isFreshGpsFix(l)) {
            p.edit().putInt(KEY_SPEED_MOVING_FIXES, 0).putFloat(KEY_SPEED_DISPLAY_MPS, 0f)
                .remove(KEY_SPEED_LAST_LAT).remove(KEY_SPEED_LAST_LON).remove(KEY_SPEED_LAST_TS).apply();
            return 0d;
        }
        double raw = l.hasSpeed() && Float.isFinite(l.getSpeed()) && l.getSpeed() >= 0f ? l.getSpeed() : -1d;
        long ts = l.getTime();
        double lat = l.getLatitude(), lon = l.getLongitude();
        double prevLat = Double.longBitsToDouble(p.getLong(KEY_SPEED_LAST_LAT, Double.doubleToLongBits(Double.NaN)));
        double prevLon = Double.longBitsToDouble(p.getLong(KEY_SPEED_LAST_LON, Double.doubleToLongBits(Double.NaN)));
        long prevTs = p.getLong(KEY_SPEED_LAST_TS, 0L);
        double derived = -1d;
        if (Double.isFinite(prevLat) && Double.isFinite(prevLon) && prevTs > 0L && ts > prevTs && ts - prevTs <= 5000L) {
            float[] out = new float[1];
            Location.distanceBetween(prevLat, prevLon, lat, lon, out);
            if (Float.isFinite(out[0]) && out[0] >= 0f) derived = out[0] / ((ts - prevTs) / 1000d);
        }
        int moving = p.getInt(KEY_SPEED_MOVING_FIXES, 0);
        if (raw >= SPEED_MOVING_MPS && (derived < 0d || derived >= SPEED_DERIVED_MIN_MPS)) {
            moving = Math.min(MIN_MOVING_SPEED_FIXES, moving + 1);
        } else if (raw >= 0d && raw <= SPEED_STOP_MPS) {
            moving = 0;
        } else if (derived >= 0d && derived < SPEED_STOP_MPS) {
            moving = 0;
        }
        double display = 0d;
        if (moving >= MIN_MOVING_SPEED_FIXES) {
            double candidate = raw >= 0d ? raw : Math.max(0d, derived);
            display = Math.max(0d, Math.min(MAX_TRIP_SPEED_MPS, candidate));
        }
        p.edit().putLong(KEY_SPEED_LAST_LAT, Double.doubleToLongBits(lat))
            .putLong(KEY_SPEED_LAST_LON, Double.doubleToLongBits(lon))
            .putLong(KEY_SPEED_LAST_TS, ts)
            .putInt(KEY_SPEED_MOVING_FIXES, moving)
            .putFloat(KEY_SPEED_DISPLAY_MPS, (float)display).apply();
        return display;
    }

    private void updateTripDistance(android.location.Location l) {
        SharedPreferences p=getSharedPreferences(PREF,0);
        if(!p.getBoolean(KEY_TRIP_ACTIVE,false)) return;

        // A taximeter needs precise location. Approximate/COARSE-only Android
        // location must never advance the fare distance.
        if(!hasFineLocationPermission()){
            p.edit().putBoolean(KEY_NEEDS_ANCHOR,true).remove(KEY_TRIP_LAST_LAT).remove(KEY_TRIP_LAST_LON).remove(KEY_TRIP_LAST_TS)
                .remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS).apply();
            return;
        }

        float acc=l.hasAccuracy()?l.getAccuracy():999f;
        if(!Float.isFinite(acc)||acc<0||acc>MAX_TRIP_ACCURACY_M){
            p.edit().putBoolean(KEY_NEEDS_ANCHOR,true).remove(KEY_TRIP_LAST_LAT).remove(KEY_TRIP_LAST_LON).remove(KEY_TRIP_LAST_TS)
                .remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS).apply();
            return;
        }

        double lat=l.getLatitude(),lon=l.getLongitude();
        long ts=l.getTime()>0?l.getTime():System.currentTimeMillis();
        if(!Double.isFinite(lat)||!Double.isFinite(lon)) return;

        boolean needs=p.getBoolean(KEY_NEEDS_ANCHOR,true);
        double lat0=Double.longBitsToDouble(p.getLong(KEY_TRIP_LAST_LAT,Double.doubleToLongBits(Double.NaN)));
        double lon0=Double.longBitsToDouble(p.getLong(KEY_TRIP_LAST_LON,Double.doubleToLongBits(Double.NaN)));
        long ts0=p.getLong(KEY_TRIP_LAST_TS,0L);
        if(needs||!Double.isFinite(lat0)||!Double.isFinite(lon0)||ts0<=0L){
            saveTripAnchor(p,lat,lon,ts);
            p.edit().putBoolean(KEY_NEEDS_ANCHOR,false).apply();
            clearSmallMove(p);
            return;
        }

        long dt=ts-ts0;
        if(dt<=0L) return;
        if(dt>MAX_TRIP_GAP_MS){
            saveTripAnchor(p,lat,lon,ts);
            p.edit().putBoolean(KEY_NEEDS_ANCHOR,false).apply();
            clearSmallMove(p);
            return;
        }

        float[] out=new float[1];
        android.location.Location.distanceBetween(lat0,lon0,lat,lon,out);
        double d=out[0];
        if(!Double.isFinite(d)||d<0||d>=MAX_TRIP_DELTA_M){
            p.edit().putBoolean(KEY_NEEDS_ANCHOR,true).remove(KEY_TRIP_LAST_LAT).remove(KEY_TRIP_LAST_LON).remove(KEY_TRIP_LAST_TS)
                .remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS).apply();
            return;
        }

        double derivedSpeed=d/(dt/1000.0);
        if(!Double.isFinite(derivedSpeed)||derivedSpeed>MAX_TRIP_SPEED_MPS){
            p.edit().putBoolean(KEY_NEEDS_ANCHOR,true).remove(KEY_TRIP_LAST_LAT).remove(KEY_TRIP_LAST_LON).remove(KEY_TRIP_LAST_TS)
                .remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS).apply();
            return;
        }

        double reportedSpeed=l.hasSpeed()&&Float.isFinite(l.getSpeed())&&l.getSpeed()>=0?l.getSpeed():-1;
        double confident = reportedSpeed>=CONFIDENT_SPEED_MPS || (reportedSpeed<0 && derivedSpeed>=CONFIDENT_SPEED_MPS) ? 1d : 0d;
        boolean stationaryReported = reportedSpeed>=0 && reportedSpeed<0.35;
        double total=getTripDistanceM(p);
        SharedPreferences.Editor e=p.edit();

        if((d>=MIN_TRIP_DIRECT_M && !stationaryReported) || confident>0){
            putTripDistanceM(e,total+d);
            e.remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS);
        }else{
            float buffered=p.getFloat(KEY_SMALL_MOVE_M,0f);
            long start=p.getLong(KEY_SMALL_MOVE_START_TS,0L);
            if(start<=0L)start=ts0;
            buffered+=d;
            double window=Math.max(0.001,(ts-start)/1000.0);
            double avg=buffered/window;
            double evidence=Math.max(avg,reportedSpeed>=0?reportedSpeed:derivedSpeed);
            if(buffered>=MIN_TRIP_COMMIT_M && evidence>=MIN_SMALL_AVG_SPEED_MPS){
                putTripDistanceM(e,total+buffered);
                e.remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS);
            }else{
                e.putFloat(KEY_SMALL_MOVE_M,buffered).putLong(KEY_SMALL_MOVE_START_TS,start);
            }
        }

        e.putLong(KEY_TRIP_LAST_LAT,Double.doubleToLongBits(lat))
         .putLong(KEY_TRIP_LAST_LON,Double.doubleToLongBits(lon))
         .putLong(KEY_TRIP_LAST_TS,ts)
         .putBoolean(KEY_NEEDS_ANCHOR,false)
         .apply();
    }

    private void clearSmallMove(SharedPreferences p){p.edit().remove(KEY_SMALL_MOVE_M).remove(KEY_SMALL_MOVE_START_TS).apply();}

    private void saveTripAnchor(SharedPreferences p, double lat, double lon, long ts) {
        p.edit()
            .putLong(KEY_TRIP_LAST_LAT, Double.doubleToLongBits(lat))
            .putLong(KEY_TRIP_LAST_LON, Double.doubleToLongBits(lon))
            .putLong(KEY_TRIP_LAST_TS, ts)
            .apply();
    }

    private boolean hasFineLocationPermission() {
        return ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
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
                    CH, "CabCalc GPS", NotificationManager.IMPORTANCE_DEFAULT
                );
                ch.setDescription("Thông báo khi CabCalc đang nhận GPS chạy nền");
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
            .setContentTitle("CabCalc")
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
        if (locationThread != null) {
            locationThread.quitSafely();
            locationThread = null;
        }
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
            Log.w("CABCalc_GPS", "restarting CabCalc location updates", e);
        }
        return START_STICKY;
    }

    @Nullable @Override public IBinder onBind(Intent i) {
        return null;
    }
}
