package com.synccompanion.server

import android.util.Base64
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object WebDavHandler {

    private val httpDate = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("GMT")
    }
    private val iso8601 = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

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

    // MARK: - Auth

    private fun checkAuth(req: HttpRequest, token: String): Boolean {
        val auth = req.header("authorization") ?: return false
        if (!auth.startsWith("Basic ", ignoreCase = true)) return false
        val decoded = try {
            String(Base64.decode(auth.substring(6).trim(), Base64.NO_WRAP))
        } catch (_: Exception) { return false }
        return decoded == "sync:$token"
    }

    // MARK: - Verb handlers

    private fun options() = HttpResponse(200, "OK", extraHeaders = mapOf(
        "Allow"         to "OPTIONS, HEAD, GET, PUT, DELETE, MKCOL, PROPFIND, MOVE, COPY",
        "DAV"           to "1, 2",
        "MS-Author-Via" to "DAV"
    ))

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

    private fun StringBuilder.appendEntry(entry: StorageEntry, isRoot: Boolean, rootDisplayName: String) {
        val href = entry.path.split("/").joinToString("/") { seg ->
            java.net.URLEncoder.encode(seg, "UTF-8").replace("+", "%20")
        }.let { if (!it.startsWith("/")) "/$it" else it }

        append("<D:response>")
        append("<D:href>${xmlEsc(href)}</D:href>")
        append("<D:propstat><D:prop>")
        // Finder uses displayname as the volume label for the root resource
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

    private fun delete(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (!storage.exists(req.path)) return HttpResponse(404, "Not Found")
        return if (storage.delete(req.path)) HttpResponse(204, "No Content")
        else HttpResponse(500, "Internal Server Error")
    }

    private fun mkcol(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (storage.exists(req.path)) return HttpResponse(405, "Method Not Allowed")
        return if (storage.makeDirectory(req.path)) HttpResponse(201, "Created")
        else HttpResponse(409, "Conflict")
    }

    private fun move(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (!storage.exists(req.path)) return HttpResponse(404, "Not Found")
        val dest = destPath(req) ?: return HttpResponse(400, "Bad Request")
        return if (storage.move(req.path, dest)) HttpResponse(201, "Created")
        else HttpResponse(500, "Internal Server Error")
    }

    private fun copy(req: HttpRequest, storage: StorageBackend): HttpResponse {
        if (!storage.exists(req.path)) return HttpResponse(404, "Not Found")
        val dest = destPath(req) ?: return HttpResponse(400, "Bad Request")
        return if (storage.copy(req.path, dest)) HttpResponse(201, "Created")
        else HttpResponse(500, "Internal Server Error")
    }

    // MARK: - Helpers

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

    private fun xmlEsc(s: String) = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")

    private const val TAG = "WebDavHandler"
}
