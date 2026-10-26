package space.tsukuyomi.tsukuyomi_space_app

import android.app.Activity
import android.content.Intent
import com.tencent.connect.common.Constants
import com.tencent.tauth.IUiListener
import com.tencent.tauth.UiError
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Exercise the shipped Tencent SDK's result dispatcher, without QQ or a network login. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class NativeQQAuthCallbackTest {
    private lateinit var auth: NativeQQAuth
    private val completions = mutableListOf<JSONObject>()
    private val errors = mutableListOf<UiError?>()
    private var cancellations = 0

    @Before
    fun setUp() {
        auth = NativeQQAuth(Robolectric.buildActivity(Activity::class.java).setup().get())
        // Seed only an in-flight listener. Keep Tencent.onActivityResultData real:
        // a mocked MethodChannel test cannot catch an Android request-code mismatch.
        val listener = object : IUiListener {
            override fun onComplete(value: Any?) { completions.add(value as JSONObject) }
            override fun onError(error: UiError?) { errors.add(error) }
            override fun onCancel() { cancellations++ }
            override fun onWarning(code: Int) {}
        }
        NativeQQAuth::class.java.getDeclaredField("listener").apply {
            isAccessible = true
            set(auth, listener)
        }
    }

    private fun response() = Intent()
        .putExtra(Constants.KEY_ACTION, "action_login")
        .putExtra(Constants.KEY_ERROR_CODE, 0)
        .putExtra(Constants.KEY_RESPONSE, """{"ret":0,"access_token":"fixture_token_0123456789","openid":"0123456789ABCDEF0123456789ABCDEF"}""")

    @Test
    fun sdkSsoSuccessReachesTheActiveListener() {
        auth.onActivityResult(Constants.REQUEST_LOGIN, Activity.RESULT_OK, response())
        assertEquals(1, completions.size)
        assertEquals("0123456789ABCDEF0123456789ABCDEF", completions.single().getString("openid"))
        assertTrue(errors.isEmpty())
        assertEquals(0, cancellations)
    }

    @Test
    fun sdkCancelReachesTheActiveListener() {
        auth.onActivityResult(Constants.REQUEST_LOGIN, Activity.RESULT_CANCELED, null)
        assertEquals(1, cancellations)
        assertTrue(completions.isEmpty())
        assertTrue(errors.isEmpty())
    }

    @Test
    fun sdkErrorReachesTheActiveListener() {
        auth.onActivityResult(Constants.REQUEST_LOGIN, Activity.RESULT_OK, null)
        assertEquals(1, errors.size)
        assertTrue(completions.isEmpty())
    }

    @Test
    fun unrelatedActivityResultDoesNotCompleteOrCancelQQ() {
        auth.onActivityResult(42, Activity.RESULT_OK, response())
        auth.onActivityResult(42, Activity.RESULT_CANCELED, null)
        assertTrue(completions.isEmpty())
        assertTrue(errors.isEmpty())
        assertEquals(0, cancellations)
    }

    @Test
    fun callbackWithoutAnActiveLoginIsIgnored() {
        NativeQQAuth::class.java.getDeclaredField("listener").apply {
            isAccessible = true
            set(auth, null)
        }
        auth.onActivityResult(Constants.REQUEST_LOGIN, Activity.RESULT_OK, response())
        assertTrue(completions.isEmpty())
    }
}
