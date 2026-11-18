package com.whatamesss.sensorbridge;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * Foreground service that scans for Govee H5075 advertisements and forwards
 * each validated reading to the configured MQTT broker.
 */
public class SensorService extends Service {

    public static final String ACTION_START =
        "com.whatamesss.sensorbridge.START";
    public static final String ACTION_STOP =
        "com.whatamesss.sensorbridge.STOP";
    public static final String ACTION_TEST =
        "com.whatamesss.sensorbridge.TEST";
    public static final String STATUS_ACTION =
        "com.whatamesss.sensorbridge.STATUS";

    private static final String TAG = "SensorBridge";
    private static final String PREFS = "sensorbridge";

    private static final String CHANNEL = "sensorbridge_running";
    private static final int NOTIFICATION_ID = 42;

    private static final long MIN_PUBLISH_INTERVAL_MS = 1500;
    private static final long STATUS_INTERVAL_MS = 30000;
    private static final long HEARTBEAT_INTERVAL_S = 10;
    private static final long NO_DATA_TIMEOUT_MS = 120000;
    private static final long SCAN_RETRY_DELAY_S = 10;

    /**
     * Age after which {@link MainActivity} treats the service as stopped. The
     * heartbeat uses its own thread so a slow MQTT connect cannot starve it.
     */
    public static final long HEARTBEAT_STALE_MS = 30000;

    private final Object mqttLock = new Object();
    private final Object deviceLock = new Object();

    private ScheduledExecutorService executor;
    private ScheduledExecutorService heartbeatExecutor;
    private MqttClient mqtt;
    private BluetoothLeScanner scanner;
    private volatile boolean scanning = false;
    private boolean receiverRegistered = false;

    /** Per-sensor state, keyed by BLE address. */
    private final Map<String, Device> devices = new HashMap<>();

    private long lastStatusMs = 0;
    private volatile long lastReadingMs = 0;
    private long lastScanRestartMs = 0;

    /**
     * Tracks one physical sensor, so duplicate suppression and the stable
     * name are not shared between sensors that advertise in turns.
     */
    private static final class Device {
        String name;
        String lastRaw = "";
        long lastPublishMs = 0;
        String summary = "";
        long seenMs = 0;

        /** Remembers the advertised name; falls back to an address suffix. */
        String name(String advertised, String address) {
            if (advertised != null && !advertised.isEmpty()) {
                name = advertised;
            } else if (name == null) {
                name = fallbackName(address);
            }

            return name;
        }
    }

