# SensorBridge Plasma widget

A KDE Plasma 6 desktop widget that shows the latest Govee H5075 readings from
Grafana. One row per sensor, with temperature, humidity, battery and the age of
the reading.

It queries Grafana's `/api/ds/query` endpoint using the configured InfluxDB
datasource, bucket and measurement. It does not need direct access to InfluxDB.

## Requirements

- Plasma 6
- Grafana with an InfluxDB v2 datasource (Flux queries)
- `curl` (proxy handling is configurable in the widget settings)
- A Grafana API token that can query that datasource, unless Grafana allows
  anonymous access

## Install

From this directory:

```sh
kpackagetool6 --type Plasma/Applet --install .
```

After changing the code, upgrade the installed copy with:

```sh
kpackagetool6 --type Plasma/Applet --upgrade .
```

Run `--upgrade .` from inside the package directory and pass only the path —
not the package name. If it reports that the plugin is not installed, use
`--install .` instead.

Remove it with:

```sh
kpackagetool6 --type Plasma/Applet --remove com.whatamesss.sensorbridge
```

Then add **SensorBridge** to the desktop from Plasma's widget chooser.

## Configure

Right-click the widget and choose **Configure**:

| Setting | Default | Notes |
| --- | --- | --- |
| Grafana URL | `http://grafana:3000` | Base URL, including any subpath — **not** a `/public-dashboards/…` link |
| Service account token | empty | Grafana service account token; leave empty only for anonymous Grafana |
| Datasource UID | `influxdb` | UID from the datasource settings page |
| InfluxDB bucket | `sensors` | Bucket fed by Telegraf |
| Measurement | `mqtt_consumer` | Measurement written by Telegraf |
| Sensor names | `GVH5075_B6D2,GVH5075_E22C` | Comma-separated `name` tag values; empty shows all |
| Refresh interval | 60 s | Minimum 10 s |
| Bypass system proxy | on | Turn off to let `curl` use the session's proxy settings |

To create a token: **Administration → Users and access → Service accounts**,
create an account with the **Viewer** role, then add a token to it.

The token in a `/public-dashboards/<token>` URL is *not* a Grafana API token.
It only authorises the public dashboard's own endpoints; sending it as
`Authorization: Bearer …` to `/api/ds/query` gives `401 Invalid API key`. Use
the base URL (`http://grafana:3000`) in the widget, not the public dashboard
link. The widget flags both mistakes in its settings.

The token is stored in plain text in the applet's configuration (in
`~/.config/plasma-org.kde.plasma.desktop-appletsrc`). Use a read-only token
scoped to this purpose. If you remove and re-add the applet, that new applet
gets fresh defaults, so the token field will be empty again.

## How it works

Every refresh the widget builds one Flux query and runs `curl` through
Plasma's executable data engine. With **Bypass system proxy** on (the default),
the command clears `http_proxy`, `https_proxy`, `all_proxy` (and their uppercase
forms) plus `LD_PRELOAD` (proxychains), and passes `--noproxy '*'`, so the
request goes straight to Grafana. Turn it off to let `curl` use the session's
proxy environment instead.

The query it sends:

```flux
from(bucket: "sensors")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "mqtt_consumer")
  |> filter(fn: (r) => r._field == "temperature" or ... )
  |> filter(fn: (r) => r.name == "GVH5075_B6D2" or ... )
  |> group(columns: ["name"])
  |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"])
  |> tail(n: 1)
```

Configured sensors with no point in the last 24 hours stay visible as
**no data**, so a sensor that stops reporting does not simply disappear. A
reading named `TEST` is ignored.

The widget parses Grafana's data frames tolerantly: it accepts the sensor name
from field labels or from a `name` column, and merges frames if the datasource
returns one frame per field.

## Troubleshooting

- **HTTP 401 / 403** — the token is missing, expired, or lacks permission to
  query the datasource. `Invalid API key` means you pasted a public dashboard
  share token; use a service account token instead. Anonymous requests to a
  Grafana server that requires login also return 401.
- **HTTP 404** — the Grafana URL is wrong, the URL includes a subpath that
  `/api/ds/query` is not served under, or the configured Datasource UID does
  not exist.
- **HTTP 400** — Grafana rejected the query. The error from Grafana is shown
  in the widget; check the bucket, measurement, sensor names and that the
  datasource supports Flux.
- **HTTP 5xx** — Grafana (or a reverse proxy in front of it) is temporarily
  unavailable or a backend query failed. The widget retries twice, three
  seconds apart, and shows the server's message or response body so the
  cause is visible if it persists. Grafana itself answers query failures with
  400 or 500, so a **503** means a proxy or ingress answered; the widget
  bypasses the desktop proxy settings, but an older installed copy may still
  be using Qt's HTTP stack. Upgrade with `kpackagetool6 --type Plasma/Applet
  --upgrade .`.
- **Grafana itself shows no data** — check the datasource health and Grafana's
  logs; the widget depends on that same InfluxDB datasource.
- **Could not reach Grafana** — check the hostname from this machine, whether
  Grafana uses plain HTTP or HTTPS, and that `curl` is installed. The message
  includes curl's own error text.
- **Self-signed HTTPS** — `curl` rejects untrusted certificates. Use HTTP on
  the local network or install the CA in the system trust store.
- **No data for a sensor** — verify the `name` tag in InfluxDB matches the
  configured sensor names, and that the measurement and bucket are correct.
