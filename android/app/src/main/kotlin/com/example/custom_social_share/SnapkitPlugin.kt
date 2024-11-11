package com.example.custom_social_share

import android.app.Activity
import androidx.annotation.NonNull
import androidx.annotation.Nullable
import com.snapchat.kit.sdk.SnapCreative
import com.snapchat.kit.sdk.SnapLogin
import com.snapchat.kit.sdk.creative.api.SnapCreativeKitApi
import com.snapchat.kit.sdk.creative.exceptions.SnapMediaSizeException
import com.snapchat.kit.sdk.creative.exceptions.SnapStickerSizeException
import com.snapchat.kit.sdk.creative.exceptions.SnapVideoLengthException
import com.snapchat.kit.sdk.creative.media.SnapMediaFactory
import com.snapchat.kit.sdk.creative.media.SnapPhotoFile
import com.snapchat.kit.sdk.creative.media.SnapSticker
import com.snapchat.kit.sdk.creative.media.SnapVideoFile
import com.snapchat.kit.sdk.creative.models.SnapContent
import com.snapchat.kit.sdk.creative.models.SnapLiveCameraContent
import com.snapchat.kit.sdk.creative.models.SnapPhotoContent
import com.snapchat.kit.sdk.creative.models.SnapVideoContent
import com.snapchat.kit.sdk.login.models.MeData
import com.snapchat.kit.sdk.login.models.UserDataResponse
import com.snapchat.kit.sdk.login.networking.FetchUserDataCallback
import com.snapchat.kit.sdk.util.SnapUtils
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.io.File

class SnapkitPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, OnLoginStateChangedListener {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var resultCallback: MethodChannel.Result? = null
    private var creativeKitApi: SnapCreativeKitApi? = null
    private var mediaFactory: SnapMediaFactory? = null

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "snapkit")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "callLogin" -> {
                activity?.let {
                    SnapLogin.getLoginStateController(it).addOnLoginStateChangedListener(this)
                    SnapLogin.getAuthTokenManager(it).startTokenGrant()
                    resultCallback = result
                }
            }
            "getUser" -> {
                val query = "{me{externalId, displayName, bitmoji{selfie}}}"
                activity?.let { act ->
                    SnapLogin.fetchUserData(act, query, null, object : FetchUserDataCallback {
                        override fun onSuccess(@Nullable userDataResponse: UserDataResponse?) {
                            val meData: MeData? = userDataResponse?.data?.me
                            if (meData == null) {
                                result.error("GetUserError", "Returned MeData was null", null)
                            } else {
                                val res = listOf(
                                    meData.externalId,
                                    meData.displayName,
                                    meData.bitmojiData?.selfie
                                )
                                result.success(res)
                            }
                        }

                        override fun onFailure(isNetworkError: Boolean, statusCode: Int) {
                            val errorCode = if (isNetworkError) "NetworkGetUserError" else "UnknownGetUserError"
                            result.error(errorCode, "Error fetching user data", statusCode)
                        }
                    })
                }
            }
            "sendMedia" -> sendMediaContent(call, result)
            "verifyNumber" -> result.success(listOf("", ""))
            "callLogout" -> {
                activity?.let {
                    SnapLogin.getAuthTokenManager(it).clearToken()
                    resultCallback = result
                }
            }
            "isInstalled" -> result.success(activity?.let { SnapUtils.isSnapchatInstalled(it.packageManager, "com.snapchat.android") })
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
            else -> result.notImplemented()
        }
    }

    private fun sendMediaContent(call: MethodCall, result: MethodChannel.Result) {
        activity?.let { act ->
            creativeKitApi = creativeKitApi ?: SnapCreative.getApi(act)
            mediaFactory = mediaFactory ?: SnapCreative.getMediaFactory(act)

            val content: SnapContent? = when (call.argument<String>("mediaType")) {
                "PHOTO" -> try {
                    val photoFile = mediaFactory?.getSnapPhotoFromFile(File(call.argument("imagePath")!!))
                    SnapPhotoContent(photoFile)
                } catch (e: SnapMediaSizeException) {
                    result.error("SendMediaError", "Could not create SnapPhotoFile", e)
                    return
                }
                "VIDEO" -> try {
                    val videoFile = mediaFactory?.getSnapVideoFromFile(File(call.argument("videoPath")!!))
                    SnapVideoContent(videoFile)
                } catch (e: SnapMediaSizeException) {
                    result.error("SendMediaError", "Could not create SnapVideoFile", e)
                    return
                } catch (e: SnapVideoLengthException) {
                    result.error("SendMediaError", "Video length exceeded", e)
                    return
                }
                else -> SnapLiveCameraContent()
            }

            content?.apply {
                setCaptionText(call.argument("caption"))
                setAttachmentUrl(call.argument("attachmentUrl"))

                call.argument<Map<String, Any>>("sticker")?.let { stickerMap ->
                    val sticker = try {
                        mediaFactory?.getSnapStickerFromFile(File(stickerMap["imagePath"] as String))
                    } catch (e: SnapStickerSizeException) {
                        result.error("SendMediaError", "Could not create SnapSticker", e)
                        return
                    }
                    sticker?.apply {
                        widthDp = stickerMap["width"]?.toString()?.toFloat() ?: 100f
                        heightDp = stickerMap["height"]?.toString()?.toFloat() ?: 100f
                        posX = stickerMap["offsetX"]?.toString()?.toFloat() ?: 0f
                        posY = stickerMap["offsetY"]?.toString()?.toFloat() ?: 0f
                        rotationDegreesClockwise = stickerMap["rotation"]?.toString()?.toFloat() ?: 0f
                    }
                    setSnapSticker(sticker)
                }

                creativeKitApi?.send(this)
            }
        }
    }

    override fun onLoginSucceeded() {
        resultCallback?.success("Login Success")
    }

    override fun onLoginFailed() {
        resultCallback?.error("LoginError", "Error Logging In", null)
    }

    override fun onLogout() {
        resultCallback?.success("Logout Success")
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}

    override fun onDetachedFromActivity() {}
}
