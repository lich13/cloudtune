package com.gosu.cloudtune.core

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

object AtomicFileIO {
    fun writeBytes(target: File, bytes: ByteArray) {
        if (target.isDirectory) {
            throw IOException("Target path is an existing directory: $target")
        }
        val parent = (target.absoluteFile.parentFile ?: File(".")).also { it.mkdirs() }
        val tmp = File(parent, ".${target.name}.${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(tmp).use { out ->
                out.write(bytes)
                out.fd.sync()
            }
            replaceAtomically(tmp, target)
        } finally {
            if (tmp.exists()) {
                tmp.delete()
            }
        }
    }

    fun writeText(target: File, content: String) {
        writeBytes(target, content.toByteArray(Charsets.UTF_8))
    }

    fun replaceAtomically(source: File, target: File) {
        if (target.isDirectory) {
            throw IOException("Target path is an existing directory: $target")
        }
        target.absoluteFile.parentFile?.mkdirs()
        try {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE
            )
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING
            )
        }
    }
}
