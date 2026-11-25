.pragma library

var FIELDS = ["temperature", "humidity", "battery"];

// Friendly room names for the two sensors in the usual setup. Matching is on
// the trailing four characters, so the label survives a changed name prefix.
var SENSOR_LABELS = {
    "B6D2": "House",
    "E22C": "Garage"
};

/** Appends a room label to a known sensor name, or returns it unchanged. */
function sensorDisplayName(name) {
    var text = String(name === null || name === undefined ? "" : name);
    var match = /([0-9a-f]{4})$/i.exec(text);
    var label = match ? SENSOR_LABELS[match[1].toUpperCase()] : "";

    return label ? text + " (" + label + ")" : text;
}

/**
 * Parses the Sensor names setting. Each entry is the raw `name` tag, optionally
 * followed by `=Label` to override the built-in display label:
 * "GVH5075_B6D2=House, GVH5075_E22C". Only the part before `=` is queried, so a
 * label can never turn into a sensor name that matches nothing in InfluxDB.
 * Returns the unique names in configured order and a name-to-label map.
 */
function parseSensorList(raw) {
    var parts = String(raw === null || raw === undefined ? "" : raw)
        .split(",");
    var names = [];
    var labels = {};

    for (var i = 0; i < parts.length; i++) {
        var entry = parts[i].trim();

        if (entry.length === 0) {
            continue;
        }

        var eq = entry.indexOf("=");
        var name = eq >= 0 ? entry.substring(0, eq).trim() : entry;
        var label = eq >= 0 ? entry.substring(eq + 1).trim() : "";

        if (name.length === 0) {
            continue;
        }

        if (names.indexOf(name) < 0) {
            names.push(name);
        }

        if (label.length > 0) {
            labels[name] = label;
        }
    }

    return {names: names, labels: labels};
}

/**
 * Parses the Outside temperature setting. The form is
 * "measurement|tag=value|field" or "measurement|field" without a tag. Returns
 * null when the setting is empty or malformed, which hides the outside row
 * instead of sending a broken query. The tag key becomes part of the Flux
 * expression, so it is limited to an identifier.
 */
function parseOutsideSource(raw) {
    var text = String(raw === null || raw === undefined ? "" : raw).trim();

    if (text.length === 0) {
        return null;
    }

    var parts = text.split("|");

    if (parts.length < 2 || parts.length > 3) {
        return null;
    }

    var measurement = parts[0].trim();
    var field = parts[parts.length - 1].trim();
    var tag = parts.length === 3 ? parts[1].trim() : "";
    var tagKey = "";
    var tagValue = "";

    if (measurement.length === 0 || field.length === 0) {
        return null;
    }

    if (tag.length > 0) {
        var eq = tag.indexOf("=");

        if (eq <= 0) {
            return null;
        }

        tagKey = tag.substring(0, eq).trim();
        tagValue = tag.substring(eq + 1).trim();

        if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(tagKey)
                || tagValue.length === 0) {
            return null;
        }
    }

    return {
        "measurement": measurement,
        "tagKey": tagKey,
        "tagValue": tagValue,
        "field": field
    };
}

/** Escapes a value for use inside a double-quoted Flux string. */
function escapeFlux(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/\\/g, "\\\\")
        .replace(/"/g, "\\\"");
}

/** Flux that returns the newest temperature/humidity/battery point per name. */
function buildFlux(bucket, measurement, names) {
    var lines = [
        "from(bucket: \"" + escapeFlux(bucket) + "\")",
        "  |> range(start: -24h)",
        "  |> filter(fn: (r) => r._measurement == \"" + escapeFlux(measurement) + "\")",
        "  |> filter(fn: (r) => r._field == \"temperature\""
            + " or r._field == \"humidity\" or r._field == \"battery\")"
    ];

    if (names && names.length > 0) {
        var filters = [];

        for (var i = 0; i < names.length; i++) {
            filters.push("r.name == \"" + escapeFlux(names[i]) + "\"");
        }

        lines.push("  |> filter(fn: (r) => " + filters.join(" or ") + ")");
    }

    lines.push("  |> group(columns: [\"name\"])");
    lines.push("  |> pivot(rowKey: [\"_time\"], columnKey: [\"_field\"],"
        + " valueColumn: \"_value\")");
    lines.push("  |> sort(columns: [\"_time\"])");
    lines.push("  |> tail(n: 1)");
    lines.push("  |> keep(columns: [\"name\", \"_time\", \"temperature\","
        + " \"humidity\", \"battery\"])");

    return lines.join("\n");
}

