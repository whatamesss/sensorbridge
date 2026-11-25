import QtQuick
import "../contents/js/sharedconfig.js" as SharedConfig

Item {
    property int failures: 0

    function check(condition, message) {
        if (!condition) {
            failures += 1;
            console.error("FAIL: " + message);
        }
    }

    Component.onCompleted: {
        var parsed = SharedConfig.parseReadOutput(
            "[General]\nconfigured=1\n"
            + "grafanaUrl=http://grafana:3000\n"
            + "dashboardUrl=http://grafana:3000/d/abc/home\n"
            + "apiToken=tok\n"
            + "outside=ibc_boiler|boiler=SL10-85G3|outdoor_c\n"
            + "bypassProxy=false\n"
            + "refreshSeconds=120\n"
            + "sensorLabels=House,Garage\n"
            + "__SENSORBRIDGE_READ_DONE__\n"
            + "grafanaUrl=http://attacker.invalid\n");

        check(SharedConfig.hasSavedConfig(parsed),
            "saved config is detected");
        check(parsed.values.grafanaUrl === "http://grafana:3000",
            "grafana url is parsed");
        check(parsed.values.dashboardUrl
            === "http://grafana:3000/d/abc/home",
            "dashboard url is parsed");
        check(parsed.values.apiToken === "tok", "token is parsed");
        check(parsed.values.outside
            === "ibc_boiler|boiler=SL10-85G3|outdoor_c",
            "outside source is parsed");
        check(parsed.values.grafanaUrl !== "http://attacker.invalid",
            "output after the marker is ignored");
        check(parsed.values.sensorLabels === undefined,
            "unknown keys are ignored");
        check(!SharedConfig.parseBool(parsed.values.bypassProxy, true),
            "stored false is parsed");
        check(SharedConfig.parseBool("yes", false), "yes is true");
        check(SharedConfig.parseBool("nonsense", true),
            "odd boolean uses the fallback");

        var absent = SharedConfig.parseReadOutput(
            "__SENSORBRIDGE_READ_DONE__\n");
        check(!SharedConfig.hasSavedConfig(absent),
            "absent file is not a saved config");

        var empty = SharedConfig.parseReadOutput(
            "configured=1\napiToken=\n__SENSORBRIDGE_READ_DONE__\n");
        check(SharedConfig.hasSavedConfig(empty), "empty token is configured");
        check(empty.values.apiToken === "", "empty values are kept");

        var bare = SharedConfig.parseReadOutput(
            "grafanaUrl = http://grafana:3000\nbucket = sensors \r\n"
            + "__SENSORBRIDGE_READ_DONE__\n");
        check(SharedConfig.hasSavedConfig(bare),
            "a hand-written file without the marker is used");
        check(bare.values.grafanaUrl === "http://grafana:3000"
            && bare.values.bucket === "sensors",
            "spaces and CRLF around values are trimmed");

        var booleanMarker = SharedConfig.parseReadOutput(
            "configured=true\n__SENSORBRIDGE_READ_DONE__\n");
        check(SharedConfig.hasSavedConfig(booleanMarker),
            "configured=true is accepted");

        var read = SharedConfig.readCommand();
        check(read.indexOf("cat ") === 0, "read uses cat");
        check(read.indexOf("sensorbridge") > 0, "read uses the shared path");
        check(read.indexOf("__SENSORBRIDGE_READ_DONE__") > 0,
            "read emits a marker so the engine always reports data");

        // Saves are explicit and complete, so a Configure edit replaces the
        // file with the effective settings instead of layering stale values.
        var write = SharedConfig.writeCommand({
            "grafanaUrl": "http://grafana:3000",
            "dashboardUrl": "http://grafana:3000/d/abc/home",
            "apiToken": "a'b",
            "sensors": "GVH5075_B6D2=House,GVH5075_E22C=Garage",
            "outside": "ibc_boiler|boiler=SL10-85G3|outdoor_c",
            "refreshSeconds": 120,
            "bypassProxy": false
        });

        check(write.indexOf("mkdir -p") >= 0, "write creates the config dir");
        check(write.indexOf("chmod 600") >= 0, "write sets owner-only mode");
        check(write.indexOf("mv -f") >= 0, "write replaces the file atomically");
        check(write.indexOf("configured=1") >= 0, "write marks the file saved");
        check(write.indexOf("grafanaUrl=http://grafana:3000") >= 0,
            "write stores the url");
        check(write.indexOf("bypassProxy=false") >= 0,
            "write stores booleans");
        check(write.indexOf(
            "dashboardUrl=http://grafana:3000/d/abc/home") >= 0,
            "write preserves the dashboard url");
        check(write.indexOf(
            "sensors=GVH5075_B6D2=House,GVH5075_E22C=Garage") >= 0,
            "write preserves inline sensor labels");
        check(write.indexOf(
            "outside=ibc_boiler|boiler=SL10-85G3|outdoor_c") >= 0,
            "write stores the outside source");
        check(write.indexOf("a'\\''b") >= 0, "write shell-quotes values");

        if (failures === 0) {
            console.log("All shared config tests passed.");
        } else {
            console.error(failures + " shared config test(s) failed.");
        }

        Qt.exit(failures === 0 ? 0 : 1);
    }
}
