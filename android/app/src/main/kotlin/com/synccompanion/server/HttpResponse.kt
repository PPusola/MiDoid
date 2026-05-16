package com.synccompanion.server

import java.io.OutputStream

class HttpResponse(
    private val status: Int,
    private val statusText: String,
    private val body: ByteArray = ByteArray(0),
    private val extraHeaders: Map<String, String> = emptyMap()
) {
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
        out.flush()
    }
}
