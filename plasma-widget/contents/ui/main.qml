import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "../js/grafana.js" as Grafana
import "../js/sharedconfig.js" as SharedConfig

PlasmoidItem {
    id: root

    property var readings: []
    property string pendingCommand: ""
    property var pendingNames: []
    property bool loading: false
    property string errorText: ""
    property int retryCount: 0
    property real nowMs: Date.now()

    // Settings read from ~/.config/sensorbridge at launch. Empty when the
    // file is absent; values from it win over the applet's own (instance-bound)
    // configuration. A Configure edit updates both copies and is written back
    // to the file, but only after an explicit user edit.
    property var savedConfig: ({})
    property bool configReadDone: false
    property bool configReadSucceeded: false
    property string pendingConfigCommand: ""
    property string pendingConfigWrite: ""

    // -------------------------------------------------------------- config

    /** Reads a setting from the applet's own Plasma configuration. */
    function liveConfigValue(key) {
        var cfg = Plasmoid.configuration;

        if (key === "grafanaUrl") {
            return cfg.grafanaUrl;
        }

        if (key === "dashboardUrl") {
            return cfg.dashboardUrl;
        }

        if (key === "apiToken") {
            return cfg.apiToken;
        }

        if (key === "datasourceUid") {
            return cfg.datasourceUid;
        }

        if (key === "bucket") {
            return cfg.bucket;
        }

        if (key === "measurement") {
            return cfg.measurement;
        }

        if (key === "sensors") {
            return cfg.sensors;
        }

        if (key === "refreshSeconds") {
            return cfg.refreshSeconds;
        }

        if (key === "bypassProxy") {
            return cfg.bypassProxy;
        }

        return undefined;
    }

    /**
     * Value to use for a setting: the shared file when it defines the key,
     * otherwise the applet's own Plasma configuration. A setting changed in
     * Configure is kept in savedConfig for this session and written to the
     * file by writeSharedConfig().
     */
    function configValue(key) {
        var saved = root.savedConfig || {};

        return Object.prototype.hasOwnProperty.call(saved, key)
            ? saved[key] : liveConfigValue(key);
    }

    /** Makes a setting changed in the applet config win over the file. */
    function rememberConfigChange(key) {
        var next = {};
        var saved = root.savedConfig || {};

        for (var name in saved) {
            if (Object.prototype.hasOwnProperty.call(saved, name)) {
                next[name] = saved[name];
            }
        }

        next[key] = liveConfigValue(key);
        root.savedConfig = next;
    }

    /** Called for a real settings edit after the launch read finished. */
    function applyConfigChange(key) {
        if (!configReadDone) {
            return;
        }

        rememberConfigChange(key);
        configWriteTimer.restart();
        fetchData();
    }

    /**
     * Mirrors file values into Plasma's applet config so the Configure dialog
     * shows the settings actually in use. It runs at launch only; the change
     * signals it causes are ignored because configReadDone is still false.
     */
    function syncPlasmaConfiguration(values) {
        var cfg = Plasmoid.configuration;
        var keys = ["grafanaUrl", "dashboardUrl", "apiToken", "datasourceUid",
            "bucket", "measurement", "sensors", "refreshSeconds",
            "bypassProxy"];

        for (var i = 0; i < keys.length; i++) {
            if (Object.prototype.hasOwnProperty.call(values, keys[i])) {
                cfg[keys[i]] = values[keys[i]];
            }
        }
    }

    /** Saves the effective settings to ~/.config/sensorbridge. */
    function writeSharedConfig() {
        // Never save after a failed launch read: the untouched keys would be
        // Plasma defaults and could overwrite a file that was merely slow.
        if (!configReadDone || !configReadSucceeded) {
            return;
        }

        var values = {};

        for (var i = 0; i < SharedConfig.KEYS.length; i++) {
            var key = SharedConfig.KEYS[i];

            values[key] = configValue(key);
        }

        if (pendingConfigWrite.length > 0) {
            try {
                configWriteSource.disconnectSource(pendingConfigWrite);
            } catch (e) {
            }
        }

        pendingConfigWrite = SharedConfig.writeCommand(values);
        configWriteSource.connectSource(pendingConfigWrite, 0);
    }

    function readSharedConfig() {
        configReadTimer.start();
        pendingConfigCommand = SharedConfig.readCommand();
        configSource.connectSource(pendingConfigCommand, 0);
    }

    function applySharedConfig(stdout) {
        if (configReadDone) {
            return;
        }

        var parsed = SharedConfig.parseReadOutput(stdout);

        if (SharedConfig.hasSavedConfig(parsed)) {
            var values = {};
            // An empty URL/datasource/bucket/measurement is never usable and
            // is usually what an older build wrote when it had nothing to
            // save. Let Plasma's copy show through instead of blanking the
            // widget. An empty token (anonymous) and an empty sensor list
            // (show all) are meaningful, so they are kept.
            var required = ["grafanaUrl", "datasourceUid", "bucket",
                "measurement"];

            for (var i = 0; i < SharedConfig.KEYS.length; i++) {
                var key = SharedConfig.KEYS[i];
                var value = parsed.values[key];

                if (value !== undefined
                        && (required.indexOf(key) < 0 || value.length > 0)) {
                    values[key] = value;
                }
            }

            if (values.refreshSeconds !== undefined) {
                values.refreshSeconds =
                    parseInt(values.refreshSeconds, 10) || 60;
            }

            if (values.bypassProxy !== undefined) {
                values.bypassProxy =
                    SharedConfig.parseBool(values.bypassProxy, true);
            }

            savedConfig = values;
            syncPlasmaConfiguration(values);
        }

        configReadSucceeded = true;
        configReadDone = true;
        configReadTimer.stop();
        refreshTimer.restart();
        Qt.callLater(root.fetchData);
    }

    /** Carry on with Plasma's configuration if the read never returns. */
    function finishConfigRead() {
        if (configReadDone) {
            return;
        }

        if (pendingConfigCommand.length > 0) {
            try {
                configSource.disconnectSource(pendingConfigCommand);
            } catch (e) {
            }

            pendingConfigCommand = "";
        }

        configReadDone = true;
        Qt.callLater(root.fetchData);
    }

    // ---------------------------------------------------------------- data

    function sensorNames() {
        var raw = String(configValue("sensors") || "");
        var parts = raw.split(",");
        var names = [];

        for (var i = 0; i < parts.length; i++) {
            var name = parts[i].trim();

            if (name.length > 0 && names.indexOf(name) < 0) {
                names.push(name);
            }
        }

        return names;
    }

    function grafanaBaseUrl() {
        return Grafana.normalizeBaseUrl(configValue("grafanaUrl"));
    }

    function openInBrowser() {
        // A dashboard page can live below the API base URL, so prefer the
        // optional Dashboard URL and fall back to the Grafana API URL.
        var dashboard = String(configValue("dashboardUrl") || "").trim();
        var target = dashboard.length > 0
            ? dashboard : configValue("grafanaUrl");
        var url = Grafana.browserUrl(target);

        if (url.length === 0) {
            errorText = i18n("Set a valid http:// or https:// Dashboard URL"
                + " or Grafana API URL in the widget settings or"
                + " ~/.config/sensorbridge before opening it.");
            return;
        }

        Qt.openUrlExternally(url);
    }

    function abortRequest() {
        var command = pendingCommand;

        pendingCommand = "";

        if (command.length > 0) {
            try {
                executableSource.disconnectSource(command);
            } catch (e) {
            }
        }
    }

    function handleResponse(data) {
        loading = false;
        nowMs = Date.now();

        var result = Grafana.parseCurlOutput(data, pendingNames,
            Grafana.apiUrl(root.grafanaBaseUrl()));

        pendingNames = [];

        // Grafana (or a backend) can briefly answer 5xx; retry a couple of
        // times before showing a hard failure.
        if (result.status >= 500 && retryCount < 2) {
            retryCount += 1;
            readings = result.rows;
            errorText = result.error + " " + i18n("Retrying…");
            retryTimer.restart();
            return;
        }

        retryCount = 0;
        readings = result.rows;
        errorText = result.error;
    }

    function fetchData() {
        var base = grafanaBaseUrl();
        var names = sensorNames();

        if (base.length === 0) {
            abortRequest();
            loading = false;
            readings = [];
            errorText = i18n("Set the Grafana API URL in the widget settings"
                + " or ~/.config/sensorbridge.");
            return;
        }

        if (Grafana.isPublicDashboardUrl(base)) {
            abortRequest();
            loading = false;
            readings = [];
            errorText = i18n("Use the Grafana API base URL"
                + " (http://grafana:3000), not a public dashboard link."
                + " Public dashboard share tokens cannot query /api/ds/query"
                + " — use a Grafana service account token instead.");
            return;
        }

        var token = String(configValue("apiToken") || "").trim();

        if (/^[0-9a-f]{32}$/i.test(token)) {
            abortRequest();
            loading = false;
            readings = [];
            errorText = i18n("The configured token is a public dashboard"
                + " share token, not a Grafana API token. Create a service"
                + " account token with the Viewer role and paste that into"
                + " the widget settings.");
            return;
        }

        abortRequest();

        var command = Grafana.buildCurlCommand({
            "grafanaUrl": base,
            "datasourceUid": configValue("datasourceUid"),
            "bucket": configValue("bucket"),
            "measurement": configValue("measurement"),
            "names": names,
            "token": token,
            "bypassProxy": configValue("bypassProxy")
        });

        pendingCommand = command;
        pendingNames = names;
        loading = true;
        errorText = "";

        // The executable engine runs curl via /bin/sh; the command strips
        // proxy variables and LD_PRELOAD (proxychains) before connecting.
        executableSource.connectSource(command, 0);
    }

    P5Support.DataSource {
        id: executableSource
        engine: "executable"
        connectedSources: []

        onNewData: function (sourceName, data) {
            if (sourceName !== root.pendingCommand) {
                return;
            }

            root.pendingCommand = "";
            executableSource.disconnectSource(sourceName);
            root.handleResponse(data);
        }
    }

    P5Support.DataSource {
        id: configSource
        engine: "executable"
        connectedSources: []

        onNewData: function (sourceName, data) {
            if (sourceName !== root.pendingConfigCommand) {
                return;
            }

            root.pendingConfigCommand = "";
            configSource.disconnectSource(sourceName);
            root.applySharedConfig(
                data && data.stdout !== undefined ? data.stdout : "");
        }
    }

    P5Support.DataSource {
        id: configWriteSource
        engine: "executable"
        connectedSources: []

        onNewData: function (sourceName, data) {
            if (sourceName !== root.pendingConfigWrite) {
                return;
            }

            root.pendingConfigWrite = "";
            configWriteSource.disconnectSource(sourceName);

            if (data && data["exit code"] !== undefined
                    && Number(data["exit code"]) !== 0) {
                console.warn("SensorBridge: could not save settings to"
                    + " ~/.config/sensorbridge:"
                    + (data.stderr ? " " + data.stderr : ""));
            }
        }
    }

    Component.onCompleted: Qt.callLater(root.readSharedConfig)

    Connections {
        target: Plasmoid.configuration

        // Changes before the file has been read are Plasma populating the
        // applet, not edits. Let the read decide which values win.
        function onGrafanaUrlChanged() {
            root.applyConfigChange("grafanaUrl");
        }

        function onDashboardUrlChanged() {
            root.applyConfigChange("dashboardUrl");
        }

        function onApiTokenChanged() {
            root.applyConfigChange("apiToken");
        }

        function onDatasourceUidChanged() {
            root.applyConfigChange("datasourceUid");
        }

        function onBucketChanged() {
            root.applyConfigChange("bucket");
        }

        function onMeasurementChanged() {
            root.applyConfigChange("measurement");
        }

        function onSensorsChanged() {
            root.applyConfigChange("sensors");
        }

        function onBypassProxyChanged() {
            root.applyConfigChange("bypassProxy");
        }

        function onRefreshSecondsChanged() {
            root.applyConfigChange("refreshSeconds");
            root.nowMs = Date.now();
            refreshTimer.restart();
        }
    }

    Timer {
        id: configReadTimer
        interval: 3000
        repeat: false
        onTriggered: root.finishConfigRead()
    }

    // One save per Apply, even when it changes several fields.
    Timer {
        id: configWriteTimer
        interval: 300
        repeat: false
        onTriggered: root.writeSharedConfig()
    }

    Timer {
        id: refreshTimer
        running: true
        repeat: true
        interval: Math.max(10,
            Number(root.configValue("refreshSeconds")) || 60) * 1000
        onTriggered: root.fetchData()
    }

    Timer {
        id: retryTimer
        interval: 3000
        repeat: false
        onTriggered: root.fetchData()
    }

    Timer {
        id: ageTimer
        running: true
        repeat: true
        interval: 30000
        onTriggered: {
            root.nowMs = Date.now();
        }
    }

    // ------------------------------------------------------------- full

    component Metric: ColumnLayout {
        id: metric

        property string value: "–"
        property string label: ""

        spacing: 0

        PlasmaComponents3.Label {
            text: metric.value
            font.bold: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.25
        }

        PlasmaComponents3.Label {
            text: metric.label
            color: Kirigami.Theme.disabledTextColor
            font: Kirigami.Theme.smallFont
        }
    }

    fullRepresentation: Item {
        id: full

        implicitWidth: Kirigami.Units.gridUnit * 22
        implicitHeight: content.implicitHeight
            + Kirigami.Units.largeSpacing * 2

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onDoubleClicked: root.openInBrowser()
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: i18n("SensorBridge")
                    font.bold: true
                    font.pointSize:
                        Kirigami.Theme.defaultFont.pointSize * 1.1
                    Layout.fillWidth: true
                }

                PlasmaComponents3.BusyIndicator {
                    visible: root.loading
                    running: root.loading
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "view-refresh"
                    enabled: !root.loading
                    onClicked: root.fetchData()
                }
            }

            PlasmaComponents3.Label {
                visible: root.errorText.length > 0
                text: root.errorText
                color: Kirigami.Theme.negativeTextColor
                font: Kirigami.Theme.smallFont
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            Repeater {
                model: root.readings

                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        visible: index > 0
                        Layout.fillWidth: true
                        implicitHeight: 1
                        color: Kirigami.Theme.textColor
                        opacity: 0.15
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            text: Grafana.sensorDisplayName(modelData.name)
                            font.bold: true
                            elide: Text.ElideMiddle
                            Layout.fillWidth: true
                        }

                        PlasmaComponents3.Label {
                            text: modelData.missing
                                ? i18n("no data")
                                : Grafana.formatAge(
                                    modelData.timestamp, root.nowMs)
                            color: Kirigami.Theme.disabledTextColor
                            font: Kirigami.Theme.smallFont
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        Metric {
                            value: Grafana.formatTemperature(
                                modelData.temperature)
                            label: i18n("Temperature")
                        }

                        Metric {
                            value: Grafana.formatHumidity(
                                modelData.humidity)
                            label: i18n("Humidity")
                        }

                        Metric {
                            value: Grafana.formatTemperature(
                                Grafana.dewPoint(modelData.temperature,
                                    modelData.humidity))
                            label: i18n("Dew point")
                        }

                        Metric {
                            value: Grafana.formatBattery(
                                modelData.battery)
                            label: i18n("Battery")
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }
                }
            }

            PlasmaComponents3.Label {
                visible: root.readings.length === 0
                    && root.errorText.length === 0
                text: i18n("Waiting for data…")
                color: Kirigami.Theme.disabledTextColor
                font: Kirigami.Theme.smallFont
            }
        }
    }
}
