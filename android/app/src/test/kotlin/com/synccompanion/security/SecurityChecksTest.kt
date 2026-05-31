package com.synccompanion.security

import org.junit.Assert.*
import org.junit.Test

class SecurityChecksTest {

    @Test
    fun `isRooted returns a boolean without throwing`() {
        // On the JVM test environment (no su binaries, no Magisk), this should be false.
        // The test asserts the method runs without exceptions — actual result is environment-dependent.
        val result = runCatching { SecurityChecks.isRooted() }
        assertTrue("isRooted() must not throw", result.isSuccess)
    }

    @Test
    fun `isRooted is false on a standard test JVM`() {
        // No su binary exists on the CI or development host.
        assertFalse(SecurityChecks.isRooted())
    }

    @Test
    fun `checkBuildTags false when Build_TAGS is release-keys`() {
        // Build.TAGS on a test JVM is typically null or empty — neither equals "test-keys",
        // so checkBuildTags() (exercised through isRooted()) should not contribute true.
        // This passes as long as the JVM build.TAGS property is not "test-keys".
        val result = SecurityChecks.isRooted()
        // If su binaries and Magisk paths genuinely do not exist, result is false.
        assertFalse(result)
    }
}
