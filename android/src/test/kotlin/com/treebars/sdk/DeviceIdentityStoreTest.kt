package com.treebars.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The device's id and secret, one pair in one file outside every backup. What is pinned: a pair is
 * minted once and then agrees with itself, a wrapper's hand-down lands only in an empty store, a
 * half-written file is no pair at all, and erasing it makes a new device — never a device with its
 * old id and a new secret: the two only mean anything together.
 */
class DeviceIdentityStoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun store() = DeviceIdentityStore(folder.root)

    @Test
    fun mintsOnceAndThenAgreesWithItself() {
        val (first, minted) = store().resolve()
        assertTrue(minted)
        assertTrue(first.id.startsWith("dev_"))
        assertEquals(64, first.secret.length)

        val (again, mintedAgain) = store().resolve()
        assertFalse(mintedAgain)
        assertEquals(first, again)
    }

    @Test
    fun takesAHandedDownPairOnlyIntoAnEmptyStore() {
        val handed = DeviceIdentity("dev_from_js", "secret_from_js")
        assertEquals(handed to true, store().resolve(adopted = handed))
        // A stale copy handed down on a later launch cannot overwrite what this device holds.
        assertEquals(handed to false, store().resolve(adopted = DeviceIdentity("dev_other", "secret_other")))
    }

    @Test
    fun aHalfWrittenOrEmptyFileIsNoPair() {
        File(folder.root, DeviceIdentityStore.FILE_NAME).writeText("dev_only\n")
        assertNull(store().read())
        File(folder.root, DeviceIdentityStore.FILE_NAME).writeText("")
        assertNull(store().read())
    }

    @Test
    fun erasingStartsANewDeviceRatherThanANewSecret() {
        val (first, _) = store().resolve()
        store().erase()
        val (second, minted) = store().resolve()
        assertTrue(minted)
        assertNotEquals(first.id, second.id)
        assertNotEquals(first.secret, second.secret)
    }

    @Test
    fun aPairThatCannotBeWrittenIsStillThisProcessesAndNeverAnException() {
        // A directory that cannot be made: a file stands where it would go.
        val store = DeviceIdentityStore(File(folder.newFile("blocker"), "treebars"))
        val (pair, minted) = store.resolve()
        assertTrue(minted)
        assertTrue(pair.id.startsWith("dev_"))
        assertFalse(store.write(pair))
        assertNull(store.read())
    }

    @Test
    fun livesInTheDirectoryItIsGiven() {
        // `noBackupFilesDir` in production: what Auto Backup and a device transfer both leave behind.
        store().resolve()
        assertTrue(File(folder.root, DeviceIdentityStore.FILE_NAME).isFile)
        assertFalse(File(folder.root, "${DeviceIdentityStore.FILE_NAME}.tmp").exists())
    }
}
