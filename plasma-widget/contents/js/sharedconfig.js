.pragma library

/*
 * Reads and writes SensorBridge's settings in ~/.config/sensorbridge so they
 * survive an applet being removed, re-added or upgraded. Plasma's own applet
 * config is tied to one applet instance, so removing the widget discards it.
 *
 * The file is only written after an explicit edit in the widget's Configure
 * dialog, never at launch. That keeps a stale file from overwriting newer
 * settings (the bug that lost a configuration in an earlier build).
 *
 * The executable data engine runs commands through /bin/sh. Only POSIX shell
 * utilities are used; kreadconfig6/kwriteconfig6 are not guaranteed to exist
 * in the Plasma runtime.
 */

var CONFIG_DIR = "${XDG_CONFIG_HOME:-$HOME/.config}";
var CONFIG_PATH = CONFIG_DIR + "/sensorbridge";
var SENTINEL = "configured";
var READ_DONE = "__SENSORBRIDGE_READ_DONE__";

var KEYS = ["grafanaUrl", "dashboardUrl", "apiToken", "datasourceUid",
    "bucket", "measurement", "sensors", "outside", "boilerHeat",
    "jfConnections", "refreshSeconds", "bypassProxy"];

/**
 * Reads the shared file. The marker is always printed so the executable
 * engine reports data even when the file does not exist.
 */
function readCommand() {
    return "cat \"" + CONFIG_PATH + "\" 2>/dev/null || true;"
        + " printf '\\n%s\\n' " + READ_DONE;
}

/** Parses the [General] group. Stops at the marker from readCommand(). */
function parseReadOutput(stdout) {
    var result = {configured: "", values: {}};
    var lines = String(stdout === null || stdout === undefined ? "" : stdout)
        .split("\n");

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\r$/, "").trim();

        if (line === READ_DONE) {
            break;
        }

        if (line.length === 0 || line.charAt(0) === "#"
                || line.charAt(0) === "[" || line.charAt(0) === ";") {
            continue;
        }

        var pos = line.indexOf("=");

        if (pos < 0) {
            continue;
        }

        var key = line.substring(0, pos).trim();
        // KConfig files are hand-edited in the form "key = value"; a leading
        // space here would end up inside bucket/measurement/uid and break the
        // query. Trim values, but keep spaces inside multi-value entries such
        // as the sensor list.
        var value = line.substring(pos + 1).trim();

        if (key === SENTINEL) {
            result.configured = value;
        } else if (KEYS.indexOf(key) >= 0) {
            result.values[key] = value;
        }
    }

    return result;
}

/**
 * True when the file carries settings. `configured=1` is the documented
 * marker, but a hand-written file with a recognised key is accepted too, so
 * forgetting the marker cannot silently discard a real configuration.
 */
function hasSavedConfig(parsed) {
    if (parsed === null || parsed === undefined) {
        return false;
    }

    var marker = String(parsed.configured).trim().toLowerCase();

    if (marker === "1" || marker === "true" || marker === "yes") {
        return true;
    }

    for (var key in parsed.values) {
        if (Object.prototype.hasOwnProperty.call(parsed.values, key)) {
            return true;
        }
    }

    return false;
}

/** Quotes a value for /bin/sh so it is passed through unchanged. */
function shellQuote(value) {
    return "'" + String(value === null || value === undefined ? "" : value)
        .replace(/'/g, "'\\''") + "'";
}

/** One line per key: a stray newline in a value must not add a fake entry. */
function cleanValue(value) {
    return String(value === null || value === undefined ? "" : value)
        .replace(/[\r\n]+/g, " ").trim();
}

/**
 * Builds the command that saves every effective setting. It is only run for
 * an explicit Configure edit, so writing the whole file cannot clobber newer
 * values with stale ones. The write goes through a temporary file and mv so
 * an interrupted save cannot leave a truncated config behind.
 */
function writeCommand(values) {
    var lines = ["[General]", SENTINEL + "=1"];

    for (var i = 0; i < KEYS.length; i++) {
        var key = KEYS[i];
        var value = values === null || values === undefined
            ? "" : values[key];

        lines.push(key + "=" + cleanValue(value));
    }

    var args = [];

    for (var j = 0; j < lines.length; j++) {
        args.push(shellQuote(lines[j]));
    }

    return "d=\"" + CONFIG_DIR + "\"; f=\"$d/sensorbridge\";"
        + " umask 077 && mkdir -p \"$d\""
        + " && printf '%s\\n' " + args.join(" ")
        + " > \"$f.tmp.$$\""
        + " && chmod 600 \"$f.tmp.$$\""
        + " && mv -f \"$f.tmp.$$\" \"$f\"";
}

/** Parses a KConfig-style boolean, falling back when the value is odd. */
function parseBool(value, fallback) {
    var text = String(value === null || value === undefined ? "" : value)
        .trim().toLowerCase();

    if (text === "true" || text === "1" || text === "yes" || text === "on") {
        return true;
    }

    if (text === "false" || text === "0" || text === "no" || text === "off") {
        return false;
    }

    return fallback === true;
}
