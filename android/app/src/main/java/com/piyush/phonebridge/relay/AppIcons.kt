package com.piyush.phonebridge.relay

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

object AppIcons {

    private val cache = ConcurrentHashMap<String, Pair<ByteArray, String>>()

    fun pngAndHash(pm: PackageManager, pkg: String): Pair<ByteArray, String>? {
        cache[pkg]?.let { return it }
        return try {
            val drawable = pm.getApplicationIcon(pkg)
            val size = 128
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            val png = out.toByteArray()
            val hex = MessageDigest.getInstance("SHA-256").digest(png)
                .joinToString("") { "%02x".format(it) }
            val result = png to "sha256:$hex"
            cache[pkg] = result
            result
        } catch (e: Exception) {
            null
        }
    }
}
