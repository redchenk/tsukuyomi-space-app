package space.tsukuyomi.tsukuyomi_space_app

import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.tencent.tauth.IUiListener
import com.tencent.tauth.Tencent
import com.tencent.tauth.UiError
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** SDK initialization happens only after the per-use QQ consent dialog. */
class NativeQQAuth(private val activity: MainActivity) {
    companion object { const val APP_ID = "1905926637" }
    private var sdk: Tencent? = null
    private var pending: MethodChannel.Result? = null
    private var listener: IUiListener? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { fail("timeout", "QQ 授权超时，请重试") }

    fun login(consent: Boolean, result: MethodChannel.Result) {
        if (!consent) { result.error("consent", "请先阅读并同意 QQ 登录说明", null); return }
        if (pending != null) { result.error("busy", "QQ 授权正在进行", null); return }
        try {
            Tencent.setIsPermissionGranted(true)
            val client = sdk ?: Tencent.createInstance(APP_ID, activity.applicationContext).also { sdk = it }
            if (client == null || !client.isQQInstalled(activity) || !client.isSupportSSOLogin(activity)) {
                result.error("not_installed", "请安装或更新 QQ 后重试，也可以使用邮箱或密码登录", null)
                return
            }
            client.logout(activity)
            pending = result
            val callback = object : IUiListener {
                override fun onComplete(value: Any?) {
                    if (pending !== result) return
                    val data = value as? JSONObject
                    val token = data?.optString("access_token") ?: ""
                    val openId = data?.optString("openid") ?: ""
                    if (!token.matches(Regex("[A-Za-z0-9_-]{16,256}")) || !openId.matches(Regex("[a-fA-F0-9]{32}"))) {
                        fail("invalid", "QQ 返回的授权信息无效，请重试"); return
                    }
                    clear()
                    result.success(mapOf("clientId" to APP_ID, "accessToken" to token, "openId" to openId))
                }
                override fun onError(error: UiError?) {
                    if (pending === result) fail("provider", "QQ 授权失败，请检查应用审核状态及调试账号后重试")
                }
                override fun onCancel() { if (pending === result) fail("cancelled", "QQ 授权已取消") }
                override fun onWarning(code: Int) { /* Never log provider payloads. */ }
            }
            listener = callback
            handler.postDelayed(timeout, 120000)
            val mode = client.login(activity, "get_simple_userinfo", callback)
            if (pending === result && mode != 0 && mode != 1) fail("sso", "无法使用 QQ 客户端授权，请更新 QQ 后重试")
        } catch (_: Exception) {
            if (pending === result) fail("launch", "无法启动 QQ 授权，请重试")
            else result.error("launch", "无法启动 QQ 授权，请重试", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val active = listener ?: return
        if (requestCode == Tencent.REQUEST_LOGIN) Tencent.onActivityResultData(requestCode, resultCode, data, active)
    }
    private fun clear() {
        handler.removeCallbacks(timeout)
        pending = null
        listener = null
        sdk?.logout(activity)
    }
    private fun fail(code: String, message: String) {
        val result = pending ?: return
        clear()
        result.error(code, message, null)
    }
    fun dispose() { fail("cancelled", "QQ 授权已取消") }
}
