package com.synccompanion.security

import android.os.Build
import java.io.File

object SecurityChecks {

    fun isRooted(): Boolean = checkSuBinaries() || checkBuildTags() || checkMagisk()

    private fun checkSuBinaries(): Boolean {
        val paths = listOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su",
            "/system/su", "/system/bin/.ext/su", "/system/usr/we-need-root/su-backup",
            "/data/local/xbin/su", "/data/local/bin/su", "/data/local/su"
        )
        return paths.any { File(it).exists() }
    }

    private fun checkBuildTags(): Boolean {
        val tags = Build.TAGS ?: return false
        return tags.contains("test-keys")
    }

    private fun checkMagisk(): Boolean {
        val magiskPaths = listOf(
            "/sbin/.magisk", "/cache/.magisk", "/data/.magisk",
            "/sbin/magisk", "/system/bin/magisk"
        )
        return magiskPaths.any { File(it).exists() }
    }
}
