package com.xiu070806.taximetpro;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    private static final int REQ_LOCATION = 4401;
    private static final int REQ_NOTIFICATIONS = 4403;
    private static final int REQ_BACKGROUND_LOCATION = 4404;

    @Override public void onCreate(Bundle savedInstanceState) {
        registerPlugin(TaximetLocationPlugin.class);
        super.onCreate(savedInstanceState);
        try { getBridge().getWebView().addJavascriptInterface(new TaximetNativeShare(this, getBridge().getWebView()), "TaximetNativeShare"); } catch (Exception ignored) {}
        getSharedPreferences("taximet_gps", 0).edit().putBoolean("appForeground", true).apply();
        requestRuntimePermissionsAndStartGps();
    }
    @Override public void onResume() { super.onResume(); getSharedPreferences("taximet_gps", 0).edit().putBoolean("appForeground", true).apply(); requestRuntimePermissionsAndStartGps(); }
    @Override public void onPause() { getSharedPreferences("taximet_gps", 0).edit().putBoolean("appForeground", false).apply(); super.onPause(); }
    private boolean hasLocation() { return ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED || ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION)==PackageManager.PERMISSION_GRANTED; }
    private boolean hasNotifications() { return Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED; }
    private void requestRuntimePermissionsAndStartGps() {
        if (!hasLocation()) { ActivityCompat.requestPermissions(this,new String[]{Manifest.permission.ACCESS_FINE_LOCATION,Manifest.permission.ACCESS_COARSE_LOCATION},REQ_LOCATION); return; }
        startGpsService();
        if (Build.VERSION.SDK_INT >= 30 && ContextCompat.checkSelfPermission(this,Manifest.permission.ACCESS_BACKGROUND_LOCATION)!=PackageManager.PERMISSION_GRANTED) { ActivityCompat.requestPermissions(this,new String[]{Manifest.permission.ACCESS_BACKGROUND_LOCATION},REQ_BACKGROUND_LOCATION); return; }
        if (Build.VERSION.SDK_INT >= 33 && !hasNotifications()) ActivityCompat.requestPermissions(this,new String[]{Manifest.permission.POST_NOTIFICATIONS},REQ_NOTIFICATIONS);
    }
    private void startGpsService() { try { Intent i=new Intent(this,TaximetLocationService.class); if(Build.VERSION.SDK_INT>=26) ContextCompat.startForegroundService(this,i); else startService(i); } catch(Exception ignored) {} }
    @Override public void onRequestPermissionsResult(int requestCode,@NonNull String[] permissions,@NonNull int[] grantResults) { super.onRequestPermissionsResult(requestCode,permissions,grantResults); if(requestCode==REQ_LOCATION||requestCode==REQ_BACKGROUND_LOCATION||requestCode==REQ_NOTIFICATIONS) requestRuntimePermissionsAndStartGps(); }
}
