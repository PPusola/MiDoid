package com.synccompanion.server

import java.io.InputStream
import java.net.URLDecoder

/**
 * Immutable model representing a parsed inbound HTTP/1.1 request.
 *
 * @property method        Uppercase HTTP verb (GET, PUT, DELETE, PROPFIND, etc.).
 * @property path          URL-decoded request path, always non-empty (defaults to "/").
 * @property headers       All header names normalized to lowercase for case-insensitive lookup.
 * @property inputStream   Live socket stream positioned just after the header block.
 * @property contentLength Value of the Content-Length header, or 0 if absent.
 */
data class HttpRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String>,
    val inputStream: InputStream,
    val contentLength: Long
) {
    /**
     * Returns the value of the named header, or `null` if not present.
     * Lookup is case-insensitive because all stored header names are lowercased on parse.
     *
     * @param name  The header name (any casing, e.g. "Content-Type" or "content-type").
     */
    fun header(name: String): String? = headers[name.lowercase()]

    /**
     * Parses the WebDAV `Depth` header into an integer.
     * Both `"1"` and `"infinity"` are clamped to `1` — infinite-depth recursion
     * is intentionally not supported by this server to avoid unbounded reads.
     */
    val depth: Int get() = when (header("depth")?.trim()?.lowercase()) {
        "0" -> 0
        else -> 1 // "1" and "infinity" both treated as 1
    }

    companion object {
        /**
         * Reads and parses a complete HTTP/1.1 request from [input].
         * Consumes all bytes up to and including the blank line (`\r\n\r\n`)
         * that terminates the headers, leaving the stream positioned at the
         * start of the request body.
         *
         * @param input  Raw socket [InputStream].
         * @return       A fully parsed [HttpRequest], or `null` if the stream
         *               is empty or the request line is malformed.
         */
        fun parse(input: InputStream): HttpRequest? {
            val headerBytes = readUntilDoubleCRLF(input) ?: return null
            val headerText = String(headerBytes, Charsets.ISO_8859_1)
            val lines = headerText.split("\r\n")
            if (lines.isEmpty()) return null

            val parts = lines[0].split(" ")
            if (parts.size < 2) return null
            val method = parts[0].uppercase()
            val rawPath = parts[1].substringBefore('?')
            // Decode percent-encoded characters; fall back to raw path on decode failure
            val path = try {
                URLDecoder.decode(rawPath, "UTF-8").ifEmpty { "/" }
            } catch (_: Exception) { rawPath.ifEmpty { "/" } }

            val headers = mutableMapOf<String, String>()
            for (i in 1 until lines.size) {
                val colon = lines[i].indexOf(':')
                if (colon > 0) {
                    headers[lines[i].substring(0, colon).trim().lowercase()] =
                        lines[i].substring(colon + 1).trim()
                }
            }

            val contentLength = headers["content-length"]?.toLongOrNull() ?: 0L
            return HttpRequest(method, path, headers, input, contentLength)
        }

        /**
         * Reads bytes from [input] until the `\r\n\r\n` sequence that marks
         * the end of an HTTP header block. The terminating sequence is consumed
         * but not included in the returned array.
         *
         * @param input  The raw socket stream to read from.
         * @return       The header block as a [ByteArray], or `null` if the
         *               stream closes before any bytes are received.
         */
        private fun readUntilDoubleCRLF(input: InputStream): ByteArray? {
            val buf = ArrayList<Byte>(512)
            while (true) {
                val b = input.read()
                if (b < 0) return if (buf.isEmpty()) null else buf.toByteArray()
                buf.add(b.toByte())
                val n = buf.size
                if (n >= 4 &&
                    buf[n - 4] == '\r'.code.toByte() &&
                    buf[n - 3] == '\n'.code.toByte() &&
                    buf[n - 2] == '\r'.code.toByte() &&
                    buf[n - 1] == '\n'.code.toByte()
                ) return buf.subList(0, n - 4).toByteArray()
            }
        }
    }
}
