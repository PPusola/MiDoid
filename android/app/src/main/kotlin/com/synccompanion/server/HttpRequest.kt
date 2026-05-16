package com.synccompanion.server

import java.io.InputStream
import java.net.URLDecoder

data class HttpRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String>,
    val inputStream: InputStream,
    val contentLength: Long
) {
    fun header(name: String): String? = headers[name.lowercase()]

    val depth: Int get() = when (header("depth")?.trim()?.lowercase()) {
        "0" -> 0
        else -> 1 // "1" and "infinity" both treated as 1
    }

    companion object {
        fun parse(input: InputStream): HttpRequest? {
            val headerBytes = readUntilDoubleCRLF(input) ?: return null
            val headerText = String(headerBytes, Charsets.ISO_8859_1)
            val lines = headerText.split("\r\n")
            if (lines.isEmpty()) return null

            val parts = lines[0].split(" ")
            if (parts.size < 2) return null
            val method = parts[0].uppercase()
            val rawPath = parts[1].substringBefore('?')
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
