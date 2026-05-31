package com.synccompanion.server

import android.os.Build
import android.util.Base64
import android.util.Log
import com.synccompanion.transfer.TransferEvents
import java.io.InputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Stateless request dispatcher for the embedded WebDAV server.
 *
 * Receives a fully parsed [HttpRequest], authenticates the caller against the
 * session token, routes the call to the correct verb handler, and returns an
 * [HttpResponse]. All mutable state lives in [StorageBackend] — this singleton
 * holds no state of its own, making it safe to share across threads.
 */
object WebDavHandler {

    // Immutable formatters are safe to reuse across concurrent WebDAV worker threads.
    private val httpDate: DateTimeFormatter = DateTimeFormatter.RFC_1123_DATE_TIME.withZone(ZoneOffset.UTC)
    private val iso8601: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT

    /**
     * Main entry point. Authenticates the request then dispatches to the correct
     * verb handler. Returns `401 Unauthorized` on auth failure and `405 Method Not Allowed`
     * for any verb not in the WebDAV spec subset supported by this server.
     *
     * @param req      Fully parsed inbound [HttpRequest].
     * @param storage  Storage backend to read/write against.
     * @param token    Expected session token; compared against the Basic-auth password field.
     * @return         An [HttpResponse] ready to be written to the socket.
     */
    fun handle(
        req: HttpRequest,
        storage: StorageBackend,
        token: String,
        infoProvider: () -> Map<String, Any?> = { emptyMap() }
    ): HttpResponse {
        if (!checkAuth(req, token)) return HttpResponse(
            401, "Unauthorized",
            extraHeaders = mapOf("WWW-Authenticate" to "Basic realm=\"MiDoid\"")
        )
        if (req.method == "GET" && req.path == "/_midoid/info") return deviceInfo(infoProvider())
        return when (req.method) {
            "OPTIONS"      -> options()
            "HEAD", "GET"  -> get(req, storage)
            "PROPFIND"     -> propfind(req, storage)
            "PUT"          -> put(req, storage)
            "DELETE"       -> delete(req, storage)
            "MKCOL"        -> mkcol(req, storage)
            "MOVE"         -> move(req, storage)
            "COPY"         -> copy(req, storage)
            else           -> HttpResponse(405, "Method Not Allowed")
        }
    }

    // ── Auth ──────────────────────────────────────────────────────────────────

    /**
     * Validates HTTP Basic authentication against the expected [token].
     * Credentials must be in the form `sync:<token>` (Base64-encoded).
     *
     * @return `true` if the Authorization header is present and matches exactly.
     */
    private fun checkAuth(req: HttpRequest, token: String): Boolean {
        val auth = req.header("authorization") ?: return false
        if (!auth.startsWith("Basic ", ignoreCase = true)) return false
        val decoded = try {
            String(Base64.decode(auth.substring(6).trim(), Base64.NO_WRAP))
        } catch (_: Exception) { return false }
        return decoded == "sync:$token"
    }

    // ── Verb handlers ─────────────────────────────────────────────────────────

    /** Returns `{"name":"<model>","manufacturer":"<brand>"}` for the Mac to display as device name. */
    private fun deviceInfo(info: Map<String, Any?>): HttpResponse {
        val fields = linkedMapOf<String, Any?>(
            "name" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER
        )
        fields.putAll(info)
        val json = fields.entries.joinToString(prefix = "{", postfix = "}") { (key, value) ->
            val encodedKey = jsonString(key)
            when (value) {
                is Number, is Boolean -> "$encodedKey:$value"
                null -> "$encodedKey:null"
                else -> "$encodedKey:${jsonString(value.toString())}"
            }
        }
        val body = json.toByteArray(Charsets.UTF_8)
        return HttpResponse(200, "OK", body, mapOf(
            "Content-Type"   to "application/json; charset=UTF-8",
            "Content-Length" to body.size.toString()
        ))
    }

    /**
     * Handles OPTIONS. Returns the list of supported WebDAV methods and DAV compliance headers.
     * macOS Finder checks this before mounting the volume.
     */
    private fun options() = HttpResponse(200, "OK", extraHeaders = mapOf(
        "Allow"         to "OPTIONS, HEAD, GET, PUT, DELETE, MKCOL, PROPFIND, MOVE, COPY",
        "DAV"           to "1, 2",
        "MS-Author-Via" to "DAV"
    ))

