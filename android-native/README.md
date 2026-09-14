# TAXIMET PRO Android native layer

This folder is installed into a Capacitor 7 Android project generated from `native-web/index.html`.

- `TaximetLocationPlugin.java`: Capacitor bridge named `TaximetLocation`.
- `TaximetLocationService.java`: foreground GPS service using Google Play Services Location.
- `MainActivity.java`: registers the plugin.

The Android bridge exposes `start`, `stop`, `getLastLocation`, and `status`, plus `locationUpdate`, `locationError`, and `gpsStatus` events.
