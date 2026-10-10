package space.tsukuyomi.tsukuyomi_space_app

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "space.tsukuyomi/app_update")
            .setMethodCallHandler { call, result ->
                if (call.method == "supportedAbis") {
                    result.success(Build.SUPPORTED_ABIS.toList())
                } else if (call.method == "install") {
                    try {
                        val file = File(call.argument<String>("path") ?: "").canonicalFile
                        val root = File(cacheDir, "tsukuyomi-updates").canonicalFile
                        if (file.parentFile != root || !file.isFile || file.extension != "apk") {
                            result.error("storage", "Invalid update file", null)
                            return@setMethodCallHandler
                        }
                        @Suppress("DEPRECATION")
                        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
                                    else PackageManager.GET_SIGNATURES
                        @Suppress("DEPRECATION")
                        val archive = packageManager.getPackageArchiveInfo(file.path, flags)
                        @Suppress("DEPRECATION")
                        val current = packageManager.getPackageInfo(packageName, flags)
                        if (archive == null || archive.packageName != packageName) {
                            result.error("package", "Update package does not match", null)
                            return@setMethodCallHandler
                        }
                        if (signatures(archive) != signatures(current) || signatures(current).isEmpty()) {
                            result.error("signing", "Update signing certificate does not match", null)
                            return@setMethodCallHandler
                        }
                        if (versionCode(archive) <= versionCode(current)) {
                            result.error("downgrade", "Update is not newer than installed package", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")))
                            result.success("permissionRequired")
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                        startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        result.success("opened")
                    } catch (_: Exception) {
                        result.error("installer", "Unable to open system installer", null)
                    }
                } else { result.notImplemented() }
            }
    }

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners
         else info.signatures)?.map { it.toCharsString() }?.toSet() ?: emptySet()

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
}
