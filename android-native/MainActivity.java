package com.taximet.pro;

import android.content.Intent;
import android.os.Bundle;

import com.ev.taximetpro.TaximetLocationPlugin;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(TaximetLocationPlugin.class);
        super.onCreate(savedInstanceState);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
    }
}
