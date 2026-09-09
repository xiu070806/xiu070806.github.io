# TAXIMET PRO iOS v14 — triển khai

Bộ iOS dùng chung `native-web/index.html` với Android.

- PWA gốc `index.html`: không thay đổi.
- Android: native GPS bridge APK12-compatible (`nativePromise`) + Foreground Location Service.
- iOS: `registerPlugin("TaximetLocation")` + `CLLocationManager` + background location.
- Icon: dùng bộ EV Pro mới trong `assets/app-icon/`.
- Workflow: `.github/workflows/build-ios.yml` chạy trên `macos-15`, tạo unsigned `.app` và `.ipa` để kiểm tra/build artifact.

Đặt các file/thư mục này vào root repository hiện tại, không xóa các file PWA/Android đang có.
