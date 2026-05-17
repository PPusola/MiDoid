package com.synccompanion.server

import android.util.Base64
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Stateless request dispatcher for the embedded WebDAV server.
 *
 * Receives a fully parsed [HttpRequest], authenticates the caller against the
 * session token, routes the call to the correct verb handler, and returns an
 * [HttpResponse]. All mutable state lives in [StorageBackend] — this singleton
 * holds no state of its own, making it safe to share across threads.
 */
object WebDavHandler {

    // RFC 7231 HTTP-date format required by Last-Modified and similar headers
    private val httpDate = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("GMT")
    }

    // ISO 8601 used for the WebDAV creationdate property
    private val iso8601 = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

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
    fun handle(req: HttpRequest, storage: StorageBackend, token: String): HttpResponse {
        if (!checkAuth(req, token)) return HttpResponse(
            401, "Unauthorized",
            extraHeaders = mapOf("WWW-Authenticate" to "Basic realm=\"MiDoid\"")
        )
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
     * Handles GET and HEAD. Returns the file's content and metadata headers.
     * Returns `403 Forbidden` for directories (not downloadable as streams)
     * and `404 Not Found` if the path does not exist. HEAD omits the response body.
     */
    private fun get(req: HttpRequest, storage: StorageBackend): HttpResponse {
        val entry = storage.entry(req.path) ?: return HttpResponse(404, "Not Found")
        if (entry.isDirectory) return HttpResponse(403, "Forbidden")
        val body = if (req.method == "GET") storage.read(req.path) else ByteArray(0)
        return HttpResponse(200, "OK", body, mapOf(
            "Content-Type"   to storageMime(entry.name, entry.mimeType),
            "Content-Length" to entry.length.toString(),
            "Last-Modified"  to httpDate.format(Date(entry.lastModified))
        ))
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
        append("<D:getlastmodified>${httpDate.format(Date(entry.lastModified))}</D:getlastmodified>")
        append("<D:creationdate>${iso8601.format(Date(entry.lastModified))}</D:creationdate>")
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
        return try {
            if (!storage.write(req.path, req.inputStream, req.contentLength)) {
                return HttpResponse(500, "Internal Server Error")
            }
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

    private const val TAG = "WebDavHandler"
}
