.pragma library

/*
 * Grafana/Flux helpers for the SensorBridge widget.
 *
 * The widget's config describes the data: sensor names, sensor columns, and
 * an ordered list of extra single-value readings. Nothing about a particular
 * measurement, sensor or label is built into this file.
 */

// Values accepted by the `format` field of sensorFields/extraReadings.
var FORMATS = ["temperature", "humidity", "battery", "kbtu", "count", "raw"];

// Values accepted by the `color` field of an extra reading.
var COLORS = ["none", "negative", "positive"];

var ALIGNMENTS = ["left", "right"];

/** "outdoor_c" / "dewPoint" -> "Outdoor C" / "Dew Point". */
function humanizeField(name) {
    var text = String(name === null || name === undefined ? "" : name)
        .trim();
    var words;
    var i;

    if (text.length === 0) {
        return "";
    }

    text = text.replace(/[_.\-]+/g, " ");
    text = text.replace(/([a-z0-9])([A-Z])/g, "$1 $2");
    words = text.split(/\s+/);

    for (i = 0; i < words.length; i++) {
        if (words[i].length > 0) {
            words[i] = words[i].charAt(0).toUpperCase()
                + words[i].substring(1);
        }
    }

    return words.join(" ");
}

/** Best-effort format for a field when the config does not name one. */
function inferFormat(field) {
    var key = String(field === null || field === undefined ? "" : field)
        .toLowerCase();

    if (key === "dewpoint" || key.indexOf("dew") === 0) {
        return "temperature";
    }

    if (key.indexOf("humidity") >= 0) {
        return "humidity";
    }

    if (key.indexOf("battery") >= 0 || key === "batt") {
        return "battery";
    }

    if (key.indexOf("temp") >= 0 || /_[cf]$/.test(key)) {
        return "temperature";
    }

    if (key.indexOf("btu") >= 0) {
        return "kbtu";
    }

    return "raw";
}

/** Normalises a configured format, falling back to the field's guess. */
function normalizeFormat(value, field) {
    var text = String(value === null || value === undefined ? "" : value)
        .trim().toLowerCase();

    return FORMATS.indexOf(text) >= 0 ? text : inferFormat(field);
}

function normalizeColor(value) {
    var text = String(value === null || value === undefined ? "" : value)
        .trim().toLowerCase();

    return COLORS.indexOf(text) >= 0 ? text : "none";
}

function normalizeAlign(value) {
    var text = String(value === null || value === undefined ? "" : value)
        .trim().toLowerCase();

    return text === "right" || text === "end" ? "right" : "left";
}

/**
 * Parses the Sensor names setting. Each entry is the raw `name` tag, optionally
 * followed by `=Label` to set the display label:
 * "sensor-a=House, sensor-b". Only the part before `=` is queried, so a label
 * can never turn into a sensor name that matches nothing in InfluxDB.
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
 * Parses an extra reading's source. The form is
 * "measurement|tag=value|field" or "measurement|field" without a tag. Returns
 * null when the setting is empty or malformed, which hides that reading
 * instead of sending a broken query. The tag key becomes part of the Flux
 * expression, so it is limited to an identifier.
 */
