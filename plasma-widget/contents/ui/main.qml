import QtQuick
import QtQuick.Controls as QQC2
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
    property var sides: null
    property var sensorColumnWidths: []
    property var extraList: []
    property var sensorFieldList: []
    property string pendingCommand: ""
    property var pendingNames: []
    property var pendingSides: null
    property var pendingFields: []
    property bool loading: false
    property bool discovering: false
    property bool applyingDiscovery: false
    property string pendingDiscoverCommand: ""
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

        if (key === "title") {
            return cfg.title;
        }

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

        if (key === "sensorFields") {
            return cfg.sensorFields;
        }

        if (key === "extraReadings") {
            return cfg.extraReadings;
        }

        if (key === "outside") {
            return cfg.outside;
        }

        if (key === "boilerHeat") {
            return cfg.boilerHeat;
        }

        if (key === "jfConnections") {
            return cfg.jfConnections;
        }

        if (key === "boilerErrors") {
            return cfg.boilerErrors;
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

    /**
     * Keeps the parsed lists in sync with the effective configuration. When
     * a list changes, drop the values and measured widths that belonged to
     * the old list so a reading is never shown under another reading's label
     * and the side values stay aligned with the sensor columns.
     */
    function refreshDerivedConfig() {
        var nextExtras = Grafana.parseExtraReadings(
            root.configValue("extraReadings"));
        var nextFields = Grafana.parseSensorFields(
            root.configValue("sensorFields"));
        var extrasChanged = JSON.stringify(nextExtras)
            !== JSON.stringify(root.extraList);
        var fieldsChanged = JSON.stringify(nextFields)
            !== JSON.stringify(root.sensorFieldList);

        root.extraList = nextExtras;
        root.sensorFieldList = nextFields;

        if (extrasChanged) {
            root.sides = null;
        }

        if (fieldsChanged) {
            root.sensorColumnWidths = [];
        }
    }

    /** Stores one effective value without touching the other settings. */
    function setSavedValue(key, value) {
        var next = {};
        var saved = root.savedConfig || {};

        for (var name in saved) {
            if (Object.prototype.hasOwnProperty.call(saved, name)) {
                next[name] = saved[name];
            }
        }

        next[key] = value;
        root.savedConfig = next;
    }

    /** Four old settings that used to describe the side readings. */
    function legacyExtraValues(values) {
        var source = values || {};

        return {
            "outside": source.outside !== undefined
                ? source.outside : root.liveConfigValue("outside"),
            "boilerHeat": source.boilerHeat !== undefined
                ? source.boilerHeat : root.liveConfigValue("boilerHeat"),
            "jfConnections": source.jfConnections !== undefined
                ? source.jfConnections : root.liveConfigValue("jfConnections"),
            "boilerErrors": source.boilerErrors !== undefined
                ? source.boilerErrors : root.liveConfigValue("boilerErrors")
        };
    }

    /** Upgrades the four old settings to the ordered extraReadings list. */
    function migrateExtraSettings(values) {
        var existing = values ? values.extraReadings : undefined;

        if (existing !== undefined && String(existing).trim().length > 0) {
            return existing;
        }

        var list = SharedConfig.migrateExtraReadings(
            legacyExtraValues(values));

        return list.length > 0 ? JSON.stringify(list) : existing;
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
        if (!configReadDone || applyingDiscovery) {
            return;
        }

        var saved = root.savedConfig || {};
        var live = liveConfigValue(key);

        // Ignore a change that does not differ from the effective setting:
        // Plasma echoes values that the shared file already supplied, and
        // discovery updates the applet config itself.
        if (Object.prototype.hasOwnProperty.call(saved, key)
                && String(saved[key]) === String(live)) {
            return;
        }

        rememberConfigChange(key);
        refreshDerivedConfig();
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
        var keys = ["title", "grafanaUrl", "dashboardUrl", "apiToken",
            "datasourceUid", "bucket", "measurement", "sensors",
            "sensorFields", "extraReadings", "refreshSeconds", "bypassProxy"];

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
        configWriteSource.connectSource(pendingConfigWrite);
    }

    function readSharedConfig() {
        configReadTimer.start();
        pendingConfigCommand = SharedConfig.readCommand();
        configSource.connectSource(pendingConfigCommand);
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

            var migratedExtras = migrateExtraSettings(parsed.values);

            if (migratedExtras !== undefined) {
                values.extraReadings = migratedExtras;
            }

            savedConfig = values;
            syncPlasmaConfiguration(values);
            refreshDerivedConfig();
        } else {
            var migrated = migrateExtraSettings(null);

            if (migrated !== undefined && String(migrated).trim().length > 0) {
                setSavedValue("extraReadings", migrated);
                Plasmoid.configuration.extraReadings = migrated;
            }

            refreshDerivedConfig();
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
        return Grafana.parseSensorList(configValue("sensors")).names;
    }

    /** Configured sensor columns; empty means discover from the response. */
    function sensorFields() {
        return Grafana.parseSensorFields(configValue("sensorFields"));
    }

    /** Ordered extra readings configured in the shared file. */
    function extraReadings() {
        return Grafana.parseExtraReadings(configValue("extraReadings"));
    }

    /** Reading for one extra reading, or null when no data has arrived. */
    function sideReading(index) {
        var all = root.sides;

        return all && all.length > index ? all[index] : null;
    }

    /** Display text for one extra reading, using its configured format. */
    function sideText(index) {
        var extra = root.extraList[index];
        var reading = root.sideReading(index);

        if (!extra || !reading || reading.missing) {
            return "–";
        }

        return Grafana.formatValue(extra.format, reading.value);
    }

    function hasSides() {
        return root.extraList.length > 0 && root.sides !== null;
    }

    /** Applies each reading's configured colour rule. */
    function sideValueColor(index) {
        var extra = root.extraList[index];
        var reading = root.sideReading(index);

        if (!extra || !reading || reading.missing) {
            return Kirigami.Theme.textColor;
        }

        if (extra.color === "negative" && Number(reading.value) !== 0) {
            return Kirigami.Theme.negativeTextColor;
        }

        if (extra.color === "positive" && Number(reading.value) !== 0) {
            return Kirigami.Theme.positiveTextColor;
        }

        return Kirigami.Theme.textColor;
    }

    /** Keeps the side values aligned with the first sensor row. */
    function reportColumnWidth(rowIndex, columnIndex, width) {
        if (rowIndex !== 0 || width <= 0) {
            return;
        }

        var widths = (root.sensorColumnWidths || []).slice();

        if (widths[columnIndex] === width) {
            return;
        }

        widths[columnIndex] = width;
        root.sensorColumnWidths = widths;
    }

    /**
     * Width of one sensor value column, measured from the first sensor row.
     * The side readings use these widths so their values sit exactly above
     * the sensor values. Falls back to the item's own width when no sensor
     * row has been laid out yet.
     */
    function sideColumnWidth(index, fallback) {
        var widths = root.sensorColumnWidths;

        return widths && widths.length > index && widths[index] > 0
            ? widths[index] : fallback;
    }

    /**
     * Display name for a sensor: an explicit `=Label` from Sensor names
     * replaces the raw name, otherwise the raw name is shown.
     */
    function displaySensorName(name) {
        var labels = Grafana.parseSensorList(configValue("sensors")).labels;

        if (Object.prototype.hasOwnProperty.call(labels, name)) {
            return labels[name];
        }

        return name;
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
        pendingSides = null;
        pendingFields = [];

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
            Grafana.apiUrl(root.grafanaBaseUrl()),
            root.pendingSides, root.pendingFields);

        pendingNames = [];
        root.pendingSides = null;
        root.pendingFields = [];

        // Grafana (or a backend) can briefly answer 5xx; retry a couple of
        // times before showing a hard failure.
        if (result.status >= 500 && retryCount < 2) {
            retryCount += 1;
            readings = result.rows;
            root.sides = result.sides || null;
            errorText = result.error + " " + i18n("Retrying…");
            retryTimer.restart();
            return;
        }

        retryCount = 0;
        readings = result.rows;
        root.sides = result.sides || null;
        errorText = result.error;
    }

    function fetchData() {
        var base = grafanaBaseUrl();
        var names = sensorNames();
        var extras = extraReadings();
        var fields = sensorFields();

        if (base.length === 0) {
            abortRequest();
            loading = false;
            readings = [];
            root.sides = null;
            errorText = i18n("Set the Grafana API URL in the widget settings"
                + " or ~/.config/sensorbridge.");
            return;
        }

        if (Grafana.isPublicDashboardUrl(base)) {
            abortRequest();
            loading = false;
            readings = [];
            root.sides = null;
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
            root.sides = null;
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
            "fields": fields,
            "extras": extras,
            "token": token,
            "bypassProxy": configValue("bypassProxy")
        });

        pendingCommand = command;
        pendingNames = names;
        pendingSides = extras;
        pendingFields = fields;
        loading = true;
        errorText = "";

        // The executable engine runs curl via /bin/sh; the command strips
        // proxy variables and LD_PRELOAD (proxychains) before connecting.
        executableSource.connectSource(command);
    }

    /**
     * Fetches every sensor name in the bucket and saves the result. Labels
     * already present in Sensor names are kept; names that are configured but
     * absent from this response stay in the list so a sleeping sensor is not
     * silently dropped.
     */
    function discoverSensors() {
        var base = grafanaBaseUrl();

        if (!configReadDone || discovering) {
            return;
        }

        if (base.length === 0 || Grafana.isPublicDashboardUrl(base)) {
            fetchData();
            return;
        }

        var token = String(configValue("apiToken") || "").trim();

        if (/^[0-9a-f]{32}$/i.test(token)) {
            fetchData();
            return;
        }

        abortRequest();

        var command = Grafana.buildCurlCommand({
            "grafanaUrl": base,
            "datasourceUid": configValue("datasourceUid"),
            "bucket": configValue("bucket"),
            "measurement": configValue("measurement"),
            "names": [],
            "fields": [],
            "extras": [],
            "token": token,
            "bypassProxy": configValue("bypassProxy")
        });

        pendingDiscoverCommand = command;
        discovering = true;
        errorText = "";
        discoverSource.connectSource(command);
    }

    function applyDiscovery(data) {
        var result = Grafana.parseCurlOutput(data, [],
            Grafana.apiUrl(root.grafanaBaseUrl()), [], []);

        if (result.error.length > 0) {
            errorText = result.error;
            fetchData();
            return;
        }

        var discovered = [];

        for (var i = 0; i < result.rows.length; i++) {
            var name = String(result.rows[i].name || "");

            if (name.length > 0 && name !== "TEST"
                    && discovered.indexOf(name) < 0) {
                discovered.push(name);
            }
        }

        if (discovered.length === 0) {
            errorText = i18n("No sensors found in the configured bucket and"
                + " measurement.");
            fetchData();
            return;
        }

        discovered.sort();

        var current = Grafana.parseSensorList(configValue("sensors"));
        var names = current.names.slice();

        for (var j = 0; j < discovered.length; j++) {
            if (names.indexOf(discovered[j]) < 0) {
                names.push(discovered[j]);
            }
        }

        var entries = [];

        for (var k = 0; k < names.length; k++) {
            entries.push(Object.prototype.hasOwnProperty.call(current.labels,
                names[k]) ? names[k] + "=" + current.labels[names[k]]
                : names[k]);
        }

        var fields = Grafana.deriveSensorFields(result.rows,
            Grafana.parseSensorFields(configValue("sensorFields")));
        var next = {
            "sensors": entries.join(","),
            "sensorFields": JSON.stringify(fields)
        };

        setSavedValue("sensors", next.sensors);
        setSavedValue("sensorFields", next.sensorFields);

        // Plasma's copy keeps the Configure dialog in step. Its change
        // handlers are skipped here so discovery saves and refreshes once.
        applyingDiscovery = true;
        Plasmoid.configuration.sensors = next.sensors;
        Plasmoid.configuration.sensorFields = next.sensorFields;
        applyingDiscovery = false;

        refreshDerivedConfig();
        configWriteTimer.restart();
        fetchData();
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
        id: discoverSource
        engine: "executable"
        connectedSources: []

        onNewData: function (sourceName, data) {
            if (sourceName !== root.pendingDiscoverCommand) {
                return;
            }

            root.pendingDiscoverCommand = "";
            discoverSource.disconnectSource(sourceName);
            root.discovering = false;
            root.applyDiscovery(data);
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

    Component.onCompleted: {
        root.refreshDerivedConfig();
        Qt.callLater(root.readSharedConfig);
    }

    Connections {
        target: Plasmoid.configuration

        // Changes before the file has been read are Plasma populating the
        // applet, not edits. Let the read decide which values win.
        function onTitleChanged() {
            root.applyConfigChange("title");
        }

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

        function onSensorFieldsChanged() {
            root.applyConfigChange("sensorFields");
        }

        function onExtraReadingsChanged() {
            root.applyConfigChange("extraReadings");
        }

        function onOutsideChanged() {
            root.applyConfigChange("outside");
        }

        function onBoilerHeatChanged() {
            root.applyConfigChange("boilerHeat");
        }

        function onJfConnectionsChanged() {
            root.applyConfigChange("jfConnections");
        }

        function onBoilerErrorsChanged() {
            root.applyConfigChange("boilerErrors");
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
        property color valueColor: Kirigami.Theme.textColor
        property int valueAlignment: Qt.AlignLeft
        property int labelAlignment: Qt.AlignLeft

        spacing: 0

        PlasmaComponents3.Label {
            text: metric.value
            color: metric.valueColor
            font.bold: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.25
            horizontalAlignment: metric.valueAlignment
            Layout.fillWidth: true
        }

        PlasmaComponents3.Label {
            text: metric.label
            color: Kirigami.Theme.disabledTextColor
            font: Kirigami.Theme.smallFont
            horizontalAlignment: metric.labelAlignment
            Layout.fillWidth: true
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
                    text: String(root.configValue("title")
                        || Plasmoid.title || "")
                    font.bold: true
                    font.pointSize:
                        Kirigami.Theme.defaultFont.pointSize * 1.1
                    Layout.fillWidth: true
                }

                PlasmaComponents3.BusyIndicator {
                    visible: root.loading || root.discovering
                    running: root.loading || root.discovering
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "edit-find"
                    Accessible.name: i18n("Discover sensors")
                    QQC2.ToolTip.text: i18n("Discover every sensor and save"
                        + " the list to the settings")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 500
                    enabled: root.configReadDone && !root.loading
                        && !root.discovering
                    onClicked: root.discoverSensors()
                }

                PlasmaComponents3.ToolButton {
                    icon.name: "view-refresh"
                    Accessible.name: i18n("Refresh")
                    QQC2.ToolTip.text: i18n("Refresh")
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 500
                    enabled: !root.loading && !root.discovering
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

            ColumnLayout {
                visible: root.hasSides()
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Repeater {
                        model: root.extraList

                        delegate: Metric {
                            Layout.preferredWidth: root.sideColumnWidth(
                                index, implicitWidth)
                            value: root.sideText(index)
                            valueColor: root.sideValueColor(index)
                            valueAlignment: modelData.align === "right"
                                ? Qt.AlignRight : Qt.AlignLeft
                            labelAlignment: modelData.align === "right"
                                ? Qt.AlignRight : Qt.AlignLeft
                            label: modelData.label
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }
            }

            Rectangle {
                visible: root.hasSides() && root.readings.length > 0
                Layout.fillWidth: true
                implicitHeight: 1
                color: Kirigami.Theme.textColor
                opacity: 0.15
            }

            Repeater {
                model: root.readings

                delegate: ColumnLayout {
                    id: sensorRow

                    property int rowIndex: index

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
                            text: root.displaySensorName(modelData.name)
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

                        Repeater {
                            model: modelData.columns

                            delegate: Metric {
                                value: Grafana.formatValue(
                                    modelData.format, modelData.value)
                                label: modelData.label
                                valueAlignment: modelData.align === "right"
                                    ? Qt.AlignRight : Qt.AlignLeft
                                labelAlignment: modelData.align === "right"
                                    ? Qt.AlignRight : Qt.AlignLeft

                                Component.onCompleted: root.reportColumnWidth(
                                    sensorRow.rowIndex, index, implicitWidth)
                                onImplicitWidthChanged: root.reportColumnWidth(
                                    sensorRow.rowIndex, index, implicitWidth)
                            }
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
