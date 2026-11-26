import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "../js/grafana.js" as Grafana

Item {
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
    property bool applyingEditor: false

    // The value is what gets stored; the label is what the dropdown shows.
    property var formatChoices: [
        {"value": "temperature", "label": i18n("Temperature (°C)")},
        {"value": "humidity", "label": i18n("Humidity (%)")},
        {"value": "battery", "label": i18n("Battery (%)")},
        {"value": "kbtu", "label": i18n("kBTU/h")},
        {"value": "count", "label": i18n("Count")},
        {"value": "raw", "label": i18n("Raw value")}
    ]
    property var colorChoices: [
        {"value": "none", "label": i18n("No colour")},
        {"value": "negative", "label": i18n("Red while non-zero")},
        {"value": "positive", "label": i18n("Green while non-zero")}
    ]
    property var alignChoices: [
        {"value": "left", "label": i18n("Left")},
        {"value": "right", "label": i18n("Right")}
    ]

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

    Component.onCompleted: {
        page.fieldRows = Grafana.parseSensorFields(page.cfg_sensorFields);
        page.extraRows = Grafana.parseExtraReadings(page.cfg_extraReadings);
    }

    // A combo box with a caption above it, so "No colour" and "Red while
    // non-zero" make sense without having to guess what the dropdown is for.
    component Choice: ColumnLayout {
        id: choice

        property string caption: ""
        property var options: []
        property string value: ""
        signal picked(string value)

        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            text: choice.caption
            font: Kirigami.Theme.smallFont
        }

        QQC2.ComboBox {
            id: combo

            Layout.fillWidth: true
            model: choice.options
            textRole: "label"
            currentIndex: {
                var list = choice.options || [];

                for (var i = 0; i < list.length; i++) {
                    if (list[i].value === choice.value) {
                        return i;
                    }
                }
                return 0;
            }
            onActivated: {
                var list = choice.options || [];

                if (combo.currentIndex >= 0 && combo.currentIndex < list.length) {
                    choice.picked(list[combo.currentIndex].value);
                }
            }
        }
    }

    // Plasma gives the configuration page a fixed height and does not grow
    // the dialog to the form's implicit height. A scroll view here keeps every
    // setting reachable instead of clipping the bottom of the page.
    QQC2.ScrollView {
        id: scroller

        anchors.fill: parent
        clip: true
        contentWidth: availableWidth

        Kirigami.FormLayout {
            width: scroller.availableWidth

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
                text: i18n("Use the discover button in the widget header to fill"
                    + " in every sensor name found in the bucket. Existing labels"
                    + " are kept. Names that are configured but not seen stay in"
                    + " the list so a sleeping sensor is not dropped.")
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
                    text: i18n("Each row is one value column. Leave the list"
                        + " empty to show every discoverable numeric field and"
                        + " derive a dew point when temperature and humidity are"
                        + " present. dewPoint is derived; every other field is"
                        + " queried. Metadata such as rssi and timestamp is never"
                        + " shown.")
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

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                QQC2.Label {
                                    text: i18n("Field")
                                    font: Kirigami.Theme.smallFont
                                }

                                QQC2.TextField {
                                    Layout.fillWidth: true
                                    text: fieldRow.row.field
                                    placeholderText: i18n("temperature, dewPoint…")
                                    onTextEdited: {
                                        fieldRow.row.field = text;
                                        page.commitFields();
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                QQC2.Label {
                                    text: i18n("Label")
                                    font: Kirigami.Theme.smallFont
                                }

                                QQC2.TextField {
                                    Layout.fillWidth: true
                                    text: fieldRow.row.label
                                    placeholderText: i18n("Shown above the value")
                                    onTextEdited: {
                                        fieldRow.row.label = text;
                                        page.commitFields();
                                    }
                                }
                            }

                            QQC2.ToolButton {
                                icon.name: "list-remove"
                                onClicked: page.removeField(index)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true

                            Choice {
                                caption: i18n("Format")
                                options: page.formatChoices
                                value: fieldRow.row.format
                                onPicked: function (value) {
                                    fieldRow.row.format = value;
                                    page.commitFields();
                                }
                            }

                            Choice {
                                caption: i18n("Alignment")
                                options: page.alignChoices
                                value: fieldRow.row.align
                                onPicked: function (value) {
                                    fieldRow.row.align = value;
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
                        + " Source is measurement|tag=value|field in the same"
                        + " bucket; the tag part is optional. Colour leaves the"
                        + " value alone, turns it red, or turns it green while"
                        + " the value is not zero.")
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

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                QQC2.Label {
                                    text: i18n("Label")
                                    font: Kirigami.Theme.smallFont
                                }

                                QQC2.TextField {
                                    Layout.fillWidth: true
                                    text: extraRow.row.label
                                    placeholderText: i18n("Shown above the value")
                                    onTextEdited: {
                                        extraRow.row.label = text;
                                        page.commitExtras();
                                    }
                                }
                            }

                            QQC2.ToolButton {
                                icon.name: "list-remove"
                                onClicked: page.removeExtra(index)
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            QQC2.Label {
                                text: i18n("Source")
                                font: Kirigami.Theme.smallFont
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
                        }

                        RowLayout {
                            Layout.fillWidth: true

                            Choice {
                                caption: i18n("Format")
                                options: page.formatChoices
                                value: extraRow.row.format
                                onPicked: function (value) {
                                    extraRow.row.format = value;
                                    page.commitExtras();
                                }
                            }

                            Choice {
                                caption: i18n("Colour")
                                options: page.colorChoices
                                value: extraRow.row.color
                                onPicked: function (value) {
                                    extraRow.row.color = value;
                                    page.commitExtras();
                                }
                            }

                            Choice {
                                caption: i18n("Alignment")
                                options: page.alignChoices
                                value: extraRow.row.align
                                onPicked: function (value) {
                                    extraRow.row.align = value;
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
                text: i18n("Create the token under Administration → Users and"
                    + " access → Service accounts with the Viewer role. All"
                    + " settings, labels and lists are saved to"
                    + " ~/.config/sensorbridge in plain text so they survive"
                    + " removing the widget. Append =Label to a sensor name to"
                    + " rename it for display. The extra readings are stored as"
                    + " a JSON list in the same file.")
            }
        }
    }
}
