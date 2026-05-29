package com.synccompanion.server

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.InputStream
import java.net.URLDecoder

/**
 * Metadata snapshot of a single file or directory entry returned by a [StorageBackend].
 *
 * @property name         Display name of the file or directory.
 * @property path         Normalized absolute path (always starts with "/").
 * @property isDirectory  `true` if this entry is a folder.
 * @property length       File size in bytes; 0 for directories.
 * @property lastModified Last-modified timestamp in milliseconds since the Unix epoch.
 * @property mimeType     MIME type if known by the underlying provider, otherwise `null`.
 */
data class StorageEntry(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val length: Long,
    val lastModified: Long,
    val mimeType: String?
)

/**
 * Abstraction over the Android filesystem that the WebDAV layer uses for all I/O.
 *
 * Two concrete implementations exist:
 * - [FileStorageBackend] — standard Java File I/O, used with MANAGE_EXTERNAL_STORAGE or app storage.
 * - [DocumentTreeStorageBackend] — SAF-based, used when the user picks a specific folder.
 */
interface StorageBackend {
    /** Human-readable label shown as the root folder name in WebDAV clients (e.g. macOS Finder). */
    val rootDisplayName: String

    /** Returns `true` if a file or directory exists at [path]. */
    fun exists(path: String): Boolean

    /**
     * Returns metadata for the resource at [path], or `null` if it does not exist.
     *
     * @param path  Normalized absolute path.
     */
    fun entry(path: String): StorageEntry?

    /**
     * Lists the immediate children of the directory at [path].
     * Returns an empty list if the path does not exist or is not a directory.
     *
     * @param path  Normalized absolute path of the parent directory.
     */
    fun list(path: String): List<StorageEntry>

    /**
     * Opens a streaming reader for the file at [path].
     *
     * Used by WebDAV GET so large files do not need to fit in Android memory.
     */
    fun openRead(path: String): InputStream?

    /**
     * Writes [contentLength] bytes from [input] to [path], creating or overwriting the file.
     *
     * @param path          Normalized absolute destination path.
     * @param input         Source [InputStream] positioned at the first byte to write.
     * @param contentLength Exact number of bytes to read from [input].
     * @return `true` on success, `false` if the write could not be completed.
     */
    fun write(path: String, input: InputStream, contentLength: Long): Boolean

    /**
     * Deletes the file or directory (recursively for directories) at [path].
     *
     * @return `true` if the resource was deleted, `false` otherwise.
     */
    fun delete(path: String): Boolean

    /**
     * Creates a new directory at [path].
     *
     * @return `false` if the directory already exists or the parent directory is missing.
     */
    fun makeDirectory(path: String): Boolean

    /**
     * Moves (renames) the resource from [sourcePath] to [destinationPath].
     *
     * @return `true` on success.
     */
    fun move(sourcePath: String, destinationPath: String): Boolean

    /**
     * Copies the resource (recursively for directories) from [sourcePath] to [destinationPath].
     *
     * @return `true` on success.
     */
    fun copy(sourcePath: String, destinationPath: String): Boolean
}

/**
 * Resolves a MIME type string from a filename extension.
 * Falls back to `application/octet-stream` for unrecognized extensions.
 *
 * @param name          Filename including extension (e.g. "photo.jpg").
 * @param explicitType  If non-null, returned as-is — lets the SAF provider's known type take precedence.
 * @return              A valid MIME type string.
 */
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

/**
 * Splits [path] into decoded, non-empty path segments.
 * Used internally by both backends to walk a path component by component.
 */
private fun cleanSegments(path: String): List<String> =
    path.trim('/').split('/').filter { it.isNotBlank() }.map {
        URLDecoder.decode(it, "UTF-8")
    }

/**
 * Constructs a child path by appending [childName] to [parentPath].
 * Handles the root case ("/") correctly to avoid double slashes.
 */
private fun childPath(parentPath: String, childName: String): String {
    return if (parentPath == "/" || parentPath.isBlank()) "/$childName" else "${parentPath.trimEnd('/')}/$childName"
}