function parseSideSource(raw) {
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

/**
 * Parses the JSON `extraReadings` setting:
 *
 *   [{"label":"Outside","source":"m|tag=v|field",
 *     "format":"temperature","color":"none","align":"left"}]
 *
 * A bare string source is accepted too. Invalid sources are dropped instead
 * of sending a broken query. The returned entries carry both the original
 * source text (for the Configure editor) and the parsed source (for queries).
 */
function parseExtraReadings(raw) {
    var text = String(raw === null || raw === undefined ? "" : raw).trim();
    var list;
    var extras = [];

    if (text.length === 0) {
        return extras;
    }

    try {
        list = JSON.parse(text);
    } catch (e) {
        return extras;
    }

    if (!list || typeof list.length !== "number") {
        return extras;
    }

    for (var i = 0; i < list.length; i++) {
        var item = list[i];
        var sourceText = "";
        var label = "";
        var format = "";
        var color = "";
        var align = "";

        if (typeof item === "string") {
            sourceText = item;
        } else if (item && typeof item === "object") {
            sourceText = String(item.source === undefined
                || item.source === null ? "" : item.source).trim();
            label = String(item.label === undefined
                || item.label === null ? "" : item.label).trim();
            format = String(item.format === undefined
                || item.format === null ? "" : item.format).trim();
            color = String(item.color === undefined
                || item.color === null ? "" : item.color).trim();
            align = String(item.align === undefined
                || item.align === null ? "" : item.align).trim();
        } else {
            continue;
        }

        var source = parseSideSource(sourceText);

        if (!source) {
            continue;
        }

        extras.push({
            "label": label.length > 0 ? label : humanizeField(source.field),
            "sourceText": sourceText,
            "source": source,
            "format": normalizeFormat(format, source.field),
            "color": normalizeColor(color),
            "align": normalizeAlign(align)
        });
    }

    return extras;
}

/**
 * Parses the JSON `sensorFields` setting. Each entry describes one column of
 * a sensor row. `field` may be `dewPoint`, which is derived from the
 * temperature and humidity fields rather than queried. An empty array means
 * "use every numeric field the datasource returns".
 */
function parseSensorFields(raw) {
    var text = String(raw === null || raw === undefined ? "" : raw).trim();
    var list;
    var fields = [];
    var seen = {};

    if (text.length === 0) {
        return fields;
    }

    try {
        list = JSON.parse(text);
    } catch (e) {
        return fields;
    }

    if (!list || typeof list.length !== "number") {
        return fields;
    }

    for (var i = 0; i < list.length; i++) {
        var item = list[i];
        var field = "";
        var label = "";
        var format = "";
        var align = "";

        if (typeof item === "string") {
            field = item.trim();
        } else if (item && typeof item === "object") {
            field = String(item.field === undefined
                || item.field === null ? "" : item.field).trim();
            label = String(item.label === undefined
                || item.label === null ? "" : item.label).trim();
            format = String(item.format === undefined
                || item.format === null ? "" : item.format).trim();
            align = String(item.align === undefined
                || item.align === null ? "" : item.align).trim();
        } else {
            continue;
        }

        if (field.length === 0 || seen[field.toLowerCase()]) {
            continue;
        }

        seen[field.toLowerCase()] = true;
        fields.push({
            "field": field,
            "label": label.length > 0 ? label : humanizeField(field),
            "format": normalizeFormat(format, field),
            "align": normalizeAlign(align)
        });
    }

    return fields;
}

/**
 * Turns the fields found in the response into a sensorFields list, preserving
 * any columns the user already configured. Dew point is appended when both
 * temperature and humidity are present.
 */
function deriveSensorFields(rows, existing) {
    var fields = [];
    var known = {};
    var seen = {};
    var i;
    var j;

    for (i = 0; existing && i < existing.length; i++) {
        fields.push({
            "field": existing[i].field,
            "label": existing[i].label,
            "format": existing[i].format,
            "align": existing[i].align
        });
        known[existing[i].field.toLowerCase()] = true;
    }

    for (i = 0; rows && i < rows.length; i++) {
        var rowFields = rows[i].fields || [];

        for (j = 0; j < rowFields.length; j++) {
            var name = rowFields[j];
            var key = name.toLowerCase();

            if (known[key] || seen[key]) {
                continue;
            }

            seen[key] = true;
            fields.push({
                "field": name,
                "label": humanizeField(name),
                "format": inferFormat(name),
                "align": "left"
            });
        }
    }

    if ((known.temperature || seen.temperature)
            && (known.humidity || seen.humidity)
            && !known.dewpoint && !seen.dewpoint) {
        fields.push({
            "field": "dewPoint",
            "label": humanizeField("dewPoint"),
            "format": "temperature",
            "align": "left"
        });
    }

    return fields;
}

/** Escapes a value for use inside a double-quoted Flux string. */
function escapeFlux(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/\\/g, "\\\\")
        .replace(/"/g, "\\\"");
}

/**
 * Flux that returns the newest point per name. With configured fields it
 * filters and keeps just those fields; with none it returns every field so
 * the widget can discover the columns.
 */
