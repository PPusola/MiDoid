package com.synccompanion.server

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream

class HttpRequestTest {

    private fun stream(raw: String) = ByteArrayInputStream(raw.toByteArray(Charsets.ISO_8859_1))

    // MARK: - parse()

    @Test
    fun `parse returns null on empty stream`() {
        assertNull(HttpRequest.parse(ByteArrayInputStream(ByteArray(0))))
    }

    @Test
    fun `parse GET request`() {
        val raw = "GET /files/photo.jpg HTTP/1.1\r\nHost: 192.168.1.1\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))
        assertNotNull(req)
        assertEquals("GET", req!!.method)
        assertEquals("/files/photo.jpg", req.path)
    }

    @Test
    fun `parse uppercases method`() {
        val raw = "get / HTTP/1.1\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))
        assertEquals("GET", req!!.method)
    }

    @Test
    fun `parse decodes percent-encoded path`() {
        val raw = "GET /My%20Files/photo.jpg HTTP/1.1\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))
        assertEquals("/My Files/photo.jpg", req!!.path)
    }

    @Test
    fun `parse strips query string from path`() {
        val raw = "GET /files?sort=name HTTP/1.1\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))
        assertEquals("/files", req!!.path)
    }

    @Test
    fun `parse fallback to root for empty path`() {
        val raw = "GET  HTTP/1.1\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))
        assertEquals("/", req!!.path)
    }

    @Test
    fun `parse reads headers case-insensitively`() {
        val raw = "GET / HTTP/1.1\r\nContent-Length: 42\r\nAuthorization: Basic abc\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))!!
        assertEquals("42", req.header("content-length"))
        assertEquals("42", req.header("Content-Length"))
        assertEquals("Basic abc", req.header("authorization"))
    }

    @Test
    fun `parse extracts content-length`() {
        val raw = "PUT /file HTTP/1.1\r\nContent-Length: 100\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))
        assertEquals(100L, req!!.contentLength)
    }

    @Test
    fun `parse content-length zero when absent`() {
        val raw = "GET / HTTP/1.1\r\n\r\n"
        val req = HttpRequest.parse(stream(raw))
        assertEquals(0L, req!!.contentLength)
    }

    @Test
    fun `parse returns null for malformed request line`() {
        val raw = "BADREQUEST\r\n\r\n"
        assertNull(HttpRequest.parse(stream(raw)))
    }

    // MARK: - depth property

    @Test
    fun `depth defaults to 1 when header absent`() {
        val raw = "PROPFIND / HTTP/1.1\r\n\r\n"
        assertEquals(1, HttpRequest.parse(stream(raw))!!.depth)
    }

    @Test
    fun `depth 0 when header is 0`() {
        val raw = "PROPFIND / HTTP/1.1\r\nDepth: 0\r\n\r\n"
        assertEquals(0, HttpRequest.parse(stream(raw))!!.depth)
    }

    @Test
    fun `depth 1 when header is 1`() {
        val raw = "PROPFIND / HTTP/1.1\r\nDepth: 1\r\n\r\n"
        assertEquals(1, HttpRequest.parse(stream(raw))!!.depth)
    }

    @Test
    fun `depth 1 for infinity`() {
        val raw = "PROPFIND / HTTP/1.1\r\nDepth: infinity\r\n\r\n"
        assertEquals(1, HttpRequest.parse(stream(raw))!!.depth)
    }

    // MARK: - header()

    @Test
    fun `header returns null for missing key`() {
        val raw = "GET / HTTP/1.1\r\n\r\n"
        assertNull(HttpRequest.parse(stream(raw))!!.header("X-Missing"))
    }

    @Test
    fun `header trims whitespace from value`() {
        val raw = "GET / HTTP/1.1\r\nX-Custom:   value with spaces   \r\n\r\n"
        assertEquals("value with spaces", HttpRequest.parse(stream(raw))!!.header("x-custom"))
    }
}
