# SensorBridge

An Android app that reads a **Govee H5075** Bluetooth Low Energy thermometer /
hygrometer and forwards every validated reading to an **MQTT** broker.

It runs as a foreground service, so scanning and publishing continue while the
screen is off or the app is closed.

The companion [Plasma widget](plasma-widget/) shows the latest readings from
Grafana on the desktop, one row per sensor.

## How it works

1. `SensorService` scans for BLE advertisements and looks for manufacturer ID
   `0xEC88` (Govee).
2. `H5075` decodes the six-byte payload into temperature, humidity and battery
   level, and rejects error frames and implausible values.
3. Valid readings are published as JSON to the configured topic (QoS 0).
   Each sensor is tracked separately by BLE address, so identical
   advertisements repeated by one sensor within 1.5 s are suppressed without
   hiding readings from another.
4. The MQTT connection is retried every 10 s; a failed publish drops the client
   so the next attempt reconnects cleanly.
5. While running, the service stamps a heartbeat every 10 s. The settings screen
   treats a heartbeat older than 30 s as stopped, so it does not keep showing a
   stale "connected" status after a reboot or an app update.

## Payload

```json
{
  "name": "GVH5075_1234",
  "address": "A4:C1:38:00:00:01",
  "rssi": -62,
  "temperature": 23.5,
  "humidity": 48.2,
  "battery": 95,
  "raw": "01 03 97 DA 5F 00",
  "timestamp": 1700000000000
}
```

`temperature` is Celsius and `timestamp` is milliseconds since the epoch.
`name` is the name the sensor advertises; when an advertisement omits it, the
app falls back to `GVH5075_` plus the last four digits of the address, the same
scheme Govee uses.

## Using the app

1. Install and open **SensorBridge**.
2. Enter the broker hostname, port, username, password and topic, then tap
   **Save MQTT Settings**. Defaults are `mqtt`, `1883`, `mqttuser`, an empty
   password and `sensors/govee/H5075`.
3. Grant the location permission when prompted. Android requires it for BLE
   scanning, and system location must also be switched on.
4. Disable battery optimization when prompted, or tap **Disable Battery
   Optimization**. Otherwise Doze / App Standby can suspend scanning while the
   screen is off. The app shows whether the exemption is currently in place.
5. Tap **START SENSORBRIDGE**. The settings screen and the persistent
   notification show the current state plus one line per detected sensor (for
   example `GVH5075_B6D2: 21.4 C, 48.2 %, 95 %`). Tapping the notification
   reopens the app, and its **Stop** action shuts the service down.
6. Use **Publish Test Reading** to verify the full path to the broker and the
   sensor topic. The test payload uses the reserved name `TEST` and includes
   `"test":true`, so it is easy to filter out downstream.

The service keeps running in the background until **STOP SENSORBRIDGE** is
pressed.

## Building

Requires JDK 17 and the Android SDK with platform 35 and build-tools 35.0.0.

```sh
cd android-app
./gradlew test assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The signed release build is `android-app/release/sensorbridge-1.2.apk`
(versionCode 3, versionName 1.2).

## Plasma widget

`plasma-widget/` is a KDE Plasma 6 applet that queries Grafana's HTTP API for
the same sensors and shows temperature, humidity, battery and reading age.

```sh
kpackagetool6 --type Plasma/Applet --install plasma-widget
```

After changing it, upgrade with `--upgrade plasma-widget` instead. See
[`plasma-widget/README.md`](plasma-widget/README.md) for configuration and
troubleshooting.

## Layout

    android-app/                     Android source, Gradle wrapper, keystore, release APK
    android-app/app/src/main/java/com/whatamesss/sensorbridge/
      MainActivity.java              settings UI and service control
      SensorService.java             foreground BLE scanner and MQTT publisher
      H5075.java                     Android-free payload decoder
    android-app/app/src/test/java/com/whatamesss/sensorbridge/
      H5075Test.java                 decoder unit tests
    plasma-widget/                   KDE Plasma 6 desktop widget

## Notes

- The application ID is `com.whatamesss.sensorbridge`.
- Debug builds are signed with `android-app/keystore/debug.keystore`, which is
  checked in so the signing key stays the same across machines and rebuilds.
  Without it, AGP generates a fresh debug key whenever the user-home keystore
  is missing, and Android then refuses to update an installed build in place.
- `minSdk` / `targetSdk` are 27 (Android 8.1), matching the device this was
  built for. Android 12+ additionally requires `BLUETOOTH_SCAN` /
  `BLUETOOTH_CONNECT` runtime permissions; they are not declared here.
- The MQTT password is stored in the app's private `SharedPreferences`, which
  is not encrypted. Use a broker account scoped to this device only.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is declared so the app can ask to be
  exempted from Doze / App Standby. Google Play restricts that permission to
  exempt app categories, so a store release may need the app to be classified
  accordingly.
