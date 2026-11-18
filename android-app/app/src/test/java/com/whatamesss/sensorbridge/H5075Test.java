package com.whatamesss.sensorbridge;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class H5075Test {

    /** Packs a reading exactly the way the H5075 firmware does. */
    private static byte[] payload(
            double temperature, double humidity, int battery, boolean error) {

        int magnitude = (int) (Math.abs(temperature) * 10) * 1000
            + (int) Math.round(humidity * 10);

        if (temperature < 0) {
            magnitude |= 0x800000;
        }

        int batteryByte = (battery & 0x7f) | (error ? 0x80 : 0x00);

        return new byte[]{
            0x01,
            (byte) ((magnitude >> 16) & 0xff),
            (byte) ((magnitude >> 8) & 0xff),
            (byte) (magnitude & 0xff),
            (byte) batteryByte,
            0x00
        };
    }

    @Test
    public void decodesPositiveReading() {
        H5075.Reading reading = H5075.decode(
            payload(23.5, 48.2, 95, false));

        assertNotNull(reading);
        assertEquals(23.5, reading.temperature, 0.001);
        assertEquals(48.2, reading.humidity, 0.001);
        assertEquals(95, reading.battery);
    }

    @Test
    public void decodesNegativeTemperature() {
        H5075.Reading reading = H5075.decode(
            payload(-5.0, 32.1, 80, false));

        assertNotNull(reading);
        assertEquals(-5.0, reading.temperature, 0.001);
        assertEquals(32.1, reading.humidity, 0.001);
        assertEquals(80, reading.battery);
    }

    @Test
    public void decodesFullScaleOfPackedFields() {
        // 0x03 0x97 0xDA -> temperature 23.5, humidity 48.2, battery 95.
        H5075.Reading reading = H5075.decode(new byte[]{
            0x01, 0x03, (byte) 0x97, (byte) 0xDA, 0x5F, 0x00});

        assertNotNull(reading);
        assertEquals(23.5, reading.temperature, 0.001);
        assertEquals(48.2, reading.humidity, 0.001);
        assertEquals(95, reading.battery);
    }

    @Test
    public void rejectsErrorFlag() {
        assertNull(H5075.decode(payload(21.0, 50.0, 90, true)));
    }

    @Test
    public void rejectsShortPayload() {
        assertNull(H5075.decode(null));
        assertNull(H5075.decode(new byte[]{}));
        assertNull(H5075.decode(new byte[]{0x01, 0x02, 0x03, 0x04, 0x05}));
    }

    @Test
    public void rejectsBatteryAboveHundred() {
        assertNull(H5075.decode(new byte[]{
            0x01, 0x03, (byte) 0x97, (byte) 0xDA, (byte) 0x7F, 0x00}));
    }

    @Test
    public void rejectsTemperatureAboveHundred() {
        // magnitude = 1500 * 1000 -> 150.0 C after decoding.
        int magnitude = 1500 * 1000;
        byte[] data = new byte[]{
            0x01,
            (byte) ((magnitude >> 16) & 0xff),
            (byte) ((magnitude >> 8) & 0xff),
            (byte) (magnitude & 0xff),
            0x50,
            0x00
        };

        assertNull(H5075.decode(data));
    }

    @Test
    public void formatsJsonWithEscapedDeviceName() {
        H5075.Reading reading = H5075.decode(
            payload(23.5, 48.2, 95, false));

        assertNotNull(reading);

        String json = reading.toJson(
            "Hall \"sensor\"\\", "A4:C1:38:00:00:01", -60, 1700000000000L);

        assertTrue(json.contains("\"temperature\":23.5"));
        assertTrue(json.contains("\"humidity\":48.2"));
        assertTrue(json.contains("\"battery\":95"));
        assertTrue(json.contains("\"rssi\":-60"));
        assertTrue(json.contains("\"timestamp\":1700000000000"));
        assertTrue(json.contains("\"name\":\"Hall \\\"sensor\\\"\\\\\""));
    }
}
