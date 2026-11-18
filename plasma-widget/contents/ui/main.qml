import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import "../js/grafana.js" as Grafana

PlasmoidItem {
    id: root

    preferredRepresentation: fullRepresentation

    property var readings: []
    property string pendingCommand: ""
    property var pendingNames: []
    property bool loading: false
    property string errorText: ""
    property int retryCount: 0
    property real nowMs: Date.now()

    toolTipMainText: i18n("SensorBridge")
    toolTipSubText: ""

    // ---------------------------------------------------------------- data

    function sensorNames() {
        var raw = String(Plasmoid.configuration.sensors || "");
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
        return Grafana.normalizeBaseUrl(Plasmoid.configuration.grafanaUrl);
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
            updateToolTip();
            retryTimer.restart();
            return;
        }

        retryCount = 0;
        readings = result.rows;
        errorText = result.error;
        updateToolTip();
    }

    function fetchData() {
        var base = grafanaBaseUrl();
        var cfg = Plasmoid.configuration;
        var names = sensorNames();

        if (base.length === 0) {
            abortRequest();
            loading = false;
            readings = [];
            errorText = i18n("Set the Grafana URL in the widget settings.");
            updateToolTip();
            return;
        }

        if (Grafana.isPublicDashboardUrl(base)) {
            abortRequest();
            loading = false;
            readings = [];
            errorText = i18n("Use the Grafana base URL (http://grafana:3000),"
                + " not a public dashboard link. Public dashboard share"
                + " tokens cannot query /api/ds/query — use a Grafana service"
                + " account token instead.");
            updateToolTip();
            return;
        }

        var token = String(cfg.apiToken || "").trim();

        if (/^[0-9a-f]{32}$/i.test(token)) {
            abortRequest();
            loading = false;
            readings = [];
            errorText = i18n("The configured token is a public dashboard"
                + " share token, not a Grafana API token. Create a service"
                + " account token with the Viewer role and paste that into"
                + " the widget settings.");
            updateToolTip();
            return;
        }

        abortRequest();

        var command = Grafana.buildCurlCommand({
            "grafanaUrl": base,
            "datasourceUid": cfg.datasourceUid,
            "bucket": cfg.bucket,
            "measurement": cfg.measurement,
            "names": names,
            "token": token,
            "bypassProxy": cfg.bypassProxy
        });

        pendingCommand = command;
        pendingNames = names;
        loading = true;
        errorText = "";

        // The executable engine runs curl via /bin/sh; the command strips
        // proxy variables and LD_PRELOAD (proxychains) before connecting.
        executableSource.connectSource(command, 0);
    }

    function updateToolTip() {
        var lines = [];

        for (var i = 0; i < readings.length; i++) {
            var row = readings[i];

            if (row.missing) {
                lines.push(row.name + ": " + i18n("no data"));
                continue;
            }

            lines.push(row.name + ": "
                + Grafana.formatTemperature(row.temperature) + ", "
                + Grafana.formatHumidity(row.humidity) + ", "
                + Grafana.formatBattery(row.battery) + " ("
                + Grafana.formatAge(row.timestamp, nowMs) + ")");
        }

        if (errorText.length > 0) {
            lines.push(errorText);
        }

        toolTipSubText = lines.join("\n");
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

    Component.onCompleted: Qt.callLater(root.fetchData)

    Connections {
        target: Plasmoid.configuration

        function onGrafanaUrlChanged() {
            root.fetchData();
        }

        function onApiTokenChanged() {
            root.fetchData();
        }

        function onDatasourceUidChanged() {
            root.fetchData();
        }

        function onBucketChanged() {
            root.fetchData();
        }

        function onMeasurementChanged() {
            root.fetchData();
        }

        function onSensorsChanged() {
            root.fetchData();
        }

        function onRefreshSecondsChanged() {
            root.nowMs = Date.now();
        }
    }

    Timer {
        id: refreshTimer
        running: true
        repeat: true
        interval: Math.max(10,
            Number(Plasmoid.configuration.refreshSeconds) || 60) * 1000
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
            root.updateToolTip();
        }
    }

    // ----------------------------------------------------------- compact

    compactRepresentation: MouseArea {
        id: compact

        readonly property var firstReading:
            root.readings.length > 0 ? root.readings[0] : null

        implicitWidth: compactRow.implicitWidth
            + Kirigami.Units.smallSpacing * 2
        implicitHeight: compactRow.implicitHeight
            + Kirigami.Units.smallSpacing * 2

        RowLayout {
            id: compactRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "weather-temperature"
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: Kirigami.Units.iconSizes.small
            }

            PlasmaComponents3.Label {
                text: compact.firstReading && !compact.firstReading.missing
                    ? Grafana.formatTemperature(
                        compact.firstReading.temperature)
                    : "–"
            }
        }

        onClicked: root.expanded = !root.expanded
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

        implicitWidth: Kirigami.Units.gridUnit * 18
        implicitHeight: content.implicitHeight
            + Kirigami.Units.largeSpacing * 2

        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight
        Layout.minimumWidth: Kirigami.Units.gridUnit * 12
        Layout.minimumHeight: implicitHeight

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

                    PlasmaComponents3.ToolTip {
                        text: i18n("Refresh now")
                    }
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
                            text: modelData.name
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
