package com.photocleaner.mobile_storage_cleaner

import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.photocleaner/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageInfo" -> {
                        try {
                            result.success(getStorageInfo())
                        } catch (e: Exception) {
                            result.error("storage_error", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getStorageInfo(): Map<String, Long> {
        val stat = StatFs(Environment.getExternalStorageDirectory().absolutePath)
        val totalBytes = stat.totalBytes
        val freeBytes = stat.availableBytes

        val photosBytes = try {
            mediaSize(MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
        } catch (_: Exception) {
            0L
        }
        val videosBytes = try {
            mediaSize(MediaStore.Video.Media.EXTERNAL_CONTENT_URI)
        } catch (_: Exception) {
            0L
        }

        return mapOf(
            "totalBytes" to totalBytes,
            "freeBytes" to freeBytes,
            "photosBytes" to photosBytes,
            "videosBytes" to videosBytes,
        )
    }

    private fun mediaSize(uri: Uri): Long {
        val projection = arrayOf(MediaStore.MediaColumns.SIZE)
        var total = 0L
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            val sizeIndex = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
            if (sizeIndex >= 0) {
                while (cursor.moveToNext()) {
                    total += cursor.getLong(sizeIndex)
                }
            }
        }
        return total
    }
}
