import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Window
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: root

    // Plasma sizes the applet configuration dialog from a fixed hint of its
    // own rather than from this page, so the lower fields stay hidden until
    // the window is stretched by hand. Ask for a width that fits the form and
    // grow the dialog to the form's real height, capped so it still fits on a
    // small screen. implicitHeight is left alone so the form reports its true
    // content height.
    implicitWidth: Kirigami.Units.gridUnit * 34

    Component.onCompleted: {
        if (typeof configDialog === "undefined" || !configDialog) {
            return;
        }

        Qt.callLater(function () {
            configDialog.width = Math.max(configDialog.width,
                root.implicitWidth + Kirigami.Units.gridUnit * 11);
            configDialog.height = Math.max(configDialog.height,
                Math.min(root.implicitHeight + Kirigami.Units.gridUnit * 9,
                    root.Screen.desktopAvailableHeight
                        - Kirigami.Units.gridUnit * 4));
        });
    }

    property alias cfg_grafanaUrl: urlField.text
    property alias cfg_apiToken: tokenField.text
    property bool looksLikeShareToken:
        /^[0-9a-f]{32}$/i.test(String(tokenField.text).trim())
    property alias cfg_datasourceUid: datasourceField.text
    property alias cfg_bucket: bucketField.text
    property alias cfg_measurement: measurementField.text
    property alias cfg_sensors: sensorsField.text
    property alias cfg_refreshSeconds: refreshSpin.value
    property alias cfg_bypassProxy: proxyCheck.checked

    QQC2.TextField {
        id: urlField
        Kirigami.FormData.label: i18n("Grafana URL:")
        placeholderText: "http://grafana:3000"
        Layout.fillWidth: true
    }

    QQC2.TextField {
        id: tokenField
        Kirigami.FormData.label: i18n("Service account token:")
        placeholderText: i18n("Leave empty only for anonymous Grafana")
        echoMode: TextInput.Password
        Layout.fillWidth: true
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
        Layout.fillWidth: true
    }

    QQC2.TextField {
        id: bucketField
        Kirigami.FormData.label: i18n("InfluxDB bucket:")
        placeholderText: "sensors"
        Layout.fillWidth: true
    }

    QQC2.TextField {
        id: measurementField
        Kirigami.FormData.label: i18n("Measurement:")
        placeholderText: "mqtt_consumer"
        Layout.fillWidth: true
    }

    QQC2.TextField {
        id: sensorsField
        Kirigami.FormData.label: i18n("Sensor names:")
        placeholderText: "GVH5075_B6D2, GVH5075_E22C"
        Layout.fillWidth: true
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

    QQC2.Label {
        Layout.fillWidth: true
        Layout.maximumWidth: Kirigami.Units.gridUnit * 30
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        text: i18n("Create the token under Administration → Users and access"
            + " → Service accounts with the Viewer role. It is stored in this"
            + " widget's configuration in plain text. Leave the sensor list"
            + " empty to show every sensor in the bucket.")
    }
}
