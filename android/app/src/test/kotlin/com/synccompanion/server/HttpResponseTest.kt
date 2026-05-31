package com.synccompanion.server

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class HttpResponseTest {

    private fun capture(response: HttpResponse): String {
        val out = ByteArrayOutputStream()
        response.writeTo(out)
        return out.toString(Charsets.ISO_8859_1.name())
    }

    @Test
    fun `writeTo emits HTTP 1_1 status line`() {
        val output = capture(HttpResponse(200, "OK"))
        assertTrue(output.startsWith("HTTP/1.1 200 OK\r\n"))
    }

    @Test
    fun `writeTo includes Connection close`() {
        val output = capture(HttpResponse(200, "OK"))
        assertTrue(output.contains("Connection: close\r\n"))
    }

    @Test
    fun `writeTo includes Content-Length for body`() {
        val body = "hello".toByteArray()
        val output = capture(HttpResponse(200, "OK", body = body))
        assertTrue(output.contains("Content-Length: 5\r\n"))
        assertTrue(output.endsWith("hello"))
    }

    @Test
    fun `writeTo Content-Length 0 for empty body`() {
        val output = capture(HttpResponse(404, "Not Found"))
        assertTrue(output.contains("Content-Length: 0\r\n"))
    }

    @Test
    fun `writeTo includes extra headers`() {
        val output = capture(HttpResponse(207, "Multi-Status", extraHeaders = mapOf("DAV" to "1, 2")))
        assertTrue(output.contains("DAV: 1, 2\r\n"))
    }

    @Test
    fun `writeTo skips auto Content-Length when provided in extraHeaders`() {
        val output = capture(HttpResponse(206, "Partial Content",
            extraHeaders = mapOf("Content-Length" to "999")))
        assertTrue(output.contains("Content-Length: 999\r\n"))
        // Should not contain a second Content-Length
        assertEquals(1, output.split("Content-Length").size - 1)
    }

    @Test
    fun `writeTo streams body stream`() {
        val data = "streamed content".toByteArray()
        val stream = ByteArrayInputStream(data)
        val output = capture(HttpResponse(200, "OK", bodyStream = stream))
        assertTrue(output.endsWith("streamed content"))
    }

    @Test
    fun `writeTo 404 status`() {
        val output = capture(HttpResponse(404, "Not Found"))
        assertTrue(output.startsWith("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test
    fun `writeTo has blank line separating headers and body`() {
        val body = "data".toByteArray()
        val output = capture(HttpResponse(200, "OK", body = body))
        assertTrue(output.contains("\r\n\r\n"))
    }
}