/** Flux that returns the newest point of the outside-temperature field. */
function buildOutsideFlux(bucket, source) {
    var conditions = [
        "r._measurement == \"" + escapeFlux(source.measurement) + "\""
    ];

    if (source.tagKey.length > 0) {
        conditions.push("r." + source.tagKey + " == \""
            + escapeFlux(source.tagValue) + "\"");
    }

    var lines = [
        "from(bucket: \"" + escapeFlux(bucket) + "\")",
        "  |> range(start: -24h)",
        "  |> filter(fn: (r) => " + conditions.join(" and ") + ")",
        "  |> filter(fn: (r) => r._field == \""
            + escapeFlux(source.field) + "\")",
        "  |> sort(columns: [\"_time\"])",
        "  |> tail(n: 1)",
        "  |> keep(columns: [\"_time\", \"_value\"])"
    ];

    return lines.join("\n");
}

/** Body for Grafana's /api/ds/query endpoint. */
function queryBody(options) {
    var datasource = {
        "type": "influxdb",
        "uid": options.datasourceUid
    };
    var queries = [{
        "refId": "A",
        "datasource": datasource,
        "query": buildFlux(options.bucket, options.measurement,
            options.names || []),
        "rawQuery": true,
        "resultFormat": "time_series"
    }];

    if (options.outside) {
        queries.push({
            "refId": "B",
            "datasource": datasource,
            "query": buildOutsideFlux(options.bucket, options.outside),
            "rawQuery": true,
            "resultFormat": "time_series"
        });
    }

    return {
        "queries": queries,
        "from": "now-24h",
        "to": "now",
        "intervalMs": 60000,
        "maxDataPoints": 100
    };
}

/**
 * Turns a configured Grafana URL into a base URL. A pasted /api/ds/query
 * suffix is removed so the endpoint is never appended twice.
 */
function normalizeBaseUrl(baseUrl) {
    var base = String(baseUrl === null || baseUrl === undefined ? "" : baseUrl)
        .trim();
    var endpoint = "/api/ds/query";

    while (base.length > 1 && base.charAt(base.length - 1) === "/") {
        base = base.substring(0, base.length - 1);
    }

    if (base.slice(-endpoint.length) === endpoint) {
        base = base.substring(0, base.length - endpoint.length);

        while (base.length > 1 && base.charAt(base.length - 1) === "/") {
            base = base.substring(0, base.length - 1);
        }
    }

    return base;
}

/** True when the configured URL is a public dashboard link, not a base URL. */
function isPublicDashboardUrl(baseUrl) {
    return /\/public-dashboards\/[0-9a-f]{32}$/i.test(
        normalizeBaseUrl(baseUrl));
}

/** Grafana's data source query endpoint. */
function apiUrl(baseUrl) {
    return normalizeBaseUrl(baseUrl) + "/api/ds/query";
}

/**
 * URL to hand to the desktop browser. Only http(s) is accepted so a stray
 * file:// or other scheme in the settings cannot be launched by a double
 * click. A pasted /api/ds/query suffix is stripped like everywhere else.
 */
function browserUrl(baseUrl) {
    var url = normalizeBaseUrl(baseUrl);

    return /^https?:\/\/\S+$/i.test(url) ? url : "";
}

