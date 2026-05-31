package com.synccompanion.server

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import kotlin.io.path.createTempDirectory

class FileStorageBackendTest {

    private lateinit var root: File
    private lateinit var backend: FileStorageBackend

    @Before
    fun setUp() {
        root = createTempDirectory("midoid-test").toFile()
        backend = FileStorageBackend(root, "Test Root")
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    // MARK: - exists()

    @Test
    fun `exists true for root`() {
        assertTrue(backend.exists("/"))
    }

    @Test
    fun `exists true for created file`() {
        File(root, "a.txt").writeText("x")
        assertTrue(backend.exists("/a.txt"))
    }

    @Test
    fun `exists false for missing path`() {
        assertFalse(backend.exists("/missing.txt"))
    }

    @Test
    fun `path traversal stays within root`() {
        assertFalse(backend.exists("/../../../etc/passwd"))
    }

    // MARK: - entry()

    @Test
    fun `entry for root uses rootDisplayName`() {
        val e = backend.entry("/")
        assertNotNull(e)
        assertEquals("Test Root", e!!.name)
        assertTrue(e.isDirectory)
    }

    @Test
    fun `entry for file returns correct metadata`() {
        File(root, "doc.pdf").writeText("PDF")
        val e = backend.entry("/doc.pdf")
        assertNotNull(e)
        assertEquals("doc.pdf", e!!.name)
        assertFalse(e.isDirectory)
        assertEquals(3L, e.length)
    }

    @Test
    fun `entry returns null for missing path`() {
        assertNull(backend.entry("/nofile.txt"))
    }

    @Test
    fun `entry for directory`() {
        File(root, "subdir").mkdir()
        val e = backend.entry("/subdir")
        assertNotNull(e)
        assertTrue(e!!.isDirectory)
    }

    // MARK: - list()

    @Test
    fun `list returns children of root`() {
        File(root, "a.txt").writeText("a")
        File(root, "b.txt").writeText("b")
        val children = backend.list("/")
        assertEquals(2, children.size)
        assertTrue(children.any { it.name == "a.txt" })
        assertTrue(children.any { it.name == "b.txt" })
    }

    @Test
    fun `list returns empty for missing dir`() {
        assertEquals(emptyList<StorageEntry>(), backend.list("/nodir"))
    }

    @Test
    fun `list does not recurse into subdirs`() {
        val sub = File(root, "sub").also { it.mkdir() }
        File(sub, "nested.txt").writeText("n")
        File(root, "top.txt").writeText("t")
        val children = backend.list("/")
        // Only top.txt and sub/ — not nested.txt
        assertEquals(2, children.size)
    }

    // MARK: - write()

    @Test
    fun `write creates file with correct content`() {
        val data = "hello world".toByteArray()
        backend.write("/new.txt", ByteArrayInputStream(data), data.size.toLong())
        assertEquals("hello world", File(root, "new.txt").readText())
    }

    @Test
    fun `write creates parent directories`() {
        val data = "x".toByteArray()
        backend.write("/a/b/c.txt", ByteArrayInputStream(data), data.size.toLong())
        assertTrue(File(root, "a/b/c.txt").exists())
    }

    @Test
    fun `write overwrites existing file`() {
        File(root, "f.txt").writeText("old")
        val new = "new content".toByteArray()
        backend.write("/f.txt", ByteArrayInputStream(new), new.size.toLong())
        assertEquals("new content", File(root, "f.txt").readText())
    }

    // MARK: - delete()

    @Test
    fun `delete removes file`() {
        File(root, "del.txt").writeText("x")
        assertTrue(backend.delete("/del.txt"))
        assertFalse(File(root, "del.txt").exists())
    }

    @Test
    fun `delete removes directory recursively`() {
        val sub = File(root, "sub").also { it.mkdir() }
        File(sub, "inner.txt").writeText("x")
        backend.delete("/sub")
        assertFalse(sub.exists())
    }

    @Test
    fun `delete returns false for missing path`() {
        assertFalse(backend.delete("/nothere.txt"))
    }

    // MARK: - makeDirectory()

    @Test
    fun `makeDirectory creates new directory`() {
        assertTrue(backend.makeDirectory("/newdir"))
        assertTrue(File(root, "newdir").isDirectory)
    }

    @Test
    fun `makeDirectory returns false if already exists`() {
        File(root, "existing").mkdir()
        assertFalse(backend.makeDirectory("/existing"))
    }

    @Test
    fun `makeDirectory returns false if parent missing`() {
        assertFalse(backend.makeDirectory("/noparent/child"))
    }

    // MARK: - move()

    @Test
    fun `move renames file`() {
        File(root, "src.txt").writeText("data")
        assertTrue(backend.move("/src.txt", "/dst.txt"))
        assertFalse(File(root, "src.txt").exists())
        assertEquals("data", File(root, "dst.txt").readText())
    }

    @Test
    fun `move works across subdirectories`() {
        File(root, "sub").mkdir()
        File(root, "src.txt").writeText("x")
        backend.move("/src.txt", "/sub/moved.txt")
        assertTrue(File(root, "sub/moved.txt").exists())
    }

    // MARK: - copy()

    @Test
    fun `copy duplicates file content`() {
        File(root, "orig.txt").writeText("original")
        assertTrue(backend.copy("/orig.txt", "/copy.txt"))
        assertEquals("original", File(root, "copy.txt").readText())
        assertTrue(File(root, "orig.txt").exists())
    }

    @Test
    fun `copy recursively duplicates directory`() {
        val sub = File(root, "dir").also { it.mkdir() }
        File(sub, "inner.txt").writeText("inner")
        backend.copy("/dir", "/dir-copy")
        assertEquals("inner", File(root, "dir-copy/inner.txt").readText())
    }

    // MARK: - storageMime()

    @Test
    fun `storageMime jpg`() {
        assertEquals("image/jpeg", storageMime("photo.jpg"))
    }

    @Test
    fun `storageMime mp4`() {
        assertEquals("video/mp4", storageMime("clip.mp4"))
    }

    @Test
    fun `storageMime unknown extension`() {
        assertEquals("application/octet-stream", storageMime("file.xyz"))
    }

    @Test
    fun `storageMime no extension`() {
        assertEquals("application/octet-stream", storageMime("noext"))
    }

    @Test
    fun `storageMime explicit type overrides extension`() {
        assertEquals("image/png", storageMime("photo.jpg", explicitType = "image/png"))
    }

    @Test
    fun `storageMime case insensitive extension`() {
        assertEquals("image/jpeg", storageMime("PHOTO.JPEG"))
    }

    @Test
    fun `storageMime pdf`() {
        assertEquals("application/pdf", storageMime("doc.pdf"))
    }

    @Test
    fun `storageMime zip`() {
        assertEquals("application/zip", storageMime("archive.zip"))
    }

    @Test
    fun `storageMime mp3`() {
        assertEquals("audio/mpeg", storageMime("song.mp3"))
    }

    @Test
    fun `storageMime png`() {
        assertEquals("image/png", storageMime("img.png"))
    }
}
