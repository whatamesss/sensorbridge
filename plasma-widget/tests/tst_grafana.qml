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

        check(Grafana.formatTemperature(19.04) === "19.0 °C",
            "temperature format");
        check(Grafana.formatHumidity(45.67) === "45.7 %", "humidity format");
        check(Grafana.formatBattery(94.6) === "95 %", "battery format");
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
