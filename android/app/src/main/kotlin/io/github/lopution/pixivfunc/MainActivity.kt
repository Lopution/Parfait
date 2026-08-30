package io.github.lopution.pixivfunc

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MediaStoreChannel.configure(this, flutterEngine)
        AndroidIntentChannel.configure(this, flutterEngine)
        ReverseImageInputChannel.configure(this, flutterEngine)
        AccountTransferClipboardChannel.configure(this, flutterEngine)
        WidgetForegroundChannel.configure(this, flutterEngine)
        DistributionUpdaterChannel.configure(this, flutterEngine)
        // Login WebView interception (PRD R7): native PlatformView registered
        // with the engine's platform views controller so Dart can embed it
        // with AndroidView(viewType: LoginWebViewPlatformView.viewType).
        flutterEngine.platformViewsController.registry.registerViewFactory(
            LoginWebViewPlatformView.viewType,
            LoginWebViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        AndroidIntentChannel.dispatch(this, intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (ReverseImageInputChannel.onActivityResult(this, requestCode, resultCode, data)) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