function buildFlux(bucket, measurement, names, fields) {
    var queryFields = [];
    var lines = [
        "from(bucket: \"" + escapeFlux(bucket) + "\")",
        "  |> range(start: -24h)",
        "  |> filter(fn: (r) => r._measurement == \""
            + escapeFlux(measurement) + "\")"
    ];

    for (var i = 0; fields && i < fields.length; i++) {
        var field = String(fields[i].field === undefined
            ? fields[i] : fields[i].field);

        if (field.toLowerCase() !== "dewpoint") {
            queryFields.push(field);
        }
    }

    if (queryFields.length > 0) {
        var fieldFilters = [];

        for (var j = 0; j < queryFields.length; j++) {
            fieldFilters.push("r._field == \"" + escapeFlux(queryFields[j])
                + "\"");
        }

        lines.push("  |> filter(fn: (r) => " + fieldFilters.join(" or ") + ")");
    }

    if (names && names.length > 0) {
        var filters = [];

        for (var k = 0; k < names.length; k++) {
            filters.push("r.name == \"" + escapeFlux(names[k]) + "\"");
        }

        lines.push("  |> filter(fn: (r) => " + filters.join(" or ") + ")");
    }

    lines.push("  |> group(columns: [\"name\"])");
    lines.push("  |> pivot(rowKey: [\"_time\"], columnKey: [\"_field\"],"
        + " valueColumn: \"_value\")");
    lines.push("  |> sort(columns: [\"_time\"])");
    lines.push("  |> tail(n: 1)");

    if (queryFields.length > 0) {
        var kept = ["\"name\"", "\"_time\""];

        for (var m = 0; m < queryFields.length; m++) {
            kept.push("\"" + escapeFlux(queryFields[m]) + "\"");
        }

        lines.push("  |> keep(columns: [" + kept.join(", ") + "])");
    }

    return lines.join("\n");
}

