package com.synccompanion.server

import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream

class WebDavHandlerTest {

    private val token = "test-token-abc"
    private val authHeader = "Basic " + java.util.Base64.getEncoder()
        .encodeToString("sync:$token".toByteArray())

    private lateinit var storage: FakeStorageBackend

    @Before
    fun setUp() {
        storage = FakeStorageBackend()
        storage.addFile("/photo.jpg", "JPEG data".toByteArray())
        storage.addDir("/folder")
    }

    private fun handle(method: String, path: String, headers: Map<String, String> = emptyMap(),
                       body: ByteArray = ByteArray(0)): HttpResponse {
        val stream = ByteArrayInputStream(body)
        val allHeaders = headers + mapOf("authorization" to authHeader,
                                          "content-length" to body.size.toString())
        val req = HttpRequest(method.uppercase(), path, allHeaders, stream, body.size.toLong())
        return WebDavHandler.handle(req, storage, token)
    }

    private fun handleNoAuth(method: String, path: String): HttpResponse {
        val req = HttpRequest(method, path, emptyMap(), ByteArrayInputStream(ByteArray(0)), 0)
        return WebDavHandler.handle(req, storage, token)
    }

    private fun HttpResponse.statusCode(): Int {
        val out = ByteArrayOutputStream()
        writeTo(out)
        val line = out.toString(Charsets.ISO_8859_1.name()).substringBefore("\r\n")
        return line.split(" ")[1].toInt()
    }

    // MARK: - Authentication

    @Test
    fun `missing auth returns 401`() {
        assertEquals(401, handleNoAuth("GET", "/photo.jpg").statusCode())
    }

    @Test
    fun `wrong token returns 401`() {
        val stream = ByteArrayInputStream(ByteArray(0))
        val wrongAuth = "Basic " + java.util.Base64.getEncoder().encodeToString("sync:wrongtoken".toByteArray())
        val req = HttpRequest("GET", "/photo.jpg", mapOf("authorization" to wrongAuth), stream, 0)
        assertEquals(401, WebDavHandler.handle(req, storage, token).statusCode())
    }

    // MARK: - OPTIONS

    @Test
    fun `OPTIONS returns 200 with Allow header`() {
        val resp = handle("OPTIONS", "/")
        assertEquals(200, resp.statusCode())
        val raw = captureRaw(resp)
        assertTrue(raw.contains("Allow:") || raw.contains("DAV:"))
    }

    // MARK: - GET

    @Test
    fun `GET existing file returns 200`() {
        assertEquals(200, handle("GET", "/photo.jpg").statusCode())
    }

    @Test
    fun `GET missing file returns 404`() {
        assertEquals(404, handle("GET", "/missing.jpg").statusCode())
    }

    @Test
    fun `GET directory returns 403`() {
        assertEquals(403, handle("GET", "/folder").statusCode())
    }

    @Test
    fun `GET with satisfiable Range returns 206`() {
        val resp = handle("GET", "/photo.jpg",
            headers = mapOf("range" to "bytes=0-3"))
        assertEquals(206, resp.statusCode())
    }

    @Test
    fun `GET with unsatisfiable Range returns 416`() {
        val resp = handle("GET", "/photo.jpg",
            headers = mapOf("range" to "bytes=9999-99999"))
        assertEquals(416, resp.statusCode())
    }

    // MARK: - HEAD

    @Test
    fun `HEAD existing file returns 200`() {
        assertEquals(200, handle("HEAD", "/photo.jpg").statusCode())
    }

    // MARK: - PROPFIND

    @Test
    fun `PROPFIND root returns 207`() {
        assertEquals(207, handle("PROPFIND", "/").statusCode())
    }

    @Test
    fun `PROPFIND missing path returns 404`() {
        assertEquals(404, handle("PROPFIND", "/nothere").statusCode())
    }

    @Test
    fun `PROPFIND response is XML`() {
        val body = captureBody(handle("PROPFIND", "/"))
        assertTrue(body.contains("multistatus") || body.contains("DAV:"))
    }

    // MARK: - PUT

    @Test
    fun `PUT creates new file`() {
        val resp = handle("PUT", "/new.txt", body = "hello".toByteArray())
        assertEquals(201, resp.statusCode())
        assertNotNull(storage.files["/new.txt"])
    }

    @Test
    fun `PUT overwrites existing file`() {
        handle("PUT", "/photo.jpg", body = "updated".toByteArray())
        assertEquals("updated", String(storage.files["/photo.jpg"]!!))
    }

