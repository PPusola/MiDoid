package com.synccompanion.server

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.InputStream
import java.net.URLDecoder

data class StorageEntry(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val length: Long,
    val lastModified: Long,
    val mimeType: String?
)

interface StorageBackend {
    val rootDisplayName: String
    fun exists(path: String): Boolean
    fun entry(path: String): StorageEntry?
    fun list(path: String): List<StorageEntry>
    fun read(path: String): ByteArray
    fun write(path: String, input: InputStream, contentLength: Long): Boolean
    fun delete(path: String): Boolean
    fun makeDirectory(path: String): Boolean
    fun move(sourcePath: String, destinationPath: String): Boolean
    fun copy(sourcePath: String, destinationPath: String): Boolean
}

fun storageMime(name: String, explicitType: String? = null): String =
    explicitType ?: when (name.substringAfterLast('.', "").lowercase()) {
        "txt" -> "text/plain"
        "html", "htm" -> "text/html"
        "json" -> "application/json"
        "xml" -> "application/xml"
        "pdf" -> "application/pdf"
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "svg" -> "image/svg+xml"
        "mp4" -> "video/mp4"
        "mp3" -> "audio/mpeg"
        "zip" -> "application/zip"
        else -> "application/octet-stream"
    }

private fun cleanSegments(path: String): List<String> =
    path.trim('/').split('/').filter { it.isNotBlank() }.map {
        URLDecoder.decode(it, "UTF-8")
    }

private fun childPath(parentPath: String, childName: String): String {
    return if (parentPath == "/" || parentPath.isBlank()) "/$childName" else "${parentPath.trimEnd('/')}/$childName"
}

class FileStorageBackend(
    private val root: File,
    override val rootDisplayName: String = "MiDoid Storage"
) : StorageBackend {

    private val rootCanon: File get() = root.canonicalFile

    private fun resolve(path: String): File {
        val candidate = cleanSegments(path).fold(rootCanon) { dir, segment -> File(dir, segment) }.canonicalFile
        return if (candidate == rootCanon || candidate.path.startsWith(rootCanon.path + File.separator)) {
            candidate
        } else {
            rootCanon
        }
    }

    override fun exists(path: String): Boolean = resolve(path).exists()

    override fun entry(path: String): StorageEntry? {
        val file = resolve(path)
        if (!file.exists()) return null
        val name = if (path == "/" || path.isBlank()) rootDisplayName else file.name
        return StorageEntry(name, normalizedPath(path), file.isDirectory, file.length(), file.lastModified(), null)
    }

    override fun list(path: String): List<StorageEntry> {
        val dir = resolve(path)
        return dir.listFiles()?.map {
            StorageEntry(
                name = it.name,
                path = childPath(normalizedPath(path), it.name),
                isDirectory = it.isDirectory,
                length = it.length(),
                lastModified = it.lastModified(),
                mimeType = null
            )
        } ?: emptyList()
    }

    override fun read(path: String): ByteArray = resolve(path).readBytes()

    override fun write(path: String, input: InputStream, contentLength: Long): Boolean {
        val file = resolve(path)
        file.parentFile?.mkdirs()
        file.outputStream().use { out ->
            val buf = ByteArray(16_384)
            var remaining = contentLength
            while (remaining > 0) {
                val n = input.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                if (n < 0) break
                out.write(buf, 0, n)
                remaining -= n
            }
        }
        return true
    }

    override fun delete(path: String): Boolean = resolve(path).deleteRecursively()

    override fun makeDirectory(path: String): Boolean {
        val dir = resolve(path)
        if (dir.exists()) return false
        if (dir.parentFile?.exists() == false) return false
        return dir.mkdir()
    }

    override fun move(sourcePath: String, destinationPath: String): Boolean =
        resolve(sourcePath).renameTo(resolve(destinationPath).also { it.parentFile?.mkdirs() })

    override fun copy(sourcePath: String, destinationPath: String): Boolean =
        resolve(sourcePath).copyRecursively(resolve(destinationPath).also { it.parentFile?.mkdirs() }, overwrite = true)
}