    /**
     * Handles GET and HEAD. Supports `Range: bytes=start-end` for partial content
     * (required by AVPlayer and other streaming clients). Returns `206 Partial Content`
     * for range requests, `200 OK` for full-file requests, `403` for directories,
     * `404` if the path does not exist, and `416` for an unsatisfiable range.
     */
    private fun get(req: HttpRequest, storage: StorageBackend): HttpResponse {
        val entry = storage.entry(req.path) ?: return HttpResponse(404, "Not Found")
        if (entry.isDirectory) return HttpResponse(403, "Forbidden")
        val totalLength = entry.length

        val rangeHeader = req.header("range")
        if (rangeHeader != null) {
            val range = parseByteRange(rangeHeader, totalLength)
                ?: return HttpResponse(416, "Range Not Satisfiable",
                    extraHeaders = mapOf("Content-Range" to "bytes */$totalLength"))
            val (start, end) = range
            val length = end - start + 1
            val headers = mapOf(
                "Content-Type"   to storageMime(entry.name, entry.mimeType),
                "Content-Length" to length.toString(),
                "Content-Range"  to "bytes $start-$end/$totalLength",
                "Accept-Ranges"  to "bytes",
                "Last-Modified"  to formatHttpDate(entry.lastModified)
            )
            if (req.method == "HEAD") return HttpResponse(206, "Partial Content", extraHeaders = headers)
            val stream = storage.openRead(req.path) ?: return HttpResponse(404, "Not Found")
            stream.skip(start)
            return HttpResponse(206, "Partial Content",
                bodyStream = LimitedInputStream(stream, length), extraHeaders = headers)
        }

        val stream = if (req.method == "GET") storage.openRead(req.path)
            ?: return HttpResponse(404, "Not Found") else null
        return HttpResponse(200, "OK", bodyStream = stream, extraHeaders = mapOf(
            "Content-Type"   to storageMime(entry.name, entry.mimeType),
            "Content-Length" to totalLength.toString(),
            "Accept-Ranges"  to "bytes",
            "Last-Modified"  to formatHttpDate(entry.lastModified)
        ))
    }

    /**
     * Parses a `Range: bytes=...` header value into a (start, end) pair of inclusive byte offsets.
     * Supports all three RFC 7233 forms: `start-end`, `start-`, and `-suffixLength`.
     * Returns `null` if the header is malformed or the range is out of bounds.
     */
    private fun parseByteRange(header: String, totalLength: Long): Pair<Long, Long>? {
        if (!header.startsWith("bytes=", ignoreCase = true)) return null
        val spec = header.substringAfter("=").trim()
        return when {
            spec.startsWith("-") -> {
                val suffix = spec.drop(1).toLongOrNull() ?: return null
                if (suffix <= 0) return null
                maxOf(0L, totalLength - suffix) to (totalLength - 1)
            }
            spec.endsWith("-") -> {
                val start = spec.dropLast(1).toLongOrNull() ?: return null
                if (start >= totalLength) return null
                start to (totalLength - 1)
            }
            else -> {
                val parts = spec.split("-")
                if (parts.size != 2) return null
                val start = parts[0].toLongOrNull() ?: return null
                val end   = parts[1].toLongOrNull() ?: return null
                if (start > end || start >= totalLength) return null
                start to minOf(end, totalLength - 1)
            }
        }
    }