    // MARK: - DELETE

    @Test
    fun `DELETE existing file returns 204`() {
        assertEquals(204, handle("DELETE", "/photo.jpg").statusCode())
        assertFalse(storage.files.containsKey("/photo.jpg"))
    }

    @Test
    fun `DELETE missing file returns 404`() {
        assertEquals(404, handle("DELETE", "/missing.jpg").statusCode())
    }

    // MARK: - MKCOL

    @Test
    fun `MKCOL creates new directory`() {
        val resp = handle("MKCOL", "/newfolder")
        assertEquals(201, resp.statusCode())
        assertTrue(storage.dirs.contains("/newfolder"))
    }

    @Test
    fun `MKCOL existing directory returns 405`() {
        assertEquals(405, handle("MKCOL", "/folder").statusCode())
    }

    // MARK: - MOVE

    @Test
    fun `MOVE renames file`() {
        val dest = "http://host/renamed.jpg"
        val resp = handle("MOVE", "/photo.jpg",
            headers = mapOf("destination" to dest))
        assertEquals(201, resp.statusCode())
        assertTrue(storage.files.containsKey("/renamed.jpg"))
        assertFalse(storage.files.containsKey("/photo.jpg"))
    }

    // MARK: - Unknown method

    @Test
    fun `unknown method returns 405`() {
        assertEquals(405, handle("PATCH", "/photo.jpg").statusCode())
    }

    // MARK: - Info endpoint

    @Test
    fun `_midoid info returns 200 with JSON`() {
        val resp = handle("GET", "/_midoid/info")
        assertEquals(200, resp.statusCode())
        assertTrue(captureBody(resp).contains("{"))
    }

    // MARK: - Helpers

    private fun captureBody(resp: HttpResponse): String {
        val raw = captureRaw(resp)
        val separatorIdx = raw.indexOf("\r\n\r\n")
        return if (separatorIdx >= 0) raw.substring(separatorIdx + 4) else ""
    }

    private fun captureRaw(resp: HttpResponse): String {
        val out = ByteArrayOutputStream()
        resp.writeTo(out)
        return out.toString(Charsets.ISO_8859_1.name())
    }
}

// In-memory StorageBackend for tests
class FakeStorageBackend : StorageBackend {
    val files = mutableMapOf<String, ByteArray>()
    val dirs = mutableSetOf<String>("/")
    override val rootDisplayName = "Test Storage"

    fun addFile(path: String, data: ByteArray) { files[path] = data }
    fun addDir(path: String) { dirs.add(path) }

    override fun exists(path: String) = files.containsKey(path) || dirs.contains(path)

    override fun entry(path: String): StorageEntry? {
        if (dirs.contains(path)) return StorageEntry(path.substringAfterLast('/').ifEmpty { rootDisplayName },
            path, true, 0, 0, null)
        val data = files[path] ?: return null
        return StorageEntry(path.substringAfterLast('/'), path, false, data.size.toLong(), 0, null)
    }

    override fun list(path: String): List<StorageEntry> {
        val prefix = if (path == "/") "/" else "$path/"
        val fileEntries = files.keys.filter { it.startsWith(prefix) && it.removePrefix(prefix).none { c -> c == '/' } }
            .map { entry(it)!! }
        val dirEntries = dirs.filter { it != path && it.startsWith(prefix) && it.removePrefix(prefix).none { c -> c == '/' } }
            .map { entry(it)!! }
        return fileEntries + dirEntries
    }

    override fun openRead(path: String): InputStream? = files[path]?.let { ByteArrayInputStream(it) }

    override fun write(path: String, input: InputStream, contentLength: Long): Boolean {
        files[path] = input.readBytes()
        return true
    }

    override fun delete(path: String): Boolean {
        val removedFile = files.remove(path) != null
        val removedDir = dirs.remove(path)
        return removedFile || removedDir
    }

    override fun makeDirectory(path: String): Boolean {
        if (dirs.contains(path)) return false
        dirs.add(path)
        return true
    }

    override fun move(sourcePath: String, destinationPath: String): Boolean {
        val data = files.remove(sourcePath)
        return if (data != null) { files[destinationPath] = data; true } else false
    }

    override fun copy(sourcePath: String, destinationPath: String): Boolean {
        val data = files[sourcePath] ?: return false
        files[destinationPath] = data.copyOf()
        return true
    }
}