/** Quotes a value for /bin/sh so it is passed through unchanged. */
function shellQuote(value) {
    return "'" + String(value === null || value === undefined ? "" : value)
        .replace(/'/g, "'\\''") + "'";
}

/** True unless proxy bypass was explicitly switched off. */
function shouldBypassProxy(options) {
    var value = options === null || options === undefined
        ? undefined : options.bypassProxy;

    if (value === undefined || value === null || typeof value === "boolean") {
        return value !== false;
    }

    var text = String(value).trim().toLowerCase();

    return text !== "false" && text !== "0" && text !== "no"
        && text !== "off";
}

/**
 * Builds a curl command for /api/ds/query. With proxy bypass enabled, the
 * proxy variables and LD_PRELOAD (proxychains) are removed from the child
 * process and curl is told not to use a proxy. The executable data engine runs
 * this through /bin/sh, so every dynamic value is single-quoted.
 */
function buildCurlCommand(options) {
    var bypass = shouldBypassProxy(options);
    var args = ["env"];

    if (bypass) {
        args.push("-u", "LD_PRELOAD",
            "-u", "http_proxy", "-u", "https_proxy", "-u", "all_proxy",
            "-u", "HTTP_PROXY", "-u", "HTTPS_PROXY", "-u", "ALL_PROXY");
    }

    args.push("curl", "-sS");

    if (bypass) {
        args.push("--noproxy", "'*'");
    }

    args.push("--max-time", "15",
        "-H", "'Content-Type: application/json'",
        "-H", "'Accept: application/json'",
        "-w", "'\\n%{http_code} %{remote_ip} %{remote_port}"
            + " %{content_type}'",
        "--data-binary", shellQuote(JSON.stringify(queryBody(options))));

    var token = String(options.token === null || options.token === undefined
        ? "" : options.token).trim();

    if (token.length > 0) {
        args.push("-H", shellQuote("Authorization: Bearer " + token));
    }

    args.push(shellQuote(apiUrl(options.grafanaUrl)));

    return args.join(" ");
}

/**
 * Turns the executable engine's result into the same shape as parseResponse.
 * curl's -w adds the HTTP status, the peer it actually talked to and the
 * response content type as the last line of stdout.
 */
function parseCurlOutput(data, configuredNames, url, outsideConfigured) {
    var stdout = String(data && data.stdout !== undefined ? data.stdout : "");
    var stderr = String(data && data.stderr !== undefined ? data.stderr : "")
        .trim();
    var split = stdout.lastIndexOf("\n");
    var body = split >= 0 ? stdout.substring(0, split) : "";
    var meta = split >= 0 ? stdout.substring(split + 1).trim() : "";
    var match = /^(\d+)(?:\s+(\S+)\s+(\S+))?(?:\s+(.*))?$/.exec(meta);
    var status = match ? parseInt(match[1], 10) : 0;

    if (status === 0) {
        var message = "Could not reach Grafana.";

        if (stderr.length > 0) {
            message += " " + stderr;
        }

        return {
            "error": message,
            "rows": [],
            "status": 0,
            "outside": outsideConfigured ? missingOutside() : null
        };
    }

    var remote = match && match[2]
        ? match[2] + (match[3] ? ":" + match[3] : "")
        : "";
    var context = {
        "contentType": (match && match[4]) || "",
        "remote": remote,
        "url": url || ""
    };
    var result = parseResponse(status, body, configuredNames, context,
        outsideConfigured);

    result.status = status;

    return result;
}


function serverError(payload) {
    if (!payload) {
        return "";
    }

    if (payload.results && payload.results.A && payload.results.A.error) {
        return String(payload.results.A.error);
    }

    if (payload.message) {
        return String(payload.message);
    }

    if (payload.error) {
        return String(payload.error);
    }

    return "";
}

/** Compact, tag-free excerpt of a non-JSON error body (proxy/HTML pages). */
function bodySnippet(text) {
    var raw = String(text === null || text === undefined ? "" : text)
        .replace(/<[^>]*>/g, " ")
        .replace(/\s+/g, " ")
        .trim();

    if (raw.length > 180) {
        raw = raw.substring(0, 177) + "...";
    }

    return raw;
}

/**
 * Builds the message for a non-200 answer. `context` says which peer replied
 * and how, which is what separates a Grafana error from a proxy page: Grafana
 * always answers with JSON, a proxy or ingress usually answers with HTML or
 * with no body at all.
 */
function httpError(status, payload, text, context) {
    var ctx = context || {};
    var detail = serverError(payload);
    var where = ctx.remote ? " from " + ctx.remote : "";
    var jsonType = String(ctx.contentType || "").indexOf("json") >= 0;
    var proxied = payload === null && !jsonType;
    var message;
    var appendDetail = true;

    if (status === 401 || status === 403) {
        var reason = detail.length > 0 ? detail : bodySnippet(text);

        if (reason.toLowerCase().indexOf("invalid api key") >= 0) {
            message = "Grafana rejected the API token (HTTP " + status
                + where + "). A public dashboard share token is not an API"
                + " token — create a service account token with the Viewer"
                + " role and use that here.";
        } else {
            message = "Grafana refused access (HTTP " + status + where
                + "). This server needs a Grafana service account token;"
                + " public dashboard tokens cannot query the API. Check the"
                + " API token and its datasource permissions.";
        }

        appendDetail = false;
    } else if (status === 404) {
        message = "Grafana could not find the API or datasource (HTTP 404"
            + where + "). Check the Grafana URL and Datasource UID.";
    } else if (status === 502 || status === 503 || status === 504) {
        message = "Grafana returned HTTP " + status + where + ".";

        if (proxied) {
            message += " That reply did not come from Grafana — a proxy,"
                + " ingress or load balancer in front of it is answering"
                + " instead.";

            if (ctx.url) {
                message += " Requested " + ctx.url + ".";
            }
        }
    } else {
        message = "Grafana returned HTTP " + status + where + ".";
    }

    if (detail.length === 0) {
        detail = bodySnippet(text);
    }

    if (appendDetail && detail.length > 0) {
        message += " " + detail;
    }

    return message;
}

/**
 * Converts a /api/ds/query response into widget rows, in the order the
 * sensors are configured. A configured sensor without a recent point is kept
 * as a "missing" row so the widget does not silently hide a dead sensor.
 * When `outsideConfigured` is set, the same is done for the outside reading
 * returned by query B; `outside` is null when no outside source is configured.
 */
function parseResponse(status, text, configuredNames, context,
        outsideConfigured) {
    var noOutside = outsideConfigured ? missingOutside() : null;

    if (status === 0) {
        return {
            "error": "Could not reach Grafana.",
            "rows": [],
            "outside": noOutside
        };
    }

    if (status !== 200) {
        var failure = null;

        try {
            failure = JSON.parse(text);
        } catch (e) {
        }

        return {
            "error": httpError(status, failure, text, context),
            "rows": [],
            "outside": noOutside
        };
    }

    var payload;

    try {
        payload = JSON.parse(text);
    } catch (e) {
        return {
            "error": "Grafana returned invalid JSON.",
            "rows": [],
            "outside": noOutside
        };
    }

    var outside = outsideFromResults(payload, outsideConfigured);
    var result = payload && payload.results ? payload.results.A : null;

    if (!result) {
        return {
            "error": "Grafana returned no query results.",
            "rows": [],
            "outside": outside
        };
    }

    if (result.error) {
        return {"error": String(result.error), "rows": [], "outside": outside};
    }

    if (result.status && result.status !== 200) {
        return {
            "error": httpError(result.status, result, "", context),
            "rows": [],
            "outside": outside
        };
    }

    var frames = result.frames || [];
    var found = {};

    for (var i = 0; i < frames.length; i++) {
        var row = rowFromFrame(frames[i]);

        // The test button publishes under this name; never show it as a sensor.
        if (!row || row.name === "TEST") {
            continue;
        }

        if (found[row.name]) {
            mergeRow(found[row.name], row);
        } else {
            found[row.name] = row;
        }
    }

    var names = configuredNames || [];
    var rows = [];

    for (var j = 0; j < names.length; j++) {
        rows.push(found[names[j]] || missingRow(names[j]));
    }

    if (names.length === 0) {
        var discovered = Object.keys(found).sort();

        for (var k = 0; k < discovered.length; k++) {
            rows.push(found[discovered[k]]);
        }
    }

    return {"error": "", "rows": rows, "outside": outside};
}

/**
 * Reads query B's single frame. A failed or empty outside query leaves the
 * sensor rows intact and shows the outside row as "no data".
 */
function outsideFromResults(payload, configured) {
    if (!configured) {
        return null;
    }

    var result = payload && payload.results ? payload.results.B : null;
    var frames = result && !result.error ? result.frames || [] : [];
    var reading = null;

    for (var i = 0; i < frames.length && !reading; i++) {
        reading = outsideFromFrame(frames[i]);
    }

    return reading || missingOutside();
}

function outsideFromFrame(frame) {
    var schema = frame && frame.schema;
    var data = frame && frame.data;

    if (!schema || !data || !schema.fields || !data.values) {
        return null;
    }

    var fields = schema.fields;
    var columns = data.values;
    var timeIndex = -1;
    var valueIndex = -1;

    for (var i = 0; i < fields.length; i++) {
        var key = String((fields[i] || {}).name || "").toLowerCase();

        if (timeIndex < 0 && (key === "time" || key === "_time")) {
            timeIndex = i;
        } else if (valueIndex < 0
                && (key === "_value" || key === "value")) {
            valueIndex = i;
        }
    }

    // Grafana sometimes names the column after the Flux field instead of
    // "_value"; accept any other numeric column when the usual names are gone.
    if (valueIndex < 0) {
        for (var j = 0; j < fields.length; j++) {
            if (j !== timeIndex && numberOrNull(columns, j) !== null) {
                valueIndex = j;
                break;
            }
        }
    }

    if (valueIndex < 0) {
        return null;
    }

    var temperature = numberOrNull(columns, valueIndex);

    if (temperature === null) {
        return null;
    }

    return {
        "temperature": temperature,
        "timestamp": timeIndex < 0
            ? 0 : toMillis(lastValue(columns[timeIndex])),
        "missing": false
    };
}

function missingOutside() {
    return {
        "temperature": null,
        "timestamp": 0,
        "missing": true
    };
}

function rowFromFrame(frame) {
    var schema = frame && frame.schema;
    var data = frame && frame.data;

    if (!schema || !data || !schema.fields || !data.values) {
        return null;
    }

    var fields = schema.fields;
    var columns = data.values;
    var index = {};
    var name = "";

    for (var i = 0; i < fields.length; i++) {
        var field = fields[i] || {};
        var key = String(field.name || "").toLowerCase();

        index[key] = i;

        if (!name && field.labels && field.labels.name) {
            name = String(field.labels.name);
        }
    }

    var timeIndex = index["time"] !== undefined
        ? index["time"]
        : index["_time"];

    if (!name && index["name"] !== undefined) {
        var columnName = lastValue(columns[index["name"]]);
        name = columnName === null ? "" : String(columnName);
    }

    if (!name) {
        return null;
    }

    var row = {
        "name": name,
        "temperature": numberOrNull(columns, index["temperature"]),
        "humidity": numberOrNull(columns, index["humidity"]),
        "battery": numberOrNull(columns, index["battery"]),
        "timestamp": timeIndex === undefined
            ? 0
            : toMillis(lastValue(columns[timeIndex])),
        "missing": false
    };

    if (row.temperature === null && row.humidity === null
            && row.battery === null) {
        row.missing = true;
        row.timestamp = 0;
    }

    return row;
}

function numberOrNull(columns, columnIndex) {
    if (columnIndex === undefined) {
        return null;
    }

    var value = lastValue(columns[columnIndex]);

    if (value === null) {
        return null;
    }

    var number = Number(value);

    return isFinite(number) ? number : null;
}

/** Last non-null/non-empty entry in a frame column. */
function lastValue(column) {
    if (!column) {
        return null;
    }

    for (var i = column.length - 1; i >= 0; i--) {
        var value = column[i];

        if (value === null || value === undefined || value === "") {
            continue;
        }

        if (typeof value === "number" && isNaN(value)) {
            continue;
        }

        return value;
    }

    return null;
}

function toMillis(value) {
    if (typeof value === "number") {
        return value;
    }

    if (typeof value === "string") {
        var parsed = Date.parse(value);

        return isNaN(parsed) ? 0 : parsed;
    }

    return 0;
}

function missingRow(name) {
    return {
        "name": name,
        "temperature": null,
        "humidity": null,
        "battery": null,
        "timestamp": 0,
        "missing": true
    };
}

/**
 * Merges frames that carry different fields for the same sensor, in case the
 * datasource splits them instead of returning one pivoted table per name.
 */
function mergeRow(target, source) {
    var fields = ["temperature", "humidity", "battery"];

    for (var i = 0; i < fields.length; i++) {
        var key = fields[i];

        if (target[key] === null && source[key] !== null) {
            target[key] = source[key];
        }
    }

    target.timestamp = Math.max(target.timestamp, source.timestamp);
    target.missing = target.temperature === null
        && target.humidity === null && target.battery === null;
}

/**
 * Dew point in °C from temperature (°C) and relative humidity (%). Uses the
 * Magnus-Tetens approximation; returns null when either value is unusable.
 */
function dewPoint(temperature, humidity) {
    if (temperature === null || temperature === undefined
            || humidity === null || humidity === undefined) {
        return null;
    }

    var t = Number(temperature);
    var rh = Number(humidity);

    if (!isFinite(t) || !isFinite(rh) || rh <= 0 || rh > 100
            || t <= -243.12) {
        return null;
    }

    var b = 17.62;
    var c = 243.12;
    var gamma = Math.log(rh / 100) + (b * t) / (c + t);

    return (c * gamma) / (b - gamma);
}

function formatTemperature(value) {
    return value === null || value === undefined
        ? "–"
        : Number(value).toFixed(1) + " °C";
}

function formatHumidity(value) {
    return value === null || value === undefined
        ? "–"
        : Number(value).toFixed(1) + " %";
}

function formatBattery(value) {
    return value === null || value === undefined
        ? "–"
        : Math.round(Number(value)) + " %";
}

function formatAge(timestamp, nowMs) {
    if (!timestamp) {
        return "no data";
    }

    var seconds = Math.max(0, Math.round((nowMs - timestamp) / 1000));

    if (seconds < 60) {
        return "just now";
    }

    var minutes = Math.floor(seconds / 60);

    if (minutes < 60) {
        return minutes + " min ago";
    }

    var hours = Math.floor(minutes / 60);

    if (hours < 48) {
        return hours + (hours === 1 ? " hour ago" : " hours ago");
    }

    var days = Math.floor(hours / 24);

    return days + (days === 1 ? " day ago" : " days ago");
}