    /** Wraps an [InputStream] and limits reads to [remaining] bytes. */
    private class LimitedInputStream(
        private val inner: InputStream,
        private var remaining: Long
    ) : InputStream() {
        override fun read(): Int {
            if (remaining <= 0) return -1
            val b = inner.read()
            if (b >= 0) remaining--
            return b
        }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (remaining <= 0) return -1
            val n = inner.read(b, off, minOf(len.toLong(), remaining).toInt())
            if (n > 0) remaining -= n
            return n
        }
        override fun close() = inner.close()
    }

    /**
     * Handles PROPFIND. Builds a `207 Multi-Status` XML response containing one
     * `<D:response>` element per entry. Depth 0 returns only the requested resource;
     * Depth 1 also includes immediate children (controlled by the `Depth` header).
     */
    private fun propfind(req: HttpRequest, storage: StorageBackend): HttpResponse {
        val entry = storage.entry(req.path) ?: return HttpResponse(404, "Not Found")
        val xml = buildString {
            append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
            append("<D:multistatus xmlns:D=\"DAV:\">")
            appendEntry(entry, isRoot = req.path == "/" || req.path.isEmpty(), storage.rootDisplayName)
            if (req.depth > 0 && entry.isDirectory) {
                storage.list(req.path).forEach { child -> appendEntry(child, isRoot = false, storage.rootDisplayName) }
            }
            append("</D:multistatus>")
        }
        val body = xml.toByteArray(Charsets.UTF_8)
        return HttpResponse(207, "Multi-Status", body, mapOf(
            "Content-Type"   to "application/xml; charset=UTF-8",
            "Content-Length" to body.size.toString()
        ))
    }

    /**
     * Appends a single `<D:response>` XML block for [entry] to this [StringBuilder].
     * Percent-encodes each path segment for use in the `<D:href>` element.
     * Uses [rootDisplayName] as the `<D:displayname>` for the root resource so that
     * macOS Finder shows a meaningful volume label.
     *
     * @param entry            The file or directory to serialize.
     * @param isRoot           `true` if this entry represents the root collection.
     * @param rootDisplayName  Volume label shown for the root resource.
     */
    private fun StringBuilder.appendEntry(entry: StorageEntry, isRoot: Boolean, rootDisplayName: String) {
        val href = entry.path.split("/").joinToString("/") { seg ->
            java.net.URLEncoder.encode(seg, "UTF-8").replace("+", "%20")
        }.let { if (!it.startsWith("/")) "/$it" else it }

        append("<D:response>")
        append("<D:href>${xmlEsc(href)}</D:href>")
        append("<D:propstat><D:prop>")
        val displayName = if (isRoot) rootDisplayName else xmlEsc(entry.name)
        append("<D:displayname>$displayName</D:displayname>")
        append("<D:getlastmodified>${formatHttpDate(entry.lastModified)}</D:getlastmodified>")
        append("<D:creationdate>${formatIsoDate(entry.lastModified)}</D:creationdate>")
        if (entry.isDirectory) {
            append("<D:resourcetype><D:collection/></D:resourcetype>")
        } else {
            append("<D:resourcetype/>")
            append("<D:getcontentlength>${entry.length}</D:getcontentlength>")
            append("<D:getcontenttype>${storageMime(entry.name, entry.mimeType)}</D:getcontenttype>")
        }
        append("</D:prop>")
        append("<D:status>HTTP/1.1 200 OK</D:status>")
        append("</D:propstat></D:response>")
    }

    /**
     * Handles PUT. Streams the request body to [StorageBackend.write].
     * Returns `201 Created` for new files and `204 No Content` when overwriting an existing one.
     * Returns `500 Internal Server Error` if the write fails.
     */
    private fun put(req: HttpRequest, storage: StorageBackend): HttpResponse {
        val existed = storage.exists(req.path)
        val filename = req.path.substringAfterLast('/').ifBlank { "file" }
        val input = ProgressInputStream(req.inputStream, req.contentLength) { received, total, complete ->
            TransferEvents.reportIncoming(filename, received, total, complete)
        }
        return try {
            TransferEvents.reportIncoming(filename, 0L, req.contentLength, complete = false)
            if (!storage.write(req.path, input, req.contentLength)) {
                return HttpResponse(500, "Internal Server Error")
            }
            TransferEvents.reportIncoming(filename, req.contentLength, req.contentLength, complete = true)
            HttpResponse(if (existed) 204 else 201, if (existed) "No Content" else "Created")
        } catch (e: Exception) {
            Log.e(TAG, "PUT error: ${e.message}")
            HttpResponse(500, "Internal Server Error")
        }
    }

    /**
     * Handles DELETE. Returns `404 Not Found` if the path does not exist,
     * `204 No Content` on success, or `500 Internal Server Error` on failure.
     */
    private fun delete(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (!storage.exists(req.path)) return HttpResponse(404, "Not Found")
        return if (storage.delete(req.path)) HttpResponse(204, "No Content")
        else HttpResponse(500, "Internal Server Error")
    }

    /**
     * Handles MKCOL (create collection/directory). Returns `405 Method Not Allowed`
     * if the path already exists, `201 Created` on success, or `409 Conflict` if the
     * parent directory does not exist.
     */
    private fun mkcol(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (storage.exists(req.path)) return HttpResponse(405, "Method Not Allowed")
        return if (storage.makeDirectory(req.path)) HttpResponse(201, "Created")
        else HttpResponse(409, "Conflict")
    }

    /**
     * Handles MOVE. Extracts the destination from the `Destination` header via [destPath].
     * Returns `400 Bad Request` if the header is absent or unparseable.
     */
    private fun move(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (!storage.exists(req.path)) return HttpResponse(404, "Not Found")
        val dest = destPath(req) ?: return HttpResponse(400, "Bad Request")
        return if (storage.move(req.path, dest)) HttpResponse(201, "Created")
        else HttpResponse(500, "Internal Server Error")
    }

    /**
     * Handles COPY. Extracts the destination from the `Destination` header via [destPath].
     * Returns `400 Bad Request` if the header is absent or unparseable.
     */
    private fun copy(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (!storage.exists(req.path)) return HttpResponse(404, "Not Found")
        val dest = destPath(req) ?: return HttpResponse(400, "Bad Request")
        return if (storage.copy(req.path, dest)) HttpResponse(201, "Created")
        else HttpResponse(500, "Internal Server Error")
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /**
     * Extracts and normalizes the destination path from the WebDAV `Destination` header.
     * The header may be a full URI (e.g. `http://host/path`) or a raw path.
     * Falls back to URL-decoding on `java.net.URI` parse failure.
     *
     * @return Normalized absolute path, or `null` if the header is missing or unparseable.
     */
    private fun destPath(req: HttpRequest): String? {
        val header = req.header("destination") ?: return null
        val path = try {
            java.net.URI(header).path
        } catch (_: Exception) {
            java.net.URLDecoder.decode(
                header.substringAfter("://").substringAfter("/", "/"), "UTF-8"
            ).let { "/$it" }
        }
        return normalizedPath(path)
    }

    /**
     * Escapes the five XML special characters (`&`, `<`, `>`, `"`, `'` is not escaped here
     * as it is only required inside attribute values) for safe inclusion in XML text nodes.
     *
     * @param s  Raw string to escape.
     * @return   XML-safe version of [s].
     */
    private fun xmlEsc(s: String) = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")

    private fun jsonString(s: String): String = buildString {
        append('"')
        for (ch in s) {
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> append(ch)
            }
        }
        append('"')
    }

    private fun formatHttpDate(epochMs: Long): String = httpDate.format(Instant.ofEpochMilli(epochMs))

    private fun formatIsoDate(epochMs: Long): String = iso8601.format(Instant.ofEpochMilli(epochMs))

    private class ProgressInputStream(
        private val inner: InputStream,
        private val totalBytes: Long,
        private val onProgress: (receivedBytes: Long, totalBytes: Long, complete: Boolean) -> Unit
    ) : InputStream() {
        private var receivedBytes = 0L
        private var nextReportBytes = PROGRESS_STEP_BYTES

        override fun read(): Int {
            val value = inner.read()
            if (value >= 0) report(1)
            return value
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val count = inner.read(b, off, len)
            if (count > 0) report(count)
            return count
        }

        override fun close() = inner.close()

        private fun report(count: Int) {
            receivedBytes += count
            if (receivedBytes >= nextReportBytes || receivedBytes >= totalBytes) {
                onProgress(receivedBytes, totalBytes, receivedBytes >= totalBytes)
                nextReportBytes = receivedBytes + PROGRESS_STEP_BYTES
            }
        }
    }

    private const val TAG = "WebDavHandler"
    private const val PROGRESS_STEP_BYTES = 512 * 1024L
}
