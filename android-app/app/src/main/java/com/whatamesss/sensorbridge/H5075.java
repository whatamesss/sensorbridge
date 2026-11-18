package com.whatamesss.sensorbridge;

import java.util.Locale;

/**
 * Decoder for Govee H5075 BLE advertisement payloads.
 *
 * <p>The sensor advertises under manufacturer ID 0xEC88 with a six-byte
 * payload:
 *
 * <pre>
 * byte 0: packet flags
 * bytes 1-3: packed temperature and humidity (24 bit, big endian)
 * byte 4: battery percentage (low 7 bits) and error flag (high bit)
 * byte 5: trailing padding
 * </pre>
 *
 * <p>The three packed bytes hold {@code temperature * 10 * 1000 +
 * humidity * 10}, with bit 23 used as the sign bit for temperature. This
 * class is deliberately free of Android dependencies so it can be covered by
 * plain JVM unit tests.
 */
final class H5075 {

    static final int MANUFACTURER_ID = 0xEC88;

    static final int MIN_PAYLOAD_LENGTH = 6;

    private static final int SIGN_BIT = 0x800000;
    private static final int MAGNITUDE_MASK = 0x7FFFFF;

    private H5075() {
    }

    /** A validated sensor reading. */
    static final class Reading {
        final double temperature;
        final double humidity;
        final int battery;
        final String raw;

        Reading(double temperature, double humidity, int battery, String raw) {
            this.temperature = temperature;
            this.humidity = humidity;
            this.battery = battery;
            this.raw = raw;
        }

        String toJson(String name, String address, int rssi, long timestampMs) {
            return String.format(Locale.US,
                "{\"name\":\"%s\",\"address\":\"%s\",\"rssi\":%d,"
                    + "\"temperature\":%.1f,\"humidity\":%.1f,"
                    + "\"battery\":%d,\"raw\":\"%s\",\"timestamp\":%d}",
                escape(name),
                escape(address),
                rssi,
                temperature,
                humidity,
                battery,
                escape(raw),
                timestampMs);
        }
    }

    /**
     * Decodes a manufacturer payload.
     *
     * @return the reading, or {@code null} when the payload is too short, the
     *     sensor reports an error, or the values fall outside plausible ranges
     */
    static Reading decode(byte[] data) {
        if (data == null || data.length < MIN_PAYLOAD_LENGTH) {
            return null;
        }

        int raw = ((data[1] & 0xff) << 16)
            | ((data[2] & 0xff) << 8)
            | (data[3] & 0xff);

        boolean negative = (raw & SIGN_BIT) != 0;
        int magnitude = raw & MAGNITUDE_MASK;

        // The low three digits carry humidity * 10, the rest temperature * 10.
        double temperature = (magnitude / 1000) / 10.0;
        if (negative) {
            temperature = -temperature;
        }

        double humidity = (magnitude % 1000) / 10.0;

        int battery = data[4] & 0x7f;
        boolean error = (data[4] & 0x80) != 0;

        if (error
                || temperature < -40
                || temperature > 100
                || humidity < 0
                || humidity > 100
                || battery > 100) {
            return null;
        }

        return new Reading(temperature, humidity, battery, hex(data));
    }

    static String hex(byte[] bytes) {
        if (bytes == null) {
            return "";
        }

        StringBuilder sb = new StringBuilder(bytes.length * 2);

        for (byte b : bytes) {
            if (sb.length() > 0) {
                sb.append(' ');
            }
            sb.append(String.format(Locale.US, "%02X", b & 0xff));
        }

        return sb.toString();
    }

    private static String escape(String value) {
        if (value == null) {
            return "";
        }

        StringBuilder sb = new StringBuilder(value.length());

        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);

            switch (c) {
                case '"':
                    sb.append("\\\"");
                    break;
                case '\\':
                    sb.append("\\\\");
                    break;
                case '\n':
                    sb.append("\\n");
                    break;
                case '\r':
                    sb.append("\\r");
                    break;
                case '\t':
                    sb.append("\\t");
                    break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format(Locale.US, "\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                    break;
            }
        }

        return sb.toString();
    }
}
