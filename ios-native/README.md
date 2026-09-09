# TAXIMET PRO — iOS unsigned IPA

This repository wraps the existing TAXIMET PRO PWA in a native iOS WKWebView and adds a native Core Location layer for background location updates.

## Important iOS behavior

- Foreground: the existing web fare/GPS engine remains the main engine.
- Background/locked screen: native Core Location continues receiving location updates while the trip is running.
- When returning to the foreground, background distance accumulated natively is reconciled into the web trip.
- `UIBackgroundModes=location`, `allowsBackgroundLocationUpdates=true`, automotive activity type, and disabled automatic pauses are configured.
- The app requests location authorization from the user.

### Limitation

No iOS application can honestly guarantee continuous execution after the user force-quits/swipes the app away. Apple documents that standard location updates stop when the app is terminated. This project targets normal background/screen-lock operation, not force-quit persistence.

## Build

Push this project to GitHub. The workflow:

`.github/workflows/build-unsigned-ipa.yml`

runs on a macOS GitHub Actions runner, builds without code signing, packages the `.app` into `Payload/`, and publishes:

`TAXIMET_PRO_unsigned.ipa`

as a workflow artifact.

An unsigned IPA is not directly installable on a normal iPhone without a signing/install mechanism.