    /**
     * Govee names its devices GVH5075_XXXX where XXXX is the end of the MAC
     * address, so an unnamed advertisement still maps to a stable series.
     */
    static String fallbackName(String address) {
        String digits = address == null
            ? ""
            : address.replace(":", "").toUpperCase(Locale.US);

        if (digits.length() > 4) {
            digits = digits.substring(digits.length() - 4);
        }

        return digits.isEmpty() ? "Govee H5075" : "GVH5075_" + digits;
    }

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int type, ScanResult result) {
            ScanRecord record = result.getScanRecord();

            if (record == null) {
                return;
            }

            byte[] data = record.getManufacturerSpecificData()
                .get(H5075.MANUFACTURER_ID);

            if (data == null) {
                return;
            }

            H5075.Reading reading = H5075.decode(data);

            if (reading == null) {
                Log.w(TAG, "Ignoring invalid H5075 payload: " + H5075.hex(data));
                return;
            }

            publishReading(
                reading,
                result.getDevice().getAddress(),
                record.getDeviceName(),
                result.getRssi());
        }

        @Override
        public void onScanFailed(int errorCode) {
            if (errorCode == ScanCallback.SCAN_FAILED_ALREADY_STARTED) {
                scanning = true;
                return;
            }

            scanning = false;
            updateStatus("BLE scan failed: " + errorCode + "; retrying");
            scheduleScanRetry("Rescanning after BLE failure");
        }
    };

    /**
     * Android stops a scan when Bluetooth is turned off and does not resume
     * it, so the service watches the adapter and starts scanning again.
     */
    private final BroadcastReceiver bluetoothReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            int state = intent.getIntExtra(
                BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR);

            if (state == BluetoothAdapter.STATE_ON) {
                startBleScan("Bluetooth on; scanning");
            } else if (state == BluetoothAdapter.STATE_OFF) {
                scanning = false;
                updateStatus("Bluetooth off; waiting");
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();

        try {
            registerReceiver(
                bluetoothReceiver,
                new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED));
            receiverRegistered = true;
        } catch (Exception e) {
            Log.w(TAG, "Could not watch Bluetooth state: " + e.getMessage());
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();

        if (ACTION_STOP.equals(action)) {
            stopEverything();
            return START_NOT_STICKY;
        }

        if (ACTION_TEST.equals(action)) {
            publishTest();
            return START_STICKY;
        }

        startForeground(NOTIFICATION_ID,
            makeNotification("Starting SensorBridge"));

        if (executor == null) {
            // A sticky restart finds "running" still set: onDestroy did not
            // run, so the process was killed rather than stopped by the user.
            boolean restarted = getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean("running", false);

            synchronized (deviceLock) {
                devices.clear();
            }

            lastStatusMs = 0;
            lastReadingMs = 0;
            lastScanRestartMs = 0;

            getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit()
                .putString("sensors", "")
                .apply();

            executor = Executors.newSingleThreadScheduledExecutor();
            heartbeatExecutor = Executors.newSingleThreadScheduledExecutor();

            updateStatus(restarted
                ? "Service restarted after stopping unexpectedly"
                : "Starting bridge...");

            startBleScan("Scanning; connecting to mqtt");

            // A scheduled task that throws is silently cancelled, which would
            // leave the service alive but dead. Guard both loops.
            executor.scheduleWithFixedDelay(
                () -> guarded("MQTT loop", this::connectMqtt),
                0, 10, TimeUnit.SECONDS
            );

            heartbeatExecutor.scheduleWithFixedDelay(
                () -> guarded("Heartbeat", this::heartbeat),
                0, HEARTBEAT_INTERVAL_S, TimeUnit.SECONDS
            );
        }

        return START_STICKY;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL,
                "SensorBridge",
                NotificationManager.IMPORTANCE_LOW
            );

            channel.setDescription("BLE sensor collection and MQTT status");

            NotificationManager nm =
                (NotificationManager) getSystemService(
                    Context.NOTIFICATION_SERVICE);

            nm.createNotificationChannel(channel);
        }
    }

    private Notification makeNotification(String text) {
        Notification.Builder builder;

        if (Build.VERSION.SDK_INT >= 26) {
            builder = new Notification.Builder(this, CHANNEL);
        } else {
            builder = new Notification.Builder(this);
        }

        String sensors = sensorSummary();

        return builder
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("SensorBridge")
            .setContentText(text)
            .setStyle(new Notification.BigTextStyle().bigText(
                sensors.isEmpty() ? text : text + "\n\n" + sensors))
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop",
                stopServiceIntent())
            .build();
    }

    /** Opens MainActivity when the notification is tapped. */
    private PendingIntent openAppIntent() {
        Intent intent = new Intent(this, MainActivity.class);
        intent.setFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);

        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT
                | PendingIntent.FLAG_IMMUTABLE);
    }

    /** Stops scanning and MQTT from the notification's Stop action. */
    private PendingIntent stopServiceIntent() {
        Intent intent = new Intent(this, SensorService.class);
        intent.setAction(ACTION_STOP);

        return PendingIntent.getService(
            this,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT
                | PendingIntent.FLAG_IMMUTABLE);
    }

    /** Keeps a failing loop from being cancelled for the rest of the day. */
    private void guarded(String name, Runnable task) {
        try {
            task.run();
        } catch (Exception e) {
            Log.e(TAG, name + " failed", e);
            updateStatus(name + " failed: " + e.getMessage());
        }
    }

    /** Records that the service is alive so the UI can detect a dead one. */
    private void heartbeat() {
        long now = System.currentTimeMillis();

        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putLong("heartbeat", now)
            .apply();

        checkScanHealth(now);
    }

    /**
     * Restarts a scan that has gone quiet. Android does not always report a
     * stopped scan, so without this the service looks healthy while no data
     * arrives.
     */
    private void checkScanHealth(long now) {
        if (!scanning) {
            return;
        }

        long last = lastReadingMs;

        if (last == 0
                || now - last < NO_DATA_TIMEOUT_MS
                || now - lastScanRestartMs < NO_DATA_TIMEOUT_MS) {
            return;
        }

        lastScanRestartMs = now;
        updateStatus("No sensor data for 2 min; rescanning");
        restartBleScan("Scanning again; no readings for 2 min");
    }

    private void updateStatus(String value) {
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString("status", value)
            .putBoolean("running", true)
            .apply();

        broadcastStatus(value, sensorSummary());

        NotificationManager nm =
            (NotificationManager) getSystemService(
                Context.NOTIFICATION_SERVICE);

        nm.notify(NOTIFICATION_ID, makeNotification(value));

        Log.i(TAG, value);
    }

    /** One line per detected sensor, e.g. "GVH5075_B6D2: 21.4 C, ...". */
    private String sensorSummary() {
        List<String> lines = new ArrayList<>();

        synchronized (deviceLock) {
            for (Device device : devices.values()) {
                if (device.summary.isEmpty()) {
                    continue;
                }

                lines.add(String.format(Locale.US,
                    "%s: %s (%tT)",
                    device.name,
                    device.summary,
                    device.seenMs));
            }
        }

        Collections.sort(lines);

        StringBuilder sb = new StringBuilder();

        for (String line : lines) {
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(line);
        }

        return sb.toString();
    }

    /** Publishes the per-sensor status to the UI and the notification. */
    private void updateSensors() {
        String sensors = sensorSummary();

        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString("sensors", sensors)
            .putBoolean("running", true)
            .apply();

        String status = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getString("status", "Running");

        broadcastStatus(status, sensors);

        NotificationManager nm =
            (NotificationManager) getSystemService(
                Context.NOTIFICATION_SERVICE);

        nm.notify(NOTIFICATION_ID, makeNotification(status));
    }

    private void broadcastStatus(String status, String sensors) {
        Intent intent = new Intent(STATUS_ACTION);
        intent.setPackage(getPackageName());
        intent.putExtra("status", status);
        intent.putExtra("sensors", sensors);
        sendBroadcast(intent);
    }

    private void startBleScan(String message) {
        if (checkSelfPermission(
                android.Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            updateStatus("Location permission missing");
            return;
        }

        BluetoothManager manager =
            (BluetoothManager) getSystemService(
                Context.BLUETOOTH_SERVICE);

        BluetoothAdapter adapter = manager.getAdapter();

        if (adapter == null || !adapter.isEnabled()) {
            updateStatus("Bluetooth disabled");
            return;
        }

        scanner = adapter.getBluetoothLeScanner();

        if (scanner == null) {
            updateStatus("BLE scanner unavailable");
            return;
        }

        try {
            ScanSettings settings = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build();

            scanner.startScan(null, settings, scanCallback);
            scanning = true;
            lastReadingMs = System.currentTimeMillis();
            updateStatus(message);
        } catch (Exception e) {
            updateStatus("BLE error: " + e.getMessage());
        }
    }

    private void stopBleScan() {
        BluetoothLeScanner current = scanner;

        if (current != null && scanning) {
            try {
                current.stopScan(scanCallback);
            } catch (Exception ignored) {
            }
        }

        scanning = false;
    }

    private void restartBleScan(String message) {
        stopBleScan();
        startBleScan(message);
    }

    private void scheduleScanRetry(String message) {
        ScheduledExecutorService exec = executor;

        if (exec == null) {
            return;
        }

        try {
            exec.schedule(
                () -> startBleScan(message), SCAN_RETRY_DELAY_S, TimeUnit.SECONDS);
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
        }
    }

    /** Decodes, rate-limits and queues a reading for publication. */
    private void publishReading(
            H5075.Reading reading,
            String address,
            String advertisedName,
            int rssi) {

        long now = System.currentTimeMillis();
        String name;
        boolean added = false;

        lastReadingMs = now;

        synchronized (deviceLock) {
            Device device = devices.get(address);

            if (device == null) {
                device = new Device();
                devices.put(address, device);
                added = true;
            }

            name = device.name(advertisedName, address);

            // Each sensor repeats the same advertisement in bursts; do not
            // flood the broker with identical packets from the same device.
            if (reading.raw.equals(device.lastRaw)
                    && now - device.lastPublishMs < MIN_PUBLISH_INTERVAL_MS) {
                return;
            }

            device.lastRaw = reading.raw;
            device.lastPublishMs = now;
            device.summary = String.format(Locale.US,
                "%.1f C, %.1f %%, %d %%",
                reading.temperature,
                reading.humidity,
                reading.battery);
            device.seenMs = now;
        }

        ScheduledExecutorService exec = executor;

        if (exec == null) {
            return;
        }

        String topic = topic();
        String json = reading.toJson(name, address, rssi, now);

        try {
            exec.execute(() -> publish(topic, json));
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
        }

        if (added || now - lastStatusMs >= STATUS_INTERVAL_MS) {
            lastStatusMs = now;
            updateSensors();
        }
    }

    /**
     * Publishes on the MQTT worker thread. Returns false when the broker is
     * not connected or the publish failed; failures drop the client so the
     * reconnect loop starts over.
     */
    private boolean publish(String topic, String json) {
        MqttClient client;

        synchronized (mqttLock) {
            client = mqtt;
        }

        if (client == null || !client.isConnected()) {
            return false;
        }

        try {
            MqttMessage message = new MqttMessage(
                json.getBytes(StandardCharsets.UTF_8));

            message.setQos(0);
            client.publish(topic, message);

            return true;

        } catch (Exception e) {
            Log.w(TAG, "Publish failed: " + e.getMessage());
            discardClient(client);
            updateStatus("mqtt publish failed; reconnecting");
            return false;
        }
    }

    private void connectMqtt() {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        String host = prefs.getString("host", "mqtt");
        String port = prefs.getString("port", "1883");
        String user = prefs.getString("user", "mqttuser");
        String password = prefs.getString("password", "");

        MqttClient client;

        synchronized (mqttLock) {
            if (mqtt != null && mqtt.isConnected()) {
                return;
            }

            if (mqtt == null) {
                try {
                    mqtt = new MqttClient(
                        "tcp://" + host + ":" + port,
                        "SensorBridge-" + UUID.randomUUID(),
                        new MemoryPersistence()
                    );
                } catch (Exception e) {
                    updateStatus("mqtt setup failed: " + e.getMessage());
                    return;
                }
            }

            client = mqtt;
        }

        try {
            MqttConnectOptions options = new MqttConnectOptions();

            options.setCleanSession(true);
            options.setConnectionTimeout(10);
            options.setKeepAliveInterval(30);
            options.setAutomaticReconnect(false);

            if (user != null && !user.isEmpty()) {
                options.setUserName(user);
                options.setPassword(password.toCharArray());
            }

            client.connect(options);

            synchronized (mqttLock) {
                if (mqtt != client) {
                    // Stopped while the connection was being established.
                    try {
                        client.disconnect();
                    } catch (Exception ignored) {
                    }
                    try {
                        client.close();
                    } catch (Exception ignored) {
                    }
                    return;
                }
            }

            updateStatus("Bridge connected to broker " + host);

        } catch (Exception e) {
            discardClient(client);
            updateStatus(host + ": " + e.getMessage());
        }
    }

    /** Detaches and closes a client so the next attempt builds a fresh one. */
    private void discardClient(MqttClient client) {
        synchronized (mqttLock) {
            if (mqtt != client) {
                return;
            }

            mqtt = null;
        }

        try {
            if (client.isConnected()) {
                client.disconnect();
            }
        } catch (Exception ignored) {
        }

        try {
            client.close();
        } catch (Exception ignored) {
        }
    }

    private String mqttHost() {
        return getSharedPreferences(PREFS, MODE_PRIVATE)
            .getString("host", "mqtt");
    }

    private String topic() {
        return getSharedPreferences(PREFS, MODE_PRIVATE)
            .getString("topic", "sensors/govee/H5075");
    }

    /**
     * Payload for the test button. It goes through the normal sensor topic so
     * the whole path is exercised, but uses a reserved name and a
     * {@code "test":true} flag so it is easy to filter out.
     */
    static String testPayload(long timestampMs) {
        return String.format(Locale.US,
            "{\"name\":\"TEST\",\"address\":\"00:00:00:00:00:00\",\"rssi\":0,"
                + "\"temperature\":21.6,\"humidity\":48.2,\"battery\":95,"
                + "\"raw\":\"TEST\",\"timestamp\":%d,\"test\":true}",
            timestampMs);
    }

    private void publishTest() {
        ScheduledExecutorService exec = executor;

        if (exec == null) {
            Log.w(TAG, "Service not running; test not sent");
            return;
        }

        try {
            exec.execute(() -> {
                String topic = topic();

                if (publish(topic, testPayload(System.currentTimeMillis()))) {
                    updateStatus("Test sent to " + topic);

                    try {
                        exec.schedule(
                            () -> updateStatus(
                                "Bridge connected to broker " + mqttHost()),
                            8,
                            TimeUnit.SECONDS);
                    } catch (java.util.concurrent.RejectedExecutionException
                            ignored) {
                    }
                } else {
                    updateStatus("Not connected to mqtt; test not sent");
                }
            });
        } catch (java.util.concurrent.RejectedExecutionException e) {
            Log.w(TAG, "Service stopping; test not sent");
        }
    }

    private void stopEverything() {
        if (receiverRegistered) {
            try {
                unregisterReceiver(bluetoothReceiver);
            } catch (Exception ignored) {
            }

            receiverRegistered = false;
        }

        if (scanner != null && scanning) {
            try {
                scanner.stopScan(scanCallback);
            } catch (Exception ignored) {
            }
        }

        scanning = false;

        synchronized (deviceLock) {
            devices.clear();
        }

        if (executor != null) {
            executor.shutdownNow();
            executor = null;
        }

        if (heartbeatExecutor != null) {
            heartbeatExecutor.shutdownNow();
            heartbeatExecutor = null;
        }

        MqttClient client;

        synchronized (mqttLock) {
            client = mqtt;
            mqtt = null;
        }

        if (client != null) {
            try {
                if (client.isConnected()) {
                    client.disconnect();
                }
            } catch (Exception ignored) {
            }

            try {
                client.close();
            } catch (Exception ignored) {
            }
        }

        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean("running", false)
            .putString("status", "Stopped")
            .putString("sensors", "")
            .apply();

        NotificationManager nm =
            (NotificationManager) getSystemService(
                Context.NOTIFICATION_SERVICE);

        nm.cancel(NOTIFICATION_ID);

        sendBroadcast(new Intent(STATUS_ACTION)
            .setPackage(getPackageName())
            .putExtra("status", "Stopped"));

        stopForeground(true);
        stopSelf();
    }

    @Override
    public void onDestroy() {
        stopEverything();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
