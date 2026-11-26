import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "../js/grafana.js" as Grafana

Kirigami.FormLayout {
    id: page

    property alias cfg_title: titleField.text
    property alias cfg_grafanaUrl: urlField.text
    property alias cfg_dashboardUrl: dashboardField.text
    property alias cfg_apiToken: tokenField.text
    property bool looksLikeShareToken:
        /^[0-9a-f]{32}$/i.test(String(tokenField.text).trim())
    property alias cfg_datasourceUid: datasourceField.text
    property alias cfg_bucket: bucketField.text
    property alias cfg_measurement: measurementField.text
    property alias cfg_sensors: sensorsField.text
    property alias cfg_refreshSeconds: refreshSpin.value
    property alias cfg_bypassProxy: proxyCheck.checked

    // These two are JSON arrays so an ordered, arbitrary set of readings and
    // columns can live in ~/.config/sensorbridge instead of in the QML.
    property string cfg_sensorFields: ""
    property string cfg_extraReadings: ""

    property var fieldRows: []
    property var extraRows: []
    property var formats: Grafana.FORMATS
    property var colors: Grafana.COLORS
    property var alignments: Grafana.ALIGNMENTS
    property bool applyingEditor: false

    onCfg_sensorFieldsChanged: {
        if (!page.applyingEditor && page.fieldRows.length === 0) {
            page.fieldRows = Grafana.parseSensorFields(page.cfg_sensorFields);
        }
    }

    onCfg_extraReadingsChanged: {
        if (!page.applyingEditor && page.extraRows.length === 0) {
            page.extraRows = Grafana.parseExtraReadings(page.cfg_extraReadings);
        }
    }

    function commitFields() {
        var list = [];

        for (var i = 0; i < page.fieldRows.length; i++) {
            var row = page.fieldRows[i];

            list.push({
                "field": row.field,
                "label": row.label,
                "format": row.format,
                "align": row.align
            });
        }

        page.applyingEditor = true;
        page.cfg_sensorFields = JSON.stringify(list);
        page.applyingEditor = false;
    }

    function commitExtras() {
        var list = [];

        for (var i = 0; i < page.extraRows.length; i++) {
            var row = page.extraRows[i];

            list.push({
                "label": row.label,
                "source": row.sourceText,
                "format": row.format,
                "color": row.color,
                "align": row.align
            });
        }

        page.applyingEditor = true;
        page.cfg_extraReadings = JSON.stringify(list);
        page.applyingEditor = false;
    }

    function addField() {
        page.fieldRows = page.fieldRows.concat([{
            "field": "",
            "label": "",
            "format": "raw",
            "align": "left"
        }]);
        page.commitFields();
    }

    function removeField(index) {
        var next = page.fieldRows.slice();

        next.splice(index, 1);
        page.fieldRows = next;
        page.commitFields();
    }

    function addExtra() {
        page.extraRows = page.extraRows.concat([{
            "label": "",
            "sourceText": "",
            "format": "raw",
            "color": "none",
            "align": "left"
        }]);
        page.commitExtras();
    }

    function removeExtra(index) {
        var next = page.extraRows.slice();

        next.splice(index, 1);
        page.extraRows = next;
        page.commitExtras();
    }

    // Plasma gives the applet configuration dialog a fixed height hint and
    // does not grow it to this page's implicitHeight, so the last note is
    // clipped. The column and reading editors need noticeably more room.
    Component.onCompleted: {
        page.fieldRows = Grafana.parseSensorFields(page.cfg_sensorFields);
        page.extraRows = Grafana.parseExtraReadings(page.cfg_extraReadings);

        if (typeof configDialog === "undefined" || !configDialog) {
            return;
        }

        Qt.callLater(function () {
            configDialog.height += Kirigami.Units.gridUnit * 16;
        });
    }

    QQC2.TextField {
        id: titleField
        Kirigami.FormData.label: i18n("Widget title:")
        placeholderText: i18n("Empty uses the applet name")
    }

    QQC2.TextField {
        id: urlField
        Kirigami.FormData.label: i18n("Grafana API URL:")
        placeholderText: "http://grafana:3000"
    }

    QQC2.TextField {
        id: dashboardField
        Kirigami.FormData.label: i18n("Dashboard URL:")
        placeholderText: i18n("Optional — defaults to the Grafana API URL")
    }

    QQC2.TextField {
        id: tokenField
        Kirigami.FormData.label: i18n("Service account token:")
        placeholderText: i18n("Leave empty only for anonymous Grafana")
        echoMode: TextInput.Password
    }

    QQC2.Label {
        visible: looksLikeShareToken
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.negativeTextColor
        text: i18n("This looks like a public dashboard share token."
            + " Create a Viewer service account token in Grafana and use"
            + " that here instead.")
    }

    QQC2.CheckBox {
        id: proxyCheck
        Kirigami.FormData.label: i18n("Bypass system proxy:")
        text: i18n("Connect directly to Grafana, ignoring proxy settings")
    }

    QQC2.TextField {
        id: datasourceField
        Kirigami.FormData.label: i18n("Datasource UID:")
        placeholderText: "influxdb"
    }

    QQC2.TextField {
        id: bucketField
        Kirigami.FormData.label: i18n("InfluxDB bucket:")
        placeholderText: "sensors"
    }

    QQC2.TextField {
        id: measurementField
        Kirigami.FormData.label: i18n("Measurement:")
        placeholderText: "mqtt_consumer"
    }

    QQC2.TextField {
        id: sensorsField
        Kirigami.FormData.label: i18n("Sensor names:")
        placeholderText: i18n("Empty discovers every sensor;"
            + " name=Label renames one")
    }

    QQC2.Label {
        Layout.fillWidth: true
        Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        text: i18n("Use the discover button in the widget header to fill in"
            + " every sensor name found in the bucket. Existing labels are"
            + " kept. Names that are configured but not seen stay in the list"
            + " so a sleeping sensor is not dropped.")
    }

    QQC2.SpinBox {
        id: refreshSpin
        Kirigami.FormData.label: i18n("Refresh interval:")
        from: 10
        to: 3600
        stepSize: 10
        textFromValue: function (value) {
            return i18np("%1 second", "%1 seconds", value)
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            text: i18n("Sensor columns")
            font.bold: true
        }

        QQC2.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
            text: i18n("Each row is one value column. Leave the list empty to"
                + " show every numeric field the query returns and derive a"
                + " dew point when temperature and humidity are present."
                + " dewPoint is a derived field; every other field is"
                + " queried.")
        }

        Repeater {
            model: page.fieldRows

            delegate: ColumnLayout {
                id: fieldRow

                property var row: modelData

                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true

                    QQC2.TextField {
                        Layout.fillWidth: true
                        text: fieldRow.row.field
                        placeholderText: i18n("Field (temperature, dewPoint…)")
                        onTextEdited: {
                            fieldRow.row.field = text;
                            page.commitFields();
                        }
                    }

                    QQC2.TextField {
                        Layout.fillWidth: true
                        text: fieldRow.row.label
                        placeholderText: i18n("Label")
                        onTextEdited: {
                            fieldRow.row.label = text;
                            page.commitFields();
                        }
                    }

                    QQC2.ToolButton {
                        icon.name: "list-remove"
                        onClicked: page.removeField(index)
                    }
                }

                RowLayout {
                    Layout.fillWidth: true

                    QQC2.ComboBox {
                        Layout.fillWidth: true
                        model: page.formats
                        currentIndex: Math.max(0,
                            page.formats.indexOf(fieldRow.row.format))
                        onActivated: {
                            fieldRow.row.format = page.formats[currentIndex];
                            page.commitFields();
                        }
                    }

                    QQC2.ComboBox {
                        Layout.fillWidth: true
                        model: page.alignments
                        currentIndex: Math.max(0,
                            page.alignments.indexOf(fieldRow.row.align))
                        onActivated: {
                            fieldRow.row.align = page.alignments[currentIndex];
                            page.commitFields();
                        }
                    }
                }
            }
        }

        QQC2.Button {
            text: i18n("Add column")
            onClicked: page.addField()
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            text: i18n("Extra readings")
            font.bold: true
        }

        QQC2.Label {
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 25
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
            text: i18n("Each row becomes one value above the sensors."
                + " Source is measurement|tag=value|field in the same bucket;"
                + " the tag part is optional. Colour red or green applies"
                + " while the value is non-zero. Formats: temperature,"
                + " humidity, battery, kbtu, count or raw.")
        }

        Repeater {
            model: page.extraRows

            delegate: ColumnLayout {
                id: extraRow

                property var row: modelData

                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true

                    QQC2.TextField {
                        Layout.fillWidth: true
                        text: extraRow.row.label
                        placeholderText: i18n("Label")
                        onTextEdited: {
                            extraRow.row.label = text;
                            page.commitExtras();
                        }
                    }

                    QQC2.ToolButton {
                        icon.name: "list-remove"
                        onClicked: page.removeExtra(index)
                    }
                }

                QQC2.TextField {
                    Layout.fillWidth: true
                    text: extraRow.row.sourceText
                    placeholderText: i18n("measurement|tag=value|field")
                    onTextEdited: {
                        extraRow.row.sourceText = text;
                        page.commitExtras();
                    }
                }

                RowLayout {
                    Layout.fillWidth: true

                    QQC2.ComboBox {
                        Layout.fillWidth: true
                        model: page.formats
                        currentIndex: Math.max(0,
                            page.formats.indexOf(extraRow.row.format))
                        onActivated: {
                            extraRow.row.format = page.formats[currentIndex];
                            page.commitExtras();
                        }
                    }

                    QQC2.ComboBox {
                        Layout.fillWidth: true
                        model: page.colors
                        currentIndex: Math.max(0,
                            page.colors.indexOf(extraRow.row.color))
                        onActivated: {
                            extraRow.row.color = page.colors[currentIndex];
                            page.commitExtras();
                        }
                    }

                    QQC2.ComboBox {
                        Layout.fillWidth: true
                        model: page.alignments
                        currentIndex: Math.max(0,
                            page.alignments.indexOf(extraRow.row.align))
                        onActivated: {
                            extraRow.row.align = page.alignments[currentIndex];
                            page.commitExtras();
                        }
                    }
                }
            }
        }

        QQC2.Button {
            text: i18n("Add reading")
            onClicked: page.addExtra()
        }
    }

    QQC2.Label {
        Layout.fillWidth: true
        Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        text: i18n("Create the token under Administration → Users and access"
            + " → Service accounts with the Viewer role. All settings,"
            + " labels and lists are saved to ~/.config/sensorbridge in plain"
            + " text so they survive removing the widget. Append =Label to a"
            + " sensor name to rename it for display. The extra readings are"
            + " stored as a JSON list in the same file.")
    }
}