/** Flux that returns the newest point of one extra reading's field. */
function buildSideFlux(bucket, source) {
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

/** Query refId for extra reading `index`: B, C, ... Z, AA, AB, ... */
function refIdFor(index) {
    var n = index + 2;
    var id = "";

    while (n > 0) {
        var remainder = (n - 1) % 26;

        id = String.fromCharCode(65 + remainder) + id;
        n = Math.floor((n - 1) / 26);
    }

    return id;
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
            options.names || [], options.fields || []),
        "rawQuery": true,
        "resultFormat": "time_series"
    }];
    var extras = options.extras || [];

    for (var i = 0; i < extras.length; i++) {
        var source = extras[i] && extras[i].source
            ? extras[i].source : extras[i];

        if (!source || !source.measurement) {
            continue;
        }

        queries.push({
            "refId": refIdFor(i),
            "datasource": datasource,
            "query": buildSideFlux(options.bucket, source),
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
function parseCurlOutput(data, configuredNames, url, extras, fields) {
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
            "sides": missingSides(extras)
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
    var result = parseResponse(status, body, configuredNames, context, extras,
        fields);

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
 * When no sensors are configured every name found in the response is shown,
 * which is what discovery uses.
 *
 * `extras` is the ordered list from parseExtraReadings; `sides` in the result
 * is a parallel array of readings. `fields` is the sensorFields list; with an
 * empty list the columns are discovered from the response.
 */
function parseResponse(status, text, configuredNames, context, extras, fields) {
    var noSides = missingSides(extras);

    if (status === 0) {
        return {
            "error": "Could not reach Grafana.",
            "rows": [],
            "sides": noSides
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
            "sides": noSides
        };
    }

    var payload;

    try {
        payload = JSON.parse(text);
    } catch (e) {
        return {
            "error": "Grafana returned invalid JSON.",
            "rows": [],
            "sides": noSides
        };
    }

    var readings = sidesFromResults(payload, extras);
    var result = payload && payload.results ? payload.results.A : null;

    if (!result) {
        return {
            "error": "Grafana returned no query results.",
            "rows": [],
            "sides": readings
        };
    }

    if (result.error) {
        return {"error": String(result.error), "rows": [], "sides": readings};
    }

    if (result.status && result.status !== 200) {
        return {
            "error": httpError(result.status, result, "", context),
            "rows": [],
            "sides": readings
        };
    }

    var frames = result.frames || [];
    var found = {};

    for (var i = 0; i < frames.length; i++) {
        var row = rowFromFrame(frames[i], fields);

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
        rows.push(found[names[j]] || missingRow(names[j], fields));
    }

    if (names.length === 0) {
        var discovered = Object.keys(found).sort();

        for (var k = 0; k < discovered.length; k++) {
            rows.push(found[discovered[k]]);
        }
    }

    columnsFor(rows, fields);

    return {"error": "", "rows": rows, "sides": readings};
}

/**
 * Builds each row's display columns. Configured fields keep their order and
 * labels; otherwise the fields returned by the datasource are used, with a
 * derived dew point when temperature and humidity are both present.
 */
function columnsFor(rows, configuredFields) {
    var defs = [];
    var seen = {};
    var i;
    var j;

    if (configuredFields && configuredFields.length > 0) {
        for (i = 0; i < configuredFields.length; i++) {
            defs.push({
                "field": configuredFields[i].field,
                "label": configuredFields[i].label,
                "format": configuredFields[i].format,
                "align": configuredFields[i].align || "left"
            });
        }
    } else {
        for (i = 0; rows && i < rows.length; i++) {
            var rowFields = rows[i].fields || [];

            for (j = 0; j < rowFields.length; j++) {
                var name = rowFields[j];
                var key = name.toLowerCase();

                if (seen[key]) {
                    continue;
                }

                seen[key] = true;
                defs.push({
                    "field": name,
                    "label": humanizeField(name),
                    "format": inferFormat(name),
                    "align": "left"
                });
            }
        }

        if (seen.temperature && seen.humidity && !seen.dewpoint) {
            defs.push({
                "field": "dewPoint",
                "label": humanizeField("dewPoint"),
                "format": "temperature",
                "align": "left"
            });
        }
    }

    for (i = 0; rows && i < rows.length; i++) {
        var columns = [];

        for (j = 0; j < defs.length; j++) {
            columns.push({
                "field": defs[j].field,
                "label": defs[j].label,
                "format": defs[j].format,
                "align": defs[j].align,
                "value": valueForField(rows[i], defs[j].field)
            });
        }

        rows[i].columns = columns;
    }

    return defs;
}

function valueForField(row, field) {
    var value;

    if (String(field).toLowerCase() === "dewpoint") {
        value = row.values ? row.values.dewPoint : null;

        if (value === undefined || value === null) {
            value = row.values
                ? dewPoint(row.values.temperature, row.values.humidity)
                : null;
        }

        return value === undefined ? null : value;
    }

    value = row.values ? row.values[field] : null;

    return value === undefined ? null : value;
}

/**
 * Reads one frame per configured extra reading. A failed or empty query leaves
 * the sensor rows intact and shows that reading as "no data".
 */
function sidesFromResults(payload, configured) {
    var readings = [];

    if (!configured || typeof configured.length !== "number") {
        return readings;
    }

    for (var i = 0; i < configured.length; i++) {
        var result = payload && payload.results
            ? payload.results[refIdFor(i)] : null;
        var frames = result && !result.error ? result.frames || [] : [];
        var reading = null;

        for (var j = 0; j < frames.length && !reading; j++) {
            reading = readingFromFrame(frames[j]);
        }

        readings.push(reading || missingReading());
    }

    return readings;
}

function readingFromFrame(frame) {
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

    var value = numberOrNull(columns, valueIndex);

    if (value === null) {
        return null;
    }

    return {
        "value": value,
        "timestamp": timeIndex < 0
            ? 0 : toMillis(lastValue(columns[timeIndex])),
        "missing": false
    };
}

function missingReading() {
    return {
        "value": null,
        "timestamp": 0,
        "missing": true
    };
}

/** One entry per configured extra reading; null marks a disabled reading. */
function missingSides(configured) {
    var readings = [];

    if (!configured) {
        return readings;
    }

    for (var i = 0; i < configured.length; i++) {
        readings.push(missingReading());
    }

    return readings;
}

function rowFromFrame(frame, configuredFields) {
    var schema = frame && frame.schema;
    var data = frame && frame.data;

    if (!schema || !data || !schema.fields || !data.values) {
        return null;
    }

    var fields = schema.fields;
    var columns = data.values;
    var index = {};
    var exact = {};
    var order = [];
    var name = "";

    for (var i = 0; i < fields.length; i++) {
        var field = fields[i] || {};
        var fieldName = String(field.name || "");
        var key = fieldName.toLowerCase();

        index[key] = i;
        exact[fieldName] = i;

        if (!name && field.labels && field.labels.name) {
            name = String(field.labels.name);
        }

        if (fieldName.length > 0 && key !== "time" && key !== "_time"
                && key !== "name") {
            order.push(fieldName);
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

    var values = {};
    var used = [];

    if (configuredFields && configuredFields.length > 0) {
        for (var j = 0; j < configuredFields.length; j++) {
            var configured = configuredFields[j];
            var configuredKey = String(configured.field).toLowerCase();

            if (configuredKey === "dewpoint") {
                values[configured.field] = null;
                continue;
            }

            var column = exact[configured.field] !== undefined
                ? exact[configured.field] : index[configuredKey];

            values[configured.field] = numberOrNull(columns, column);
            used.push(configured.field);
        }

        if (values.dewPoint !== undefined || hasDewPoint(configuredFields)) {
            values.dewPoint = dewPoint(values.temperature, values.humidity);
        }
    } else {
        for (var k = 0; k < order.length; k++) {
            var orderKey = order[k].toLowerCase();
            var value = numberOrNull(columns, index[orderKey]);

            if (value !== null) {
                values[order[k]] = value;
                used.push(order[k]);
            }
        }
    }

    var row = {
        "name": name,
        "values": values,
        "fields": used,
        "timestamp": timeIndex === undefined
            ? 0
            : toMillis(lastValue(columns[timeIndex])),
        "missing": valuesMissing(values)
    };

    copyValues(row, values);

    return row;
}

function hasDewPoint(fields) {
    for (var i = 0; fields && i < fields.length; i++) {
        if (String(fields[i].field).toLowerCase() === "dewpoint") {
            return true;
        }
    }

    return false;
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

function missingRow(name, fields) {
    var values = {};
    var used = [];

    for (var i = 0; fields && i < fields.length; i++) {
        values[fields[i].field] = null;
        used.push(fields[i].field);
    }

    var row = {
        "name": name,
        "values": values,
        "fields": used,
        "timestamp": 0,
        "missing": true
    };

    copyValues(row, values);

    return row;
}

/**
 * Merges frames that carry different fields for the same sensor, in case the
 * datasource splits them instead of returning one pivoted table per name.
 */
function mergeRow(target, source) {
    var key;

    for (key in source.values) {
        if (Object.prototype.hasOwnProperty.call(source.values, key)
                && (target.values[key] === null
                    || target.values[key] === undefined)
                && source.values[key] !== null) {
            target.values[key] = source.values[key];
        }
    }

    for (var i = 0; i < source.fields.length; i++) {
        if (target.fields.indexOf(source.fields[i]) < 0) {
            target.fields.push(source.fields[i]);
        }
    }

    target.timestamp = Math.max(target.timestamp, source.timestamp);
    target.missing = valuesMissing(target.values);
    copyValues(target, target.values);
}

function copyValues(row, values) {
    for (var key in values) {
        if (Object.prototype.hasOwnProperty.call(values, key)) {
            row[key] = values[key];
        }
    }
}

function valuesMissing(values) {
    for (var key in values) {
        if (Object.prototype.hasOwnProperty.call(values, key)
                && values[key] !== null && values[key] !== undefined) {
            return false;
        }
    }

    return true;
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

/** Formats a value according to one of the FORMATS entries. */
function formatValue(format, value) {
    var name = String(format === null || format === undefined ? "" : format)
        .toLowerCase();

    if (name === "temperature") {
        return formatTemperature(value);
    }

    if (name === "humidity") {
        return formatHumidity(value);
    }

    if (name === "battery") {
        return formatBattery(value);
    }

    if (name === "kbtu") {
        return formatKbtu(value);
    }

    if (name === "count") {
        return formatCount(value);
    }

    return formatRaw(value);
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

/** BTU/h (as written by the boiler collector) as thousands of BTU/h. */
function formatKbtu(value) {
    return value === null || value === undefined
        ? "–"
        : Math.round(Number(value) / 1000) + " kBtu/h";
}

/** Connection count, shown without a unit because the label names it. */
function formatCount(value) {
    return value === null || value === undefined
        ? "–"
        : String(Math.round(Number(value)));
}

/** Unformatted value for fields without a known unit. */
function formatRaw(value) {
    return value === null || value === undefined ? "–" : String(value);
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
