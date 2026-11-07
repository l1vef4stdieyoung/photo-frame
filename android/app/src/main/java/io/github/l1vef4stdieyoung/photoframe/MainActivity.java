package io.github.l1vef4stdieyoung.photoframe;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.WindowManager;

import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    /** Where the frame lives; updating the files there updates the app. */
    static final String BASE = "https://l1vef4stdieyoung.github.io/photo-frame/";

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(FramePlugin.class);
        super.onCreate(savedInstanceState);
        // a photo frame never goes to sleep on its own
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        hideSystemBars();
        handleLink(getIntent(), 1500);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleLink(intent, 0);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    /** Full screen: status and navigation bars hidden, a swipe from the edge shows them briefly. */
    private void hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        WindowInsetsControllerCompat c = WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        c.hide(WindowInsetsCompat.Type.systemBars());
        c.setSystemBarsBehavior(WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
    }

    /** photoframe://spotify?code=…&state=… comes back from the Spotify login; hand it to the page. */
    private void handleLink(Intent intent, long delay) {
        if (intent == null) return;
        Uri data = intent.getData();
        if (data == null || !"photoframe".equals(data.getScheme())) return;
        final String q = data.getEncodedQuery();
        if (q == null || getBridge() == null) return;
        getBridge().getWebView().postDelayed(() -> getBridge().getWebView().loadUrl(BASE + "?" + q), delay);
    }
}
