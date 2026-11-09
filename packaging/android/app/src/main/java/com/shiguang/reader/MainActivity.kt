package com.shiguang.reader

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Bundle
import android.webkit.WebView
import android.webkit.WebViewClient
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import java.net.HttpURLConnection
import java.net.URL

/**
 * 拾光阅读器 Android 版：
 * Chaquopy 在 APK 内运行原版 Python 服务（含全部书源解析），
 * WebView 加载 http://127.0.0.1:8791，体验与桌面版一致。
 */
class MainActivity : Activity() {

    private lateinit var web: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        web = WebView(this)
        setContentView(web)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.webViewClient = WebViewClient()

        // 启动 Python（数据目录 = 应用私有 filesDir，由 python 端读 SUDUGU_DATA）
        if (!Python.isStarted()) Python.start(AndroidPlatform(this))
        val dataDir = filesDir.absolutePath
        Thread {
            try {
                Python.getInstance().getModule("server.main").callAttr("android_main", dataDir)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }.start()

        // 轮询等待服务就绪后再加载页面
        val url = "http://127.0.0.1:8791/"
        Thread {
            var ok = false
            repeat(60) {
                if (ok) return@Thread
                try {
                    val c = URL(url).openConnection() as HttpURLConnection
                    c.connectTimeout = 1000
                    c.readTimeout = 1000
                    c.responseCode
                    c.disconnect()
                    ok = true
                } catch (_: Exception) {
                    Thread.sleep(500)
                }
            }
            runOnUiThread { web.loadUrl(url) }
        }.start()
    }

    override fun onBackPressed() {
        if (web.canGoBack()) web.goBack() else super.onBackPressed()
    }
}
