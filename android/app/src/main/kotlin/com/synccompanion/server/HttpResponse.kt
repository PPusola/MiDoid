package com.synccompanion.server

import java.io.InputStream
import java.io.OutputStream

/**
 * Serializes an HTTP/1.1 response directly to a socket output stream.
 *
 * Automatically appends a `Content-Length` header unless one is already
 * present in [extraHeaders]. Always sends `Connection: close` to signal
 * that the underlying TCP socket will be closed after this response.
 *
 * @property status       Numeric HTTP status code (e.g. 200, 404, 207).
 * @property statusText   Human-readable reason phrase (e.g. "OK", "Not Found").
 * @property body         Raw response body bytes; empty by default for header-only responses.
 * @property bodyStream   Optional streaming body for large responses such as videos.
 * @property extraHeaders Additional headers merged into the response (e.g. Content-Type, DAV).
 */
class HttpResponse(
    private val status: Int,
    private val statusText: String,
    private val body: ByteArray = ByteArray(0),
    private val extraHeaders: Map<String, String> = emptyMap(),
    private val bodyStream: InputStream? = null
) {
    /**
     * Writes the complete HTTP response — status line, headers, blank line, and body — to [out].
     * Headers are encoded in ISO-8859-1 per the HTTP/1.1 spec; the body is written
     * as raw bytes with no additional encoding applied.
     *
     * @param out  The socket [OutputStream] to write to.
     */
    fun writeTo(out: OutputStream) {
        val sb = StringBuilder()
        sb.append("HTTP/1.1 $status $statusText\r\n")
        sb.append("Connection: close\r\n")
        extraHeaders.forEach { (k, v) -> sb.append("$k: $v\r\n") }
        if ("content-length" !in extraHeaders && "Content-Length" !in extraHeaders) {
            sb.append("Content-Length: ${body.size}\r\n")
        }
        sb.append("\r\n")
        out.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
        if (body.isNotEmpty()) out.write(body)
        bodyStream?.use { input -> input.copyTo(out, STREAM_BUFFER_SIZE) }
        out.flush()
    }

    companion object {
        private const val STREAM_BUFFER_SIZE = 64 * 1024
    }
}
