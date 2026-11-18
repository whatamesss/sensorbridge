# SensorBridge

Android app that reads Govee H5075 BLE thermometer/hygrometer advertisements
and publishes validated readings to MQTT. It runs as a foreground service.
A [KDE Plasma 6 widget](plasma-widget/) shows the latest readings from Grafana.

## Layout

- `android-app/` — Android source, Gradle wrapper, debug keystore, release APK
- `plasma-widget/` — Plasma 6 applet

Grafana dashboards and collector tooling are local-only and are not published.

## Build

Requires JDK 17 and Android SDK platform 35 / build-tools 35.0.0.

```sh
cd android-app
./gradlew test assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The signed release build is `android-app/release/sensorbridge-1.2.apk`
(versionCode 3, versionName 1.2).

## Widget

```sh
kpackagetool6 --type Plasma/Applet --install plasma-widget
```

See [`plasma-widget/README.md`](plasma-widget/README.md) for configuration.
