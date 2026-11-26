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

    function responseWith(frames, sideFrames) {
        var results = {
            "A": {"status": 200, "frames": frames}
        };
        var refs = ["B", "C", "D", "E"];

        for (var i = 0; i < sideFrames.length; i++) {
            results[refs[i]] = {"status": 200, "frames": sideFrames[i]};
        }

        return JSON.stringify({"results": results});
    }

    function valueFrame(fieldName, value, time) {
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

    function sensorFields() {
        return Grafana.parseSensorFields(JSON.stringify([
            {"field": "temperature", "label": "Temperature",
                "format": "temperature", "align": "left"},
            {"field": "humidity", "label": "Humidity",
                "format": "humidity", "align": "left"},
            {"field": "dewPoint", "label": "Dew point",
                "format": "temperature", "align": "right"},
            {"field": "battery", "label": "Battery",
                "format": "battery", "align": "right"}
        ]));
    }

    function extras() {
        return Grafana.parseExtraReadings(JSON.stringify([
            {"label": "Outside", "source":
                "ibc_boiler|boiler=SL10-85G3|outdoor_c",
                "format": "temperature", "color": "none", "align": "left"},
            {"label": "High Mass Ht.", "source":
                "ibc_boiler|boiler=SL10-85G3|load2_btu",
                "format": "kbtu", "color": "negative", "align": "left"},
            {"label": "Errors", "source":
                "ibc_boiler|boiler=SL10-85G3|active_errors",
                "format": "count", "color": "negative", "align": "right"},
            {"label": "Connects", "source":
                "jellyfin_connections|service=jellyfin|value",
                "format": "count", "color": "positive", "align": "right"}
        ]));
    }

    Component.onCompleted: {
        var now = 1700000000000;
        var fields = sensorFields();

        // Frames come back in whatever order InfluxDB chooses; the widget
        // must still follow the configured sensor order.
        var parsed = Grafana.parseResponse(200, response([
            frameWithLabels("SENSOR_B", 6.5, 61.5, 100, now),
            frameWithLabels("SENSOR_A", 19.0, 45.7, 95, now - 1000)
        ]), ["SENSOR_A", "SENSOR_B"], null, [], fields);

        check(parsed.error === "", "valid response has no error");
        check(parsed.rows.length === 2, "two rows");
        check(parsed.rows[0].name === "SENSOR_A", "configured order");
        check(parsed.rows[0].temperature === 19.0, "temperature");
        check(parsed.rows[0].humidity === 45.7, "humidity");
        check(parsed.rows[0].battery === 95, "battery");
        check(parsed.rows[0].timestamp === now - 1000, "timestamp");
        check(!parsed.rows[0].missing, "row is not missing");
        check(parsed.rows[0].columns.length === 4, "four configured columns");
        check(parsed.rows[0].columns[0].label === "Temperature",
            "column label comes from config");
        check(parsed.rows[0].columns[2].field === "dewPoint",
            "derived dew point column is present");
        check(Math.abs(parsed.rows[0].columns[2].value
            - Grafana.dewPoint(19.0, 45.7)) < 0.01,
            "derived dew point is calculated");
        check(parsed.rows[1].name === "SENSOR_B", "second row");

        // A configured sensor with no point stays visible as "no data".
        var sparse = Grafana.parseResponse(200, response([
            frameWithLabels("SENSOR_A", 19.0, 45.7, 95, now)
        ]), ["SENSOR_A", "SENSOR_B"], null, [], fields);

        check(sparse.rows.length === 2, "missing sensor keeps its row");
        check(sparse.rows[1].missing, "missing sensor is flagged");
        check(sparse.rows[1].temperature === null, "missing value is null");
        check(sparse.rows[1].columns.length === 4,
            "missing row keeps the configured columns");

        // With no configured names every sensor is discovered, which is what
        // the Discover action and an empty Sensor names setting use.
        var discovered = Grafana.parseResponse(200, response([
            frameWithLabels("B", 6.5, 61.5, 100, now),
            frameWithLabels("A", 19.0, 45.7, 95, now)
        ]), [], null, [], []);
        check(discovered.rows.length === 2, "all sensors are discovered");
        check(discovered.rows[0].name === "A"
            && discovered.rows[1].name === "B", "discovered rows are sorted");
        check(discovered.rows[0].columns.length === 4,
            "discovered columns include dew point");
        check(discovered.rows[0].columns[0].label === "Temperature",
            "discovered label is humanized");

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
                "values": [[now], ["SENSOR_A"], [19.0], [45.7], [95]]
            }
        }]), []);
        check(columnNamed.rows.length === 1, "name column is discovered");
        check(columnNamed.rows[0].name === "SENSOR_A", "name from column");
        check(columnNamed.rows[0].columns.length === 4,
            "name column is not a reading column");

        // If the datasource returns one frame per field, merge them by name.
        var split = Grafana.parseResponse(200, response([
            {
                "schema": {
                    "fields": [
                        {"name": "Time", "type": "time"},
                        {"name": "temperature", "type": "number",
                            "labels": {"name": "SENSOR_A"}}
                    ]
                },
                "data": {"values": [[now], [19.0]]}
            },
            {
                "schema": {
                    "fields": [
                        {"name": "Time", "type": "time"},
                        {"name": "humidity", "type": "number",
                            "labels": {"name": "SENSOR_A"}}
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
            ["A\"B", "C"], fields);
        check(flux.indexOf('r.name == "A\\"B"') >= 0, "sensor name is escaped");
        check(flux.indexOf('r._measurement == "mqtt_consumer"') >= 0,
            "measurement is included");
        check(flux.indexOf('r._field == "temperature"') >= 0,
            "configured fields are filtered");
        check(flux.indexOf('r._field == "dewPoint"') < 0,
            "derived dew point is not queried");
        check(flux.indexOf("|> tail(n: 1)") >= 0,
            "query takes the last point");
        check(flux.indexOf("|> last()") < 0, "query does not use last()");
        check(flux.indexOf("|> keep(columns:") >= 0,
            "configured fields are kept");

        var discoveryFlux = Grafana.buildFlux("sensors", "mqtt_consumer",
            [], []);
        check(discoveryFlux.indexOf("r._field ==") < 0,
            "discovery does not restrict fields");
        check(discoveryFlux.indexOf("|> keep(") < 0,
            "discovery keeps every column");

        var body = Grafana.queryBody({
            "datasourceUid": "influxdb",
            "bucket": "sensors",
            "measurement": "mqtt_consumer",
            "names": ["A"],
            "fields": fields
        });
        check(body.queries[0].datasource.uid === "influxdb",
            "datasource uid is sent");
        check(body.queries[0].query.indexOf('from(bucket: "sensors")') >= 0,
            "bucket is sent");
        check(body.queries.length === 1,
            "no extra queries without extra sources");

        // The extraReading list, not a fixed set of side keys, drives the
        // ordered values and their refIds.
        var sideList = extras();
        check(sideList.length === 4, "all extra readings are parsed");
        check(sideList[0].label === "Outside", "extra label is parsed");
        check(sideList[0].format === "temperature", "extra format is parsed");
        check(sideList[1].color === "negative", "extra colour is parsed");
        check(sideList[3].align === "right", "extra alignment is parsed");
        check(sideList[0].source.measurement === "ibc_boiler",
            "extra source is parsed");
        check(sideList[0].source.tagKey === "boiler",
            "extra tag key is parsed");
        check(sideList[0].source.field === "outdoor_c",
            "extra field is parsed");

        var invalidExtras = Grafana.parseExtraReadings(JSON.stringify([
            {"label": "Broken", "source": "weather"},
            {"label": "Bad tag", "source": "weather|1bad=x|temp"},
            {"label": "No tag", "source": "weather|temp_c"}
        ]));
        check(invalidExtras.length === 1, "invalid extra sources are dropped");
        check(invalidExtras[0].label === "No tag", "valid extra survives");
        check(invalidExtras[0].source.tagKey === "",
            "tagless extra source works");
        check(Grafana.parseExtraReadings("not json").length === 0,
            "invalid extra JSON is ignored");
        check(Grafana.parseExtraReadings("").length === 0,
            "empty extra list is allowed");

        var sensorFieldList = Grafana.parseSensorFields(JSON.stringify([
            {"field": "temperature"},
            {"field": "temperature", "label": "Duplicate"},
            {"field": ""},
            {"field": "outdoor_c"}
        ]));
        check(sensorFieldList.length === 2, "invalid/duplicate fields dropped");
        check(sensorFieldList[0].label === "Temperature",
            "field label defaults to humanized name");
        check(sensorFieldList[0].format === "temperature",
            "field format is inferred");
        check(sensorFieldList[1].format === "temperature",
            "temperature suffix is inferred");
        check(Grafana.parseSensorFields("not json").length === 0,
            "invalid field JSON is ignored");

        var derived = Grafana.deriveSensorFields(discovered.rows, []);
        check(derived.length === 4, "discovery derives every column");
        check(derived[3].field === "dewPoint", "discovery adds dew point");
        var preserved = Grafana.deriveSensorFields(discovered.rows, [{
            "field": "temperature", "label": "Room",
            "format": "temperature", "align": "right"
        }]);
        check(preserved[0].label === "Room", "configured label is preserved");
        check(preserved.length === 4, "missing discovered columns are added");

        var outsideBody = Grafana.queryBody({
            "datasourceUid": "influxdb",
            "bucket": "sensors",
            "measurement": "mqtt_consumer",
            "names": ["A"],
            "fields": fields,
            "extras": sideList
        });
        check(outsideBody.queries.length === 5,
            "four extra sources add four queries");
        check(outsideBody.queries[1].refId === "B"
            && outsideBody.queries[2].refId === "C"
            && outsideBody.queries[3].refId === "D"
            && outsideBody.queries[4].refId === "E",
            "extra queries use refIds B, C, D and E");
        check(Grafana.refIdFor(0) === "B" && Grafana.refIdFor(25) === "AA",
            "refIds continue past Z");
        check(outsideBody.queries[1].query
            .indexOf('r._measurement == "ibc_boiler"') >= 0,
            "outside query is sent");
        check(outsideBody.queries[2].query
            .indexOf('r._field == "load2_btu"') >= 0,
            "heat query is sent");
        check(outsideBody.queries[3].query
            .indexOf('r._field == "active_errors"') >= 0,
            "boiler error query is sent");
        check(outsideBody.queries[4].query
            .indexOf('r._measurement == "jellyfin_connections"') >= 0,
            "Jellyfin query is sent");

        var withSides = Grafana.parseResponse(200, responseWith([], [
            [valueFrame("_value", 3.25, now)],
            [valueFrame("_value", 45000, now - 1000)],
            [valueFrame("_value", 3, now - 2000)],
            [valueFrame("_value", 2, now - 3000)]
        ]), [], null, sideList, fields);
        check(withSides.sides.length === 4, "four readings are parsed");
        check(withSides.sides[0].value === 3.25, "outside is parsed");
        check(withSides.sides[0].timestamp === now,
            "outside timestamp is parsed");
        check(!withSides.sides[0].missing, "outside reading has data");
        check(withSides.sides[1].value === 45000, "high-mass heat is parsed");
        check(withSides.sides[3].value === 2, "boiler errors are parsed");

        var outsideNamed = Grafana.parseResponse(200, responseWith([], [
            [valueFrame("outdoor_c", -4.5, now - 5000)]
        ]), [], null, [sideList[0]], fields);
        check(outsideNamed.sides[0].value === -4.5,
            "outside field column is accepted");

        var outsideEmpty = Grafana.parseResponse(200, responseWith([], [
            []
        ]), [], null, [sideList[0]], fields);
        check(outsideEmpty.sides[0].missing,
            "missing outside point is flagged");

        var noExtras = Grafana.parseResponse(200, response([]), []);
        check(noExtras.sides.length === 0, "no configured readings means none");

        var outsideFailed = Grafana.parseResponse(200, JSON.stringify({
            "results": {
                "A": {
                    "status": 200,
                    "frames": [frameWithLabels("SENSOR_A", 19.0, 45.7, 95,
                        now)]
                },
                "B": {"status": 200, "error": "invalid flux"}
            }
        }), ["SENSOR_A"], null, [sideList[0]], fields);
        check(outsideFailed.rows.length === 1
            && !outsideFailed.rows[0].missing,
            "failed outside query keeps the sensor rows");
        check(outsideFailed.sides[0].missing,
            "failed outside query shows no data");

        check(Grafana.apiUrl("http://grafana:3000/")
            === "http://grafana:3000/api/ds/query", "api url is built");
        check(Grafana.normalizeBaseUrl(
            "http://grafana:3000/api/ds/query/")
            === "http://grafana:3000", "pasted endpoint is stripped");
        check(Grafana.apiUrl("http://grafana.home.arpa:3000/grafana/")
            === "http://grafana.home.arpa:3000/grafana/api/ds/query",
            "api url keeps a subpath");
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
        check(Grafana.browserUrl("file:///etc/passwd") === "",
            "non-http browser url is rejected");
        check(Grafana.shellQuote("a'b") === "'a'\\''b'",
            "shell quote escapes single quotes");

        var curl = Grafana.buildCurlCommand({
            "grafanaUrl": "http://grafana:3000",
            "datasourceUid": "influxdb",
            "bucket": "sensors",
            "measurement": "mqtt_consumer",
            "names": ["A"],
            "fields": fields,
            "extras": sideList,
            "token": "tok"
        });
        check(curl.indexOf("--noproxy '*'") >= 0, "curl disables proxies");
        check(curl.indexOf("-u LD_PRELOAD") >= 0, "curl drops LD_PRELOAD");
        check(curl.indexOf("-u http_proxy") >= 0, "curl drops http_proxy");
        check(curl.indexOf("Authorization: Bearer tok") >= 0,
            "curl sends the token");
        check(curl.indexOf("'http://grafana:3000/api/ds/query'") >= 0,
            "curl uses the query endpoint");
        check(curl.indexOf("load2_btu") >= 0,
            "curl includes the configured extra readings");

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
            "fields": fields,
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
        }, [], "", [], []);
        check(curlOk.status === 200, "curl output keeps the status");
        check(curlOk.error.length === 0, "curl 200 has no error");
        check(curlOk.sides.length === 0,
            "curl output has no extra readings by default");

        var curlOutside = Grafana.parseCurlOutput({
            "stdout": responseWith([], [
                [valueFrame("_value", -1.5, now)]
            ]) + "\n200",
            "stderr": "",
            "exit code": 0
        }, [], "", [sideList[0]], fields);
        check(curlOutside.sides[0].value === -1.5,
            "curl output keeps the outside reading");

        var curlFailed = Grafana.parseCurlOutput({
            "stdout": "\n000",
            "stderr": "curl: (7) Failed to connect",
            "exit code": 7
        }, [], "", [sideList[0]], fields);
        check(curlFailed.status === 0, "curl failure has status 0");
        check(curlFailed.error.indexOf("Could not reach Grafana") >= 0,
            "curl failure is reported");
        check(curlFailed.error.indexOf("Failed to connect") >= 0,
            "curl stderr is reported");
        check(curlFailed.sides[0].missing,
            "curl failure marks readings missing");

        var curl503 = Grafana.parseCurlOutput({
            "stdout": '{"message":"proxy busy"}\n503',
            "stderr": "",
            "exit code": 0
        }, [], "", [], []);
        check(curl503.status === 503, "curl 503 status is parsed");
        check(curl503.error.indexOf("503") >= 0, "curl 503 is reported");

        var dew = Grafana.dewPoint(20, 50);
        check(Math.abs(dew - 9.255) < 0.01, "dew point is calculated");
        check(Math.abs(Grafana.dewPoint(20, 100) - 20) < 0.001,
            "saturated air dew point equals temperature");
        check(Grafana.dewPoint(null, 50) === null,
            "dew point needs temperature");
        check(Grafana.dewPoint(20, 0) === null,
            "dew point rejects zero humidity");

        var plain = Grafana.parseSensorList("SENSOR_A, SENSOR_B");
        check(plain.names.length === 2, "plain list has two names");
        check(plain.names[0] === "SENSOR_A", "first name is kept");
        check(plain.labels["SENSOR_A"] === undefined,
            "plain names have no override");

        var labeled = Grafana.parseSensorList(
            "SENSOR_A=Living room, SENSOR_B=Shed");
        check(labeled.names[0] === "SENSOR_A",
            "label is not part of the queried name");
        check(labeled.labels["SENSOR_A"] === "Living room",
            "explicit label maps by raw name");
        check(labeled.labels["SENSOR_B"] === "Shed",
            "second explicit label maps by raw name");

        var duplicate = Grafana.parseSensorList(
            "SENSOR_A=House, SENSOR_A=Shed");
        check(duplicate.names.length === 1, "duplicate names are merged");
        check(duplicate.labels["SENSOR_A"] === "Shed",
            "last label wins for a duplicate");

        var emptyName = Grafana.parseSensorList("=TEST, SENSOR_A");
        check(emptyName.names.length === 1
            && emptyName.names[0] === "SENSOR_A",
            "an entry without a name is ignored");

        check(Grafana.humanizeField("outdoor_c") === "Outdoor C",
            "snake_case field is humanized");
        check(Grafana.humanizeField("dewPoint") === "Dew Point",
            "camelCase field is humanized");
        check(Grafana.inferFormat("outdoor_c") === "temperature",
            "temperature suffix is inferred");
        check(Grafana.inferFormat("load2_btu") === "kbtu",
            "btu is inferred");
        check(Grafana.inferFormat("active_errors") === "raw",
            "unknown fields stay raw");

        check(Grafana.formatValue("temperature", 19.04) === "19.0 °C",
            "temperature format");
        check(Grafana.formatValue("humidity", 45.67) === "45.7 %",
            "humidity format");
        check(Grafana.formatValue("battery", 94.6) === "95 %",
            "battery format");
        check(Grafana.formatValue("kbtu", 45000) === "45 kBtu/h",
            "kBtu/h format");
        check(Grafana.formatValue("count", 3.4) === "3",
            "connection count format");
        check(Grafana.formatValue("raw", 3.4) === "3.4", "raw format");
        check(Grafana.formatValue("temperature", null) === "–",
            "null format");
        check(Grafana.formatAge(now, now) === "just now", "age now");
        check(Grafana.formatAge(now - 120000, now) === "2 min ago",
            "age minutes");
        check(Grafana.formatAge(0, now) === "no data", "age missing");

        if (failures === 0) {
            console.log("All widget tests passed.");
        } else {
            console.error(failures + " widget test(s) failed.");
        }

        Qt.exit(failures === 0 ? 0 : 1);
    }
}
