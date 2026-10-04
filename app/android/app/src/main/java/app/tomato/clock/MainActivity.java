package app.tomato.clock;

import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;

import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // 必须在 super.onCreate 之前：registerPlugin 只是往 bridgeBuilder 里登记，
        // 实例化发生在 super.onCreate 末尾的 load() 里
        registerPlugin(TimerServicePlugin.class);
        super.onCreate(savedInstanceState);
        installInsetsListener();
    }

    /**
     * edge-to-edge 下接管 WebView 的 insets（覆盖 CapacitorWebView.edgeToEdgeHandler 装的那个）：
     * 系统栏边距逻辑与 Capacitor 内置一致；另把键盘 inset 合入底边距——
     * Capacitor 内置监听只认系统栏，还把键盘 insets 一并 CONSUME 掉，
     * 输入法弹出时 WebView 完全不让位，底部弹层会被键盘盖住。
     */
    private void installInsetsListener() {
        android.webkit.WebView webView = getBridge().getWebView();
        if (webView == null) {
            return;
        }
        ViewCompat.setOnApplyWindowInsetsListener(webView, (v, windowInsets) -> {
            Insets bars = windowInsets.getInsets(
                WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout());
            Insets ime = windowInsets.getInsets(WindowInsetsCompat.Type.ime());
            ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) v.getLayoutParams();
            mlp.leftMargin = bars.left;
            mlp.rightMargin = bars.right;
            mlp.topMargin = bars.top;
            mlp.bottomMargin = Math.max(bars.bottom, ime.bottom);
            v.setLayoutParams(mlp);
            return WindowInsetsCompat.CONSUMED;
        });
    }
}