/**
 * [StorageBackend] backed by standard Java [File] I/O.
 *
 * Used when the app holds MANAGE_EXTERNAL_STORAGE permission (full device storage),
 * or as a fallback to the app's private external files directory.
 *
 * Path traversal attacks are prevented by canonicalizing every resolved [File] and
 * rejecting any path that falls outside [root].
 *
 * @param root             Base [File] directory exposed as the WebDAV root.
 * @param rootDisplayName  Label shown to WebDAV clients for the root collection.
 */
class FileStorageBackend(
    private val root: File,
    override val rootDisplayName: String = "MiDoid Storage"
) : StorageBackend {

    private val rootCanon: File get() = root.canonicalFile

    /**
     * Resolves a WebDAV path to a local [File], guarding against path traversal.
     * If the canonical result escapes [root], the root itself is returned as a safe fallback.
     *
     * @param path  Normalized WebDAV path.
     * @return      A [File] guaranteed to be inside [root].
     */
    private fun resolve(path: String): File {
        val candidate = cleanSegments(path).fold(rootCanon) { dir, segment -> File(dir, segment) }.canonicalFile
        return if (candidate == rootCanon || candidate.path.startsWith(rootCanon.path + File.separator)) {
            candidate
        } else {
            rootCanon
        }
    }

    /** @see StorageBackend.exists */
    override fun exists(path: String): Boolean = resolve(path).exists()

    /**
     * @see StorageBackend.entry
     * Uses the [rootDisplayName] as the display name when [path] refers to the root directory.
     */
    override fun entry(path: String): StorageEntry? {
        val file = resolve(path)
        if (!file.exists()) return null
        val name = if (path == "/" || path.isBlank()) rootDisplayName else file.name
        return StorageEntry(name, normalizedPath(path), file.isDirectory, file.length(), file.lastModified(), null)
    }

    /** @see StorageBackend.list */
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

    /** @see StorageBackend.openRead */
    override fun openRead(path: String): InputStream? = resolve(path).inputStream()

    /**
     * @see StorageBackend.write
     * Creates parent directories as needed. Uses a 16 KB copy buffer for efficiency.
     */
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

    /** @see StorageBackend.delete */
    override fun delete(path: String): Boolean = resolve(path).deleteRecursively()

    /**
     * @see StorageBackend.makeDirectory
     * Returns `false` if the directory already exists or if the parent does not yet exist
     * (intermediate directories are not created automatically).
     */
    override fun makeDirectory(path: String): Boolean {
        val dir = resolve(path)
        if (dir.exists()) return false
        if (dir.parentFile?.exists() == false) return false
        return dir.mkdir()
    }

    /** @see StorageBackend.move */
    override fun move(sourcePath: String, destinationPath: String): Boolean =
        resolve(sourcePath).renameTo(resolve(destinationPath).also { it.parentFile?.mkdirs() })

    /** @see StorageBackend.copy */
    override fun copy(sourcePath: String, destinationPath: String): Boolean =
        resolve(sourcePath).copyRecursively(resolve(destinationPath).also { it.parentFile?.mkdirs() }, overwrite = true)
}

/**
 * [StorageBackend] backed by the Android Storage Access Framework (SAF).
 *
 * Used when the user grants access to a specific folder via
 * [androidx.activity.result.contract.ActivityResultContracts.OpenDocumentTree].
 * All I/O is routed through [ContentResolver] using the persisted URI permission,
 * making it compatible with Android 10+ scoped-storage restrictions without
 * requiring MANAGE_EXTERNAL_STORAGE.
 *
 * @param context          Required to obtain [DocumentFile] references from content URIs.
 * @param resolver         The app's [ContentResolver] for stream-based I/O.
 * @param treeUri          The SAF tree URI granted and persisted by the user.
 * @param rootDisplayName  Label shown to WebDAV clients for the root collection.
 */
