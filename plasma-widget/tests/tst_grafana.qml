import QtQuick
import "../contents/js/grafana.js" as Grafana

Item {
    property int failures: 0

    function check(condition, message) {
        if (!condition) {
            failures += 1;
            console.error("FAIL: " + message);
        }
    }

    function frameWithLabels(name, temperature, humidity, battery, time) {
        return {
            "schema": {
                "fields": [
                    {"name": "Time", "type": "time"},
                    {"name": "temperature", "type": "number",
                        "labels": {"name": name}},
                    {"name": "humidity", "type": "number",
                        "labels": {"name": name}},
                    {"name": "battery", "type": "number",
                        "labels": {"name": name}}
                ]
            },
            "data": {
                "values": [[time], [temperature], [humidity], [battery]]
            }
        };
    }

    function response(frames) {
        return JSON.stringify({
            "results": {
                "A": {
                    "status": 200,
                    "frames": frames
                }
            }
        });
    }

    function responseWithB(frames, outsideFrames, heatFrames, jfFrames,
            errorsFrames) {
        return JSON.stringify({
            "results": {
                "A": {
                    "status": 200,
                    "frames": frames
                },
                "B": {
                    "status": 200,
                    "frames": outsideFrames
                },
                "C": {
                    "status": 200,
                    "frames": heatFrames || []
                },
                "D": {
                    "status": 200,
                    "frames": jfFrames || []
                },
                "E": {
                    "status": 200,
                    "frames": errorsFrames || []
                }
            }
        });
    }

    function outsideFrame(fieldName, value, time) {
        return {
            "schema": {
                "fields": [
                    {"name": "Time", "type": "time"},
                    {"name": fieldName, "type": "number"}
                ]
            },
            "data": {"values": [[time], [value]]}
        };
    }

    Component.onCompleted: {
        var now = 1700000000000;

        // Frames come back in whatever order InfluxDB chooses; the widget
        // must still follow the configured sensor order.
        var parsed = Grafana.parseResponse(200, response([
            frameWithLabels("GVH5075_E22C", 6.5, 61.5, 100, now),
            frameWithLabels("GVH5075_B6D2", 19.0, 45.7, 95, now - 1000)
        ]), ["GVH5075_B6D2", "GVH5075_E22C"]);

        check(parsed.error === "", "valid response has no error");
        check(parsed.rows.length === 2, "two rows");
        check(parsed.rows[0].name === "GVH5075_B6D2", "configured order");
        check(parsed.rows[0].temperature === 19.0, "temperature");
        check(parsed.rows[0].humidity === 45.7, "humidity");
        check(parsed.rows[0].battery === 95, "battery");
        check(parsed.rows[0].timestamp === now - 1000, "timestamp");
        check(!parsed.rows[0].missing, "row is not missing");
        check(parsed.rows[1].name === "GVH5075_E22C", "second row");

        // A configured sensor with no point stays visible as "no data".
        var sparse = Grafana.parseResponse(200, response([
            frameWithLabels("GVH5075_B6D2", 19.0, 45.7, 95, now)
        ]), ["GVH5075_B6D2", "GVH5075_E22C"]);

        check(sparse.rows.length === 2, "missing sensor keeps its row");
        check(sparse.rows[1].missing, "missing sensor is flagged");
        check(sparse.rows[1].temperature === null, "missing value is null");

        // Some datasource versions expose name as a column instead of labels.
        var columnNamed = Grafana.parseResponse(200, response([{
            "schema": {
                "fields": [
                    {"name": "Time"},
                    {"name": "name"},
                    {"name": "temperature"},
                    {"name": "humidity"},
                    {"name": "battery"}
                ]
            },
            "data": {
                "values": [[now], ["GVH5075_B6D2"], [19.0], [45.7], [95]]
            }
        }]), []);
        check(columnNamed.rows.length === 1, "name column is discovered");
        check(columnNamed.rows[0].name === "GVH5075_B6D2", "name from column");

        // If the datasource returns one frame per field, merge them by name.
        var split = Grafana.parseResponse(200, response([
            {
                "schema": {
                    "fields": [
                        {"name": "Time", "type": "time"},
                        {"name": "temperature", "type": "number",
                            "labels": {"name": "GVH5075_B6D2"}}
                    ]
                },
                "data": {"values": [[now], [19.0]]}
            },
            {
                "schema": {
                    "fields": [
                        {"name": "Time", "type": "time"},
                        {"name": "humidity", "type": "number",
                            "labels": {"name": "GVH5075_B6D2"}}
                    ]
                },
                "data": {"values": [[now], [45.7]]}
            }
        ]), []);
        check(split.rows.length === 1, "split frames merge into one row");
        check(split.rows[0].temperature === 19.0, "split temperature kept");
        check(split.rows[0].humidity === 45.7, "split humidity kept");
        check(!split.rows[0].missing, "merged row has data");

        // The Android test payload must never appear as a sensor.
        var testPoint = Grafana.parseResponse(200, response([
            frameWithLabels("TEST", 21.6, 48.2, 95, now)
        ]), []);
        check(testPoint.rows.length === 0, "test reading is hidden");

        var unauthorized = Grafana.parseResponse(401, "", []);
        check(unauthorized.error.indexOf("401") >= 0, "401 is reported");
        check(unauthorized.rows.length === 0, "401 returns no rows");
        check(unauthorized.error.indexOf("service account token") >= 0,
            "401 explains which token is needed");

        var invalidKey = Grafana.parseResponse(401,
            '{"message":"Invalid API key"}', []);
        check(invalidKey.error.indexOf("service account token") >= 0,
            "Invalid API key names the token type");

        var missingDatasource = Grafana.parseResponse(404,
            '{"message":"Data source not found"}', []);
        check(missingDatasource.error.indexOf("404") >= 0,
            "404 is reported");
        check(missingDatasource.error.indexOf("Datasource UID") >= 0,
            "404 mentions the datasource UID");
        check(missingDatasource.error.indexOf("Data source not found") >= 0,
            "404 detail is reported");

        var unavailable = Grafana.parseResponse(503,
            '{"message":"upstream connect error"}', []);
        check(unavailable.error.indexOf("503") >= 0, "503 is reported");
        check(unavailable.error.indexOf("upstream connect error") >= 0,
            "503 JSON detail is reported");

        var unavailableHtml = Grafana.parseResponse(503,
            "<html><body><h1>Service Unavailable</h1></body></html>", []);
        check(unavailableHtml.error.indexOf("503") >= 0,
            "HTML 503 is reported");
        check(unavailableHtml.error.indexOf("Service Unavailable") >= 0,
            "HTML 503 body is reported");

        var failedQuery = Grafana.parseResponse(400,
            '{"results":{"A":{"error":"last: no column _value exists"}}}',
            []);
        check(failedQuery.error.indexOf("last: no column") >= 0,
            "query error detail is reported");

        var broken = Grafana.parseResponse(200, "not json", []);
        check(broken.error.length > 0, "invalid JSON is reported");

        var flux = Grafana.buildFlux("sensors", "mqtt_consumer",
            ["A\"B", "C"]);
        check(flux.indexOf('r.name == "A\\"B"') >= 0, "sensor name is escaped");
        check(flux.indexOf('r._measurement == "mqtt_consumer"') >= 0,
            "measurement is included");
        check(flux.indexOf("|> tail(n: 1)") >= 0,
            "query takes the last point");
        check(flux.indexOf("|> last()") < 0, "query does not use last()");

        var body = Grafana.queryBody({
            "datasourceUid": "influxdb",
            "bucket": "sensors",
            "measurement": "mqtt_consumer",
            "names": ["A"]
        });
        check(body.queries[0].datasource.uid === "influxdb",
            "datasource uid is sent");
        check(body.queries[0].query.indexOf('from(bucket: "sensors")') >= 0,
            "bucket is sent");
        check(body.queries.length === 1,
            "no extra queries without extra sources");

        var outside = Grafana.parseSideSource(
            "ibc_boiler|boiler=SL10-85G3|outdoor_c");
        var heat = Grafana.parseSideSource(
            "ibc_boiler|boiler=SL10-85G3|load2_btu");
        var jf = Grafana.parseSideSource(
            "jellyfin_connections|service=jellyfin|value");
        var errors = Grafana.parseSideSource(
            "ibc_boiler|boiler=SL10-85G3|active_errors");
        check(outside !== null, "outside source is parsed");
        check(outside.measurement === "ibc_boiler",
            "outside measurement is parsed");
        check(outside.tagKey === "boiler", "outside tag key is parsed");
        check(outside.tagValue === "SL10-85G3", "outside tag value is parsed");
        check(outside.field === "outdoor_c", "outside field is parsed");
        check(heat !== null && heat.field === "load2_btu",
            "high-mass heat source is parsed");
        check(jf !== null && jf.measurement === "jellyfin_connections"
            && jf.field === "value", "Jellyfin source is parsed");
        check(errors !== null && errors.field === "active_errors"
            && errors.tagValue === "SL10-85G3",
            "boiler error source is parsed");

        var outsideNoTag = Grafana.parseSideSource("weather|temp_c");
        check(outsideNoTag !== null && outsideNoTag.tagKey === "",
            "source works without a tag");
        check(Grafana.parseSideSource("") === null,
            "empty source is disabled");
        check(Grafana.parseSideSource("weather") === null,
            "source without a field is rejected");
        check(Grafana.parseSideSource("weather|1bad=x|temp") === null,
            "tag key must be an identifier");

        var outsideFlux = Grafana.buildSideFlux("sensors", outside);
        check(outsideFlux.indexOf('r._measurement == "ibc_boiler"') >= 0,
            "outside measurement is filtered");
        check(outsideFlux.indexOf('r.boiler == "SL10-85G3"') >= 0,
            "outside tag is filtered");
        check(outsideFlux.indexOf('r._field == "outdoor_c"') >= 0,
            "outside field is filtered");
        check(outsideFlux.indexOf("|> tail(n: 1)") >= 0,
            "outside query takes the last point");

        var sideSources = {
            "outside": outside,
            "heat": heat,
            "jf": jf,
            "errors": errors
        };
        var outsideBody = Grafana.queryBody({
            "datasourceUid": "influxdb",
            "bucket": "sensors",
            "measurement": "mqtt_consumer",
            "names": ["A"],
            "sides": sideSources
        });
        check(outsideBody.queries.length === 5,
            "four extra sources add four queries");
        check(outsideBody.queries[1].refId === "B"
            && outsideBody.queries[2].refId === "C"
            && outsideBody.queries[3].refId === "D"
            && outsideBody.queries[4].refId === "E",
            "extra queries use refIds B, C, D and E");
        check(outsideBody.queries[1].query
            .indexOf('r._measurement == "ibc_boiler"') >= 0,
            "outside query is sent");
        check(outsideBody.queries[2].query
            .indexOf('r._field == "load2_btu"') >= 0,
            "heat query is sent");
        check(outsideBody.queries[3].query
            .indexOf('r._measurement == "jellyfin_connections"') >= 0,
            "Jellyfin query is sent");
        check(outsideBody.queries[4].query
            .indexOf('r._field == "active_errors"') >= 0,
            "boiler error query is sent");

        var withSides = Grafana.parseResponse(200, responseWithB([], [
            outsideFrame("_value", 3.25, now)
        ], [
            outsideFrame("_value", 45000, now - 1000)
        ], [
            outsideFrame("_value", 3, now - 2000)
        ], [
            outsideFrame("_value", 2, now - 3000)
        ]), [], null, sideSources);
        check(withSides.sides.outside !== null, "outside reading is parsed");
        check(withSides.sides.outside.value === 3.25,
            "outside temperature is parsed");
        check(withSides.sides.outside.timestamp === now,
            "outside timestamp is parsed");
        check(!withSides.sides.outside.missing, "outside reading has data");
        check(withSides.sides.heat.value === 45000,
            "high-mass heat is parsed");
        check(withSides.sides.jf.value === 3,
            "Jellyfin connections are parsed");
        check(withSides.sides.errors.value === 2,
            "boiler errors are parsed");

        var outsideNamed = Grafana.parseResponse(200, responseWithB([], [
            outsideFrame("outdoor_c", -4.5, now - 5000)
        ]), [], null, {"outside": outside});
        check(outsideNamed.sides.outside.value === -4.5,
            "outside field column is accepted");

        var outsideEmpty = Grafana.parseResponse(200, responseWithB([], []),
            [], null, {"outside": outside});
        check(outsideEmpty.sides.outside.missing,
            "missing outside point is flagged");

        var errorsEmpty = Grafana.parseResponse(200,
            responseWithB([], [], [], [], []), [], null, {"errors": errors});
        check(errorsEmpty.sides.errors.missing,
            "missing boiler error point is flagged");
        check(errorsEmpty.sides.outside === null,
            "disabled readings stay hidden");

        var outsideFailed = Grafana.parseResponse(200, JSON.stringify({
            "results": {
                "A": {
                    "status": 200,
                    "frames": [frameWithLabels(
                        "GVH5075_B6D2", 19.0, 45.7, 95, now)]
                },
                "B": {"status": 200, "error": "invalid flux"}
            }
        }), ["GVH5075_B6D2"], null, {"outside": outside});
        check(outsideFailed.rows.length === 1
            && !outsideFailed.rows[0].missing,
            "failed outside query keeps the sensor rows");
        check(outsideFailed.sides.outside.missing,
            "failed outside query shows no data");

        var noOutsideWanted = Grafana.parseResponse(200, responseWithB([], [
            outsideFrame("_value", 3.25, now)
        ]), [], null, {});
        check(noOutsideWanted.sides.outside === null,
            "outside reading is ignored when disabled");

        check(Grafana.apiUrl("http://grafana:3000/")
            === "http://grafana:3000/api/ds/query", "api url is built");
        check(Grafana.normalizeBaseUrl(
            "http://grafana:3000/api/ds/query/")
            === "http://grafana:3000", "pasted endpoint is stripped");
        check(Grafana.apiUrl("http://grafana:3000/api/ds/query")
            === "http://grafana:3000/api/ds/query",
            "api endpoint is not doubled");
        check(Grafana.apiUrl("http://grafana.home.arpa:3000/grafana/")
            === "http://grafana.home.arpa:3000/grafana/api/ds/query",
            "api url keeps a subpath");
        check(Grafana.normalizeBaseUrl(
            "http://grafana.home.arpa:3000/grafana/api/ds/query/")
            === "http://grafana.home.arpa:3000/grafana",
            "pasted endpoint under a subpath is stripped");
        check(Grafana.isPublicDashboardUrl(
            "http://grafana:3000/public-dashboards/"
            + "4c7297010d95481a85cd86f57c708d27"),
            "public dashboard link is detected");
        check(!Grafana.isPublicDashboardUrl("http://grafana:3000"),
            "base url is accepted");
        check(Grafana.browserUrl(" http://grafana:3000/ ")
            === "http://grafana:3000", "browser url is the configured base");
        check(Grafana.browserUrl(
            "http://grafana:3000/api/ds/query")
            === "http://grafana:3000", "browser url drops api suffix");
        check(Grafana.browserUrl(
            "http://grafana.home.arpa:3000/grafana/d/abc/home")
            === "http://grafana.home.arpa:3000/grafana/d/abc/home",
            "browser url keeps a dashboard path");
        check(Grafana.browserUrl("file:///etc/passwd") === "",
            "non-http browser url is rejected");
        check(Grafana.browserUrl("") === "", "empty browser url is rejected");
        check(Grafana.shellQuote("a'b") === "'a'\\''b'",
            "shell quote escapes single quotes");

        var curl = Grafana.buildCurlCommand({
            "grafanaUrl": "http://grafana:3000",
            "datasourceUid": "influxdb",
            "bucket": "sensors",
            "measurement": "mqtt_consumer",
            "names": ["A"],
            "token": "tok"
        });
        check(curl.indexOf("--noproxy '*'") >= 0, "curl disables proxies");
        check(curl.indexOf("-u LD_PRELOAD") >= 0, "curl drops LD_PRELOAD");
        check(curl.indexOf("-u http_proxy") >= 0, "curl drops http_proxy");
        check(curl.indexOf("Authorization: Bearer tok") >= 0,
            "curl sends the token");
        check(curl.indexOf("'http://grafana:3000/api/ds/query'") >= 0,
            "curl uses the query endpoint");

        check(Grafana.shouldBypassProxy({}), "proxy bypass defaults to on");
        check(!Grafana.shouldBypassProxy({"bypassProxy": false}),
            "explicit false disables proxy bypass");
        check(!Grafana.shouldBypassProxy({"bypassProxy": "false"}),
            "stored false disables proxy bypass");

        var curlNoBypass = Grafana.buildCurlCommand({
            "grafanaUrl": "http://grafana:3000",
            "datasourceUid": "influxdb",
            "bucket": "sensors",
            "measurement": "mqtt_consumer",
            "names": ["A"],
            "token": "tok",
            "bypassProxy": false
        });
        check(curlNoBypass.indexOf("--noproxy") < 0,
            "disabled bypass keeps curl's proxy handling");
        check(curlNoBypass.indexOf("-u http_proxy") < 0,
            "disabled bypass leaves proxy environment variables alone");
        check(curlNoBypass.indexOf("-u LD_PRELOAD") < 0,
            "disabled bypass leaves LD_PRELOAD alone");
        check(curlNoBypass.indexOf("curl -sS") >= 0,
            "disabled bypass still runs curl");
        check(curlNoBypass.indexOf("Authorization: Bearer tok") >= 0,
            "disabled bypass still sends the token");

        var curlOk = Grafana.parseCurlOutput({
            "stdout": response([]) + "\n200",
            "stderr": "",
            "exit code": 0
        }, []);
        check(curlOk.status === 200, "curl output keeps the status");
        check(curlOk.error.length === 0, "curl 200 has no error");
        check(curlOk.sides.outside === null,
            "curl output has no extra readings by default");

        var curlOutside = Grafana.parseCurlOutput({
            "stdout": responseWithB([], [
                outsideFrame("_value", -1.5, now)
            ]) + "\n200",
            "stderr": "",
            "exit code": 0
        }, [], "", {"outside": outside});
        check(curlOutside.sides.outside.value === -1.5,
            "curl output keeps the outside reading");

        var curlFailed = Grafana.parseCurlOutput({
            "stdout": "\n000",
            "stderr": "curl: (7) Failed to connect",
            "exit code": 7
        }, []);
        check(curlFailed.status === 0, "curl failure has status 0");
        check(curlFailed.error.indexOf("Could not reach Grafana") >= 0,
            "curl failure is reported");
        check(curlFailed.error.indexOf("Failed to connect") >= 0,
            "curl stderr is reported");

        var curl503 = Grafana.parseCurlOutput({
            "stdout": '{"message":"proxy busy"}\n503',
            "stderr": "",
            "exit code": 0
        }, []);
        check(curl503.status === 503, "curl 503 status is parsed");
        check(curl503.error.indexOf("503") >= 0, "curl 503 is reported");

        // A reverse proxy in front of Grafana answers with HTML (or nothing)
        // instead of Grafana's JSON; the widget must name the peer it reached.
        var proxied503 = Grafana.parseCurlOutput({
            "stdout": "<html><body><h1>503 Service Unavailable</h1></body></html>"
                + "\n503 10.10.11.11 3000 text/html; charset=utf-8",
            "stderr": "",
            "exit code": 0
        }, [], "http://grafana:3000/api/ds/query");
        check(proxied503.status === 503, "proxied 503 status is parsed");
        check(proxied503.error.indexOf("10.10.11.11:3000") >= 0,
            "proxied 503 names the peer");
        check(proxied503.error.indexOf("did not come from Grafana") >= 0,
            "proxied 503 is blamed on the proxy");
        check(proxied503.error.indexOf("http://grafana:3000/api/ds/query") >= 0,
            "proxied 503 names the requested url");

        var grafana503 = Grafana.parseCurlOutput({
            "stdout": '{"message":"query timeout"}\n'
                + "503 10.10.11.11 3000 application/json",
            "stderr": "",
            "exit code": 0
        }, [], "http://grafana:3000/api/ds/query");
        check(grafana503.error.indexOf("query timeout") >= 0,
            "grafana 503 detail is reported");
        check(grafana503.error.indexOf("did not come from Grafana") < 0,
            "grafana 503 is not blamed on a proxy");

        var dew = Grafana.dewPoint(20, 50);
        check(Math.abs(dew - 9.255) < 0.01, "dew point is calculated");
        check(Math.abs(Grafana.dewPoint(20, 100) - 20) < 0.001,
            "saturated air dew point equals temperature");
        check(Grafana.dewPoint(null, 50) === null,
            "dew point needs temperature");
        check(Grafana.dewPoint(20, null) === null,
            "dew point needs humidity");
        check(Grafana.dewPoint(20, 0) === null,
            "dew point rejects zero humidity");
        check(Grafana.dewPoint(20, 101) === null,
            "dew point rejects humidity above 100");

        check(Grafana.sensorDisplayName("GVH5075_B6D2")
            === "GVH5075_B6D2 (House)", "B6D2 gets the House label");
        check(Grafana.sensorDisplayName("GVH5075_E22C")
            === "GVH5075_E22C (Garage)", "E22C gets the Garage label");
        check(Grafana.sensorDisplayName("GVH5075_1234")
            === "GVH5075_1234", "unknown sensors keep their name");
        check(Grafana.sensorDisplayName(null) === "",
            "null sensor name is empty");

        var plain = Grafana.parseSensorList(
            "GVH5075_B6D2, GVH5075_E22C");
        check(plain.names.length === 2, "plain list has two names");
        check(plain.names[0] === "GVH5075_B6D2", "first name is kept");
        check(plain.labels["GVH5075_B6D2"] === undefined,
            "plain names have no override");

        var labeled = Grafana.parseSensorList(
            "GVH5075_B6D2=Living room, GVH5075_E22C=Shed");
        check(labeled.names[0] === "GVH5075_B6D2",
            "label is not part of the queried name");
        check(labeled.names[1] === "GVH5075_E22C",
            "second label is not part of the queried name");
        check(labeled.labels["GVH5075_B6D2"] === "Living room",
            "explicit label maps by raw name");
        check(labeled.labels["GVH5075_E22C"] === "Shed",
            "second explicit label maps by raw name");

        var partial = Grafana.parseSensorList(
            "GVH5075_B6D2=House, GVH5075_E22C");
        check(partial.names.length === 2, "mixed list keeps both names");
        check(partial.labels["GVH5075_B6D2"] === "House",
            "mixed list keeps the explicit label");
        check(partial.labels["GVH5075_E22C"] === undefined,
            "unlabelled entry has no override");

        var duplicate = Grafana.parseSensorList(
            "GVH5075_B6D2=House, GVH5075_B6D2=Shed");
        check(duplicate.names.length === 1, "duplicate names are merged");
        check(duplicate.labels["GVH5075_B6D2"] === "Shed",
            "last label wins for a duplicate");

        var emptyName = Grafana.parseSensorList("=TEST, GVH5075_B6D2");
        check(emptyName.names.length === 1
            && emptyName.names[0] === "GVH5075_B6D2",
            "an entry without a name is ignored");

        var noSensors = Grafana.parseSensorList("");
        check(noSensors.names.length === 0, "empty list has no names");

        // Regression: a label must never become a queried sensor name.
        var names = Grafana.parseSensorList("GVH5075_B6D2=TEST").names;
        var labeledRow = Grafana.parseResponse(200, response([
            frameWithLabels("GVH5075_B6D2", 19.0, 45.7, 95, now)
        ]), names);
        check(labeledRow.rows.length === 1,
            "labelled sensor still gets a row");
        check(!labeledRow.rows[0].missing,
            "labelled sensor still has data");

        check(Grafana.formatTemperature(19.04) === "19.0 °C",
            "temperature format");
        check(Grafana.formatHumidity(45.67) === "45.7 %", "humidity format");
        check(Grafana.formatBattery(94.6) === "95 %", "battery format");
        check(Grafana.formatKbtu(45000) === "45 kBtu/h", "kBtu/h format");
        check(Grafana.formatKbtu(null) === "–", "null kBtu/h format");
        check(Grafana.formatCount(3.4) === "3", "connection count format");
        check(Grafana.formatTemperature(null) === "–", "null format");
        check(Grafana.formatAge(now, now) === "just now", "age now");
        check(Grafana.formatAge(now - 120000, now) === "2 min ago",
            "age minutes");
        check(Grafana.formatAge(now - 3700000, now) === "1 hour ago",
            "age hour");
        check(Grafana.formatAge(0, now) === "no data", "age missing");

        if (failures === 0) {
            console.log("All widget tests passed.");
        } else {
            console.error(failures + " widget test(s) failed.");
        }

        Qt.exit(failures === 0 ? 0 : 1);
    }
}
