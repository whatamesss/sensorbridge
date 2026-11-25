import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    property alias cfg_grafanaUrl: urlField.text
    property alias cfg_dashboardUrl: dashboardField.text
    property alias cfg_apiToken: tokenField.text
    property bool looksLikeShareToken:
        /^[0-9a-f]{32}$/i.test(String(tokenField.text).trim())
    property alias cfg_datasourceUid: datasourceField.text
    property alias cfg_bucket: bucketField.text
    property alias cfg_measurement: measurementField.text
    property alias cfg_sensors: sensorsField.text
    property alias cfg_outside: outsideField.text
    property alias cfg_boilerHeat: boilerHeatField.text
    property alias cfg_jfConnections: jfConnectionsField.text
    property alias cfg_boilerErrors: boilerErrorsField.text
    property alias cfg_refreshSeconds: refreshSpin.value
    property alias cfg_bypassProxy: proxyCheck.checked

    // Plasma gives the applet configuration dialog a fixed height hint and
    // does not grow it to this page's implicitHeight, so the last note is
    // clipped. Nudge the window itself; a spacer or a larger implicitHeight
    // would only add a scrollable line inside the dialog. The extra source
    // settings need room too.
    Component.onCompleted: {
        if (typeof configDialog === "undefined" || !configDialog) {
            return;
        }

        Qt.callLater(function () {
            configDialog.height += Kirigami.Units.gridUnit * 8;
        });
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
        placeholderText: i18n("GVH5075_B6D2=House, GVH5075_E22C=Garage")
    }

    QQC2.TextField {
        id: outsideField
        Kirigami.FormData.label: i18n("Outside temperature:")
        placeholderText: i18n("measurement|tag=value|field — empty hides it")
    }

    QQC2.TextField {
        id: boilerHeatField
        Kirigami.FormData.label: i18n("High-mass heating:")
        placeholderText: i18n("measurement|tag=value|field — empty hides it")
    }

    QQC2.TextField {
        id: jfConnectionsField
        Kirigami.FormData.label: i18n("Jellyfin connections:")
        placeholderText: i18n("measurement|tag=value|field — empty hides it")
    }

    QQC2.TextField {
        id: boilerErrorsField
        Kirigami.FormData.label: i18n("Boiler errors:")
        placeholderText: i18n("measurement|tag=value|field — empty hides it")
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
        Layout.maximumWidth: Kirigami.Units.gridUnit * 25
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        text: i18n("Create the token under Administration → Users and access"
            + " → Service accounts with the Viewer role. Settings are saved"
            + " to ~/.config/sensorbridge in plain text. Append =Label to a"
            + " sensor name to change its display label. Leave the sensor list"
            + " empty to show every sensor in the bucket. The extra readings"
            + " come from other measurements in the same bucket, written as"
            + " measurement|tag=value|field; leave one empty to hide it. Boiler"
            + " heat is load2_btu (BTU/h), shown as kBtu/h; errors is"
            + " active_errors, red when non-zero.")
    }
}
