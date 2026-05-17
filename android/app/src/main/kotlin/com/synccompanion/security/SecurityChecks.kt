package com.synccompanion.security

import android.os.Build
import java.io.File

/**
 * Static heuristics for detecting a rooted or Magisk-modified device.
 * Results are advisory — callers should warn the user, not block them outright.
 */
object SecurityChecks {

    /**
     * Returns `true` if any root indicator is detected.
     * Combines all three independent checks so that no single bypass defeats detection.
     */
    fun isRooted(): Boolean = checkSuBinaries() || checkBuildTags() || checkMagisk()

    /**
     * Scans a list of common filesystem paths for the `su` binary used by root
     * frameworks like SuperSU and KingRoot. Covers standard system bins,
     * legacy locations, and user-writable partitions.
     *
     * @return `true` if a `su` binary exists at any known path.
     */
    private fun checkSuBinaries(): Boolean {
        val paths = listOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su",
            "/system/su", "/system/bin/.ext/su", "/system/usr/we-need-root/su-backup",
            "/data/local/xbin/su", "/data/local/bin/su", "/data/local/su"
        )
        return paths.any { File(it).exists() }
    }

    /**
     * Checks [Build.TAGS] for the string `"test-keys"`, indicating firmware signed
     * with AOSP public test keys rather than OEM production keys.
     * Common on custom ROMs; occasionally present on OEM developer builds too.
     *
     * @return `true` if the build tag contains `"test-keys"`.
     */
    private fun checkBuildTags(): Boolean {
        val tags = Build.TAGS ?: return false
        return tags.contains("test-keys")
    }

    /**
     * Looks for Magisk-specific directories and binaries. Magisk's magic-mount
     * technique hides most system modifications, but its own daemon and module
     * directories remain discoverable via direct filesystem access.
     *
     * @return `true` if any known Magisk path exists on the filesystem.
     */
    private fun checkMagisk(): Boolean {
        val magiskPaths = listOf(
            "/sbin/.magisk", "/cache/.magisk", "/data/.magisk",
            "/sbin/magisk", "/system/bin/magisk"
        )
        return magiskPaths.any { File(it).exists() }
    }
}
