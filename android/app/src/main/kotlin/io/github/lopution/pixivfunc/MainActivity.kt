package io.github.lopution.pixivfunc

import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterSurfaceView
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
        SafTreeChannel.configure(this, flutterEngine)
        WebProfileChannel.configure(this, flutterEngine)
    }

    // On this device class, vsync delivery to the app drops to ~60Hz a few
    // seconds after the last touch and only a touch — or an explicit
    // Surface.setFrameRate vote — restores the full rate. Return animations
    // always play after the touch ends, so they alone ran inside the
    // throttled window. Voting the panel's top refresh rate on Flutter's
    // render surface keeps vsync delivery at full rate while foregrounded.
    override fun onFlutterSurfaceViewCreated(flutterSurfaceView: FlutterSurfaceView) {
        super.onFlutterSurfaceViewCreated(flutterSurfaceView)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // The surface is recreated across pause/resume and config
            // changes, so the vote re-applies on every surfaceCreated.
            flutterSurfaceView.holder.addCallback(
                object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) {
                        voteMaxRefreshRate(holder.surface)
                    }

                    override fun surfaceChanged(
                        holder: SurfaceHolder,
                        format: Int,
                        width: Int,
                        height: Int,
                    ) {}

                    override fun surfaceDestroyed(holder: SurfaceHolder) {}
                },
            )
            voteMaxRefreshRate(flutterSurfaceView.holder.surface)
        }
    }

    private fun voteMaxRefreshRate(surface: Surface) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        val maxRate =
            dm?.getDisplay(Display.DEFAULT_DISPLAY)
                ?.supportedModes
                ?.maxOfOrNull { it.refreshRate }
                ?: return
        try {
            surface.setFrameRate(maxRate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
        } catch (t: Throwable) {
            // Advisory hint only — an invalid/recreated surface just skips.
        }
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
        if (SafTreeChannel.onActivityResult(requestCode, resultCode, data)) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
