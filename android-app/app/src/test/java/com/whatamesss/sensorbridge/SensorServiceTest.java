package com.whatamesss.sensorbridge;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class SensorServiceTest {

    @Test
    public void fallsBackToTheAddressSuffix() {
        assertEquals(
            "GVH5075_B6D2",
            SensorService.fallbackName("A4:C1:38:1B:B6:D2"));
    }

    @Test
    public void handlesShortAndMissingAddresses() {
        assertEquals("GVH5075_A", SensorService.fallbackName("a"));
        assertEquals("Govee H5075", SensorService.fallbackName(null));
        assertEquals("Govee H5075", SensorService.fallbackName(""));
    }

    @Test
    public void testPayloadIsTaggedWithAReservedName() {
        String json = SensorService.testPayload(1700000000000L);

        assertTrue(json.contains("\"name\":\"TEST\""));
        assertTrue(json.contains("\"test\":true"));
        assertTrue(json.contains("\"temperature\":21.6"));
        assertTrue(json.contains("\"timestamp\":1700000000000"));
    }
}