class DocumentTreeStorageBackend(
    context: Context,
    private val resolver: ContentResolver,
    treeUri: Uri,
    override val rootDisplayName: String = "MiDoid Folder"
) : StorageBackend {

    private val root = DocumentFile.fromTreeUri(context, treeUri)

    /**
     * Walks the [DocumentFile] tree from [root] following each path segment in order.
     *
     * @param path  Normalized WebDAV path.
     * @return      The [DocumentFile] at that path, or `null` if any segment is not found.
     */
    private fun resolve(path: String): DocumentFile? {
        var current = root ?: return null
        for (segment in cleanSegments(path)) {
            current = current.findFile(segment) ?: return null
        }
        return current
    }

    /**
     * Resolves the parent [DocumentFile] and the leaf file name for a given path.
     * Used before create/delete/move operations that need to address the parent directory.
     *
     * @param path  Normalized WebDAV path of the target resource.
     * @return      A pair of (parent [DocumentFile], leaf name), or `null` if the parent does not exist.
     */
    private fun parentAndName(path: String): Pair<DocumentFile, String>? {
        val segments = cleanSegments(path)
        val name = segments.lastOrNull() ?: return null
        val parentPath = "/" + segments.dropLast(1).joinToString("/")
        val parent = resolve(parentPath) ?: return null
        return parent to name
    }

    /** @see StorageBackend.exists */
    override fun exists(path: String): Boolean = resolve(path)?.exists() == true

    /**
     * @see StorageBackend.entry
     * Uses the [rootDisplayName] as the display name when [path] refers to the root directory.
     */
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

    /** @see StorageBackend.list */
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

    /** @see StorageBackend.openRead */
    override fun openRead(path: String): InputStream? {
        val uri = resolve(path)?.uri ?: return null
        return resolver.openInputStream(uri)
    }

    /**
     * @see StorageBackend.write
     * Opens the existing file for overwrite (`"wt"` mode) or creates a new file via the parent
     * [DocumentFile]. Uses a 16 KB copy buffer for efficiency.
     */
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

    /** @see StorageBackend.delete */
    override fun delete(path: String): Boolean = resolve(path)?.delete() == true

    /**
     * @see StorageBackend.makeDirectory
     * Returns `false` if a file or directory with that name already exists in the parent.
     */
    override fun makeDirectory(path: String): Boolean {
        val (parent, name) = parentAndName(path) ?: return false
        if (parent.findFile(name) != null) return false
        return parent.createDirectory(name) != null
    }

    /**
     * @see StorageBackend.move
     * SAF only supports renaming within the same parent directory.
     * Cross-directory moves return `false`; the caller should implement copy-then-delete if needed.
     */
    override fun move(sourcePath: String, destinationPath: String): Boolean {
        val source = resolve(sourcePath) ?: return false
        val (destParent, destName) = parentAndName(destinationPath) ?: return false
        val sourceParentPath = "/" + cleanSegments(sourcePath).dropLast(1).joinToString("/")
        val destParentPath = "/" + cleanSegments(destinationPath).dropLast(1).joinToString("/")
        if (normalizedPath(sourceParentPath) != normalizedPath(destParentPath)) return false
        if (destParent.findFile(destName) != null) return false
        return source.renameTo(destName)
    }

    /** @see StorageBackend.copy */
    override fun copy(sourcePath: String, destinationPath: String): Boolean {
        val source = resolve(sourcePath) ?: return false
        val (destParent, destName) = parentAndName(destinationPath) ?: return false
        return copyDocument(source, destParent, destName)
    }

    /**
     * Recursively copies a [DocumentFile] tree into [destParent] under [destName].
     * Creates directories before copying their children. For files, streams bytes
     * directly between [ContentResolver] input and output streams.
     *
     * @param source      Source [DocumentFile] (file or directory).
     * @param destParent  Destination parent [DocumentFile] directory.
     * @param destName    Name to give the newly created copy.
     * @return `true` if the entire subtree was copied successfully.
     */
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

/**
 * Normalizes an arbitrary path string to a canonical absolute form.
 *
 * Rules applied: strips leading/trailing whitespace, collapses repeated slashes,
 * removes empty path segments. The root path `"/"` is always returned unchanged.
 *
 * @param path  The raw path string to normalize (e.g. `"//photos//2024/"` → `"/photos/2024"`).
 * @return      A clean absolute path starting with `"/"`.
 */
fun normalizedPath(path: String): String {
    val trimmed = path.trim()
    if (trimmed.isEmpty() || trimmed == "/") return "/"
    return "/" + trimmed.trim('/').split('/').filter { it.isNotBlank() }.joinToString("/")
}