class DocumentTreeStorageBackend(
    context: Context,
    private val resolver: ContentResolver,
    treeUri: Uri,
    override val rootDisplayName: String = "MiDoid Folder"
) : StorageBackend {

    private val root = DocumentFile.fromTreeUri(context, treeUri)

    private fun resolve(path: String): DocumentFile? {
        var current = root ?: return null
        for (segment in cleanSegments(path)) {
            current = current.findFile(segment) ?: return null
        }
        return current
    }

    private fun parentAndName(path: String): Pair<DocumentFile, String>? {
        val segments = cleanSegments(path)
        val name = segments.lastOrNull() ?: return null
        val parentPath = "/" + segments.dropLast(1).joinToString("/")
        val parent = resolve(parentPath) ?: return null
        return parent to name
    }

    override fun exists(path: String): Boolean = resolve(path)?.exists() == true

    override fun entry(path: String): StorageEntry? {
        val doc = resolve(path) ?: return null
        val isRoot = path == "/" || path.isBlank()
        return StorageEntry(
            name = if (isRoot) rootDisplayName else doc.name.orEmpty(),
            path = normalizedPath(path),
            isDirectory = doc.isDirectory,
            length = doc.length(),
            lastModified = doc.lastModified(),
            mimeType = doc.type
        )
    }

    override fun list(path: String): List<StorageEntry> {
        val parent = resolve(path) ?: return emptyList()
        return parent.listFiles().mapNotNull { child ->
            val name = child.name ?: return@mapNotNull null
            StorageEntry(
                name = name,
                path = childPath(normalizedPath(path), name),
                isDirectory = child.isDirectory,
                length = child.length(),
                lastModified = child.lastModified(),
                mimeType = child.type
            )
        }
    }

    override fun read(path: String): ByteArray {
        val uri = resolve(path)?.uri ?: return ByteArray(0)
        return resolver.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
    }

    override fun write(path: String, input: InputStream, contentLength: Long): Boolean {
        val existing = resolve(path)
        val target = existing ?: parentAndName(path)?.let { (parent, name) ->
            parent.createFile(storageMime(name), name)
        } ?: return false
        resolver.openOutputStream(target.uri, "wt")?.use { out ->
            val buf = ByteArray(16_384)
            var remaining = contentLength
            while (remaining > 0) {
                val n = input.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                if (n < 0) break
                out.write(buf, 0, n)
                remaining -= n
            }
        } ?: return false
        return true
    }

    override fun delete(path: String): Boolean = resolve(path)?.delete() == true

    override fun makeDirectory(path: String): Boolean {
        val (parent, name) = parentAndName(path) ?: return false
        if (parent.findFile(name) != null) return false
        return parent.createDirectory(name) != null
    }

    override fun move(sourcePath: String, destinationPath: String): Boolean {
        val source = resolve(sourcePath) ?: return false
        val (destParent, destName) = parentAndName(destinationPath) ?: return false
        val sourceParentPath = "/" + cleanSegments(sourcePath).dropLast(1).joinToString("/")
        val destParentPath = "/" + cleanSegments(destinationPath).dropLast(1).joinToString("/")
        if (normalizedPath(sourceParentPath) != normalizedPath(destParentPath)) return false
        if (destParent.findFile(destName) != null) return false
        return source.renameTo(destName)
    }

    override fun copy(sourcePath: String, destinationPath: String): Boolean {
        val source = resolve(sourcePath) ?: return false
        val (destParent, destName) = parentAndName(destinationPath) ?: return false
        return copyDocument(source, destParent, destName)
    }

    private fun copyDocument(source: DocumentFile, destParent: DocumentFile, destName: String): Boolean {
        val created = if (source.isDirectory) {
            destParent.createDirectory(destName)
        } else {
            destParent.createFile(storageMime(destName, source.type), destName)
        } ?: return false

        if (source.isDirectory) {
            return source.listFiles().all { child ->
                val childName = child.name ?: return@all false
                copyDocument(child, created, childName)
            }
        }

        val inStream = resolver.openInputStream(source.uri) ?: return false
        val outStream = resolver.openOutputStream(created.uri, "wt") ?: return false
        inStream.use { input -> outStream.use { output -> input.copyTo(output) } }
        return true
    }
}

fun normalizedPath(path: String): String {
    val trimmed = path.trim()
    if (trimmed.isEmpty() || trimmed == "/") return "/"
    return "/" + trimmed.trim('/').split('/').filter { it.isNotBlank() }.joinToString("/")
}
