package com.whatamesss.sensorbridge;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.bluetooth.BluetoothAdapter;
import android.content.ActivityNotFoundException;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.View;
import android.widget.*;

public class MainActivity extends Activity {

    private static final int REQUEST_LOCATION = 100;

    private EditText host, port, username, password, topic;
    private TextView status;
    private TextView sensors;
    private Button runButton;
    private TextView batteryStatus;
    private Button batteryButton;
    private boolean batteryPromptShown = false;

    private SharedPreferences prefs;

    private final BroadcastReceiver statusReceiver =
        new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String value = intent.getStringExtra("status");
                if (value != null) showStatus(value);
                showSensors(intent.getStringExtra("sensors"));
            }
        };

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);

        prefs = getSharedPreferences("sensorbridge", MODE_PRIVATE);

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(20, 16, 20, 16);

        TextView title = new TextView(this);
        title.setText("SensorBridge");
        title.setTextSize(26);
        layout.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("Govee H5075  |  BLE to MQTT");
        layout.addView(subtitle);

        status = new TextView(this);
        status.setTextSize(16);
        status.setPadding(0, 18, 0, 12);
        layout.addView(status);

        // One line per detected sensor, e.g. "GVH5075_B6D2: 21.4 C, ...".
        sensors = new TextView(this);
        sensors.setTextSize(15);
        sensors.setPadding(0, 0, 0, 12);
        sensors.setVisibility(View.GONE);
        layout.addView(sensors);

        runButton = new Button(this);
        layout.addView(runButton);
        runButton.setOnClickListener(v -> toggleService());

        Button testButton = new Button(this);
        testButton.setText("Publish Test Reading");
        layout.addView(testButton);
        testButton.setOnClickListener(v -> publishTest());

        batteryStatus = new TextView(this);
        batteryStatus.setTextSize(14);
        batteryStatus.setPadding(0, 14, 0, 6);
        layout.addView(batteryStatus);

        batteryButton = new Button(this);
        batteryButton.setText("Disable Battery Optimization");
        layout.addView(batteryButton);
        batteryButton.setOnClickListener(
            v -> requestIgnoreBatteryOptimizations());

        TextView settingsTitle = new TextView(this);
        settingsTitle.setText("\nMQTT Settings");
        settingsTitle.setTextSize(20);
        layout.addView(settingsTitle);

        host = addField(layout, "Broker hostname", "mqtt");
        port = addField(layout, "Port", "1883");
        username = addField(layout, "Username", "mqttuser");
        password = addField(layout, "Password", "");
        password.setInputType(
            android.text.InputType.TYPE_CLASS_TEXT |
            android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        );
        topic = addField(layout, "Publish topic",
            "sensors/govee/H5075");

        Button saveButton = new Button(this);
        saveButton.setText("Save MQTT Settings");
        layout.addView(saveButton);
        saveButton.setOnClickListener(v -> saveSettings());

        TextView note = new TextView(this);
        note.setText(
            "\nThe background service continues scanning " +
            "and maintaining MQTT while this screen is closed."
        );
        layout.addView(note);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(layout);
        setContentView(scroll);

        loadSettings();
        refreshServiceState();
    }

    private EditText addField(
        LinearLayout parent, String label, String defaultValue) {

        TextView text = new TextView(this);
        text.setText(label);
        parent.addView(text);

        EditText field = new EditText(this);
        field.setSingleLine(true);
        field.setText(defaultValue);
        parent.addView(field);

        return field;
    }

    private void loadSettings() {
        host.setText(prefs.getString("host", "mqtt"));
        port.setText(prefs.getString("port", "1883"));
        username.setText(prefs.getString("user", "mqttuser"));
        password.setText(prefs.getString("password", ""));
        topic.setText(prefs.getString(
            "topic", "sensors/govee/H5075"));
    }

    private void saveSettings() {
        prefs.edit()
            .putString("host", host.getText().toString().trim())
            .putString("port", port.getText().toString().trim())
            .putString("user", username.getText().toString().trim())
            .putString("password", password.getText().toString())
            .putString("topic", topic.getText().toString().trim())
            .apply();

        showStatus("Settings saved.");
    }

    private void toggleService() {
        boolean running = serviceRunning();

        if (running) {
            Intent intent = new Intent(this, SensorService.class);
            intent.setAction(SensorService.ACTION_STOP);
            startService(intent);
            return;
        }

        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(
                new String[]{Manifest.permission.ACCESS_FINE_LOCATION},
                REQUEST_LOCATION);
            return;
        }

        saveSettings();

        Intent intent = new Intent(this, SensorService.class);
        intent.setAction(SensorService.ACTION_START);

        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }

        showStatus("Starting background service...");
        runButton.setText("Stop SensorBridge");
    }

    @Override
    public void onRequestPermissionsResult(
        int requestCode, String[] permissions, int[] results) {

        super.onRequestPermissionsResult(
            requestCode, permissions, results);

        if (requestCode == REQUEST_LOCATION &&
            results.length > 0 &&
            results[0] == PackageManager.PERMISSION_GRANTED) {
            toggleService();
        } else {
            showStatus("Location permission is required for BLE scanning.");
        }
    }

    private void publishTest() {
        if (!serviceRunning()) {
            showStatus("Start SensorBridge before publishing a test.");
            return;
        }

        Intent intent = new Intent(this, SensorService.class);
        intent.setAction(SensorService.ACTION_TEST);
        startService(intent);
    }

    /** True when Android will not throttle the app in the background. */
    private boolean ignoringBatteryOptimizations() {
        PowerManager pm =
            (PowerManager) getSystemService(Context.POWER_SERVICE);

        return pm == null
            || pm.isIgnoringBatteryOptimizations(getPackageName());
    }

    /** Refreshes the battery state and prompts once per launch if needed. */
    private void checkBatteryOptimization() {
        boolean ignoring = ignoringBatteryOptimizations();

        batteryStatus.setText(ignoring
            ? "Battery optimization is disabled for SensorBridge."
            : "Battery optimization is on; the bridge may pause when idle.");
        batteryButton.setVisibility(ignoring ? View.GONE : View.VISIBLE);

        if (!ignoring && !batteryPromptShown) {
            batteryPromptShown = true;

            new AlertDialog.Builder(this)
                .setTitle("Disable battery optimization")
                .setMessage(
                    "Android may suspend the bridge while the screen is off. "
                        + "Allow SensorBridge to run in the background?")
                .setPositiveButton("Open settings",
                    (dialog, which) -> requestIgnoreBatteryOptimizations())
                .setNegativeButton("Not now", null)
                .show();
        }
    }

    /** Asks the system to exempt this app from Doze / App Standby. */
    private void requestIgnoreBatteryOptimizations() {
        try {
            Intent intent = new Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:" + getPackageName()));

            startActivity(intent);
        } catch (ActivityNotFoundException e) {
            // Some builds have no direct request screen; fall back to the list.
            try {
                startActivity(new Intent(
                    Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (ActivityNotFoundException ignored) {
                showStatus("Battery optimization settings unavailable.");
            }
        }
    }

    private void showStatus(String value) {
        status.setText("Status: " + value);
        refreshButton();
    }

    /** Shows the per-sensor lines the service broadcasts. */
    private void showSensors(String value) {
        if (value == null || value.isEmpty()) {
            sensors.setText("");
            sensors.setVisibility(View.GONE);
            return;
        }

        sensors.setText(value);
        sensors.setVisibility(View.VISIBLE);
    }

    private void refreshServiceState() {
        if (serviceRunning()) {
            showStatus(prefs.getString("status", "Stopped"));
            showSensors(prefs.getString("sensors", ""));
        } else {
            showStatus("Stopped");
            showSensors(null);
        }
    }

    /**
     * True only when the service stamped a heartbeat recently. The saved
     * "running" flag alone keeps showing "connected" after a reboot or an app
     * update kills the service without running its {@code onDestroy}.
     */
    private boolean serviceRunning() {
        if (!prefs.getBoolean("running", false)) {
            return false;
        }

        long age =
            System.currentTimeMillis() - prefs.getLong("heartbeat", 0);

        return age < SensorService.HEARTBEAT_STALE_MS;
    }

    private void refreshButton() {
        runButton.setText(serviceRunning()
            ? "STOP SENSORBRIDGE"
            : "START SENSORBRIDGE");
    }

    @Override
    protected void onResume() {
        super.onResume();

        registerReceiver(
            statusReceiver,
            new IntentFilter(SensorService.STATUS_ACTION)
        );

        refreshServiceState();
        checkBatteryOptimization();
    }

    @Override
    protected void onPause() {
        try {
            unregisterReceiver(statusReceiver);
        } catch (Exception ignored) {}

        super.onPause();
    }
}
