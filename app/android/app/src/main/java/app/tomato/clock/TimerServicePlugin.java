package app.tomato.clock;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Log;

import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * 暴露给 JS 的锁屏/通知栏计时卡开关（window.Capacitor.Plugins.TimerService）。
 *
 * start：开始专注时调用（携带事项与时间戳）；sync：暂停/恢复/页面恢复时同步状态；
 * stop：结束时调用。电脑浏览器里 JS 侧判定非原生平台根本不会调用。
 *
 * POST_NOTIFICATIONS 只影响那条常驻通知可不可见，不影响服务能否运行——
 * 未授权时 startForeground 照样成功。所以 fire-and-forget，不阻塞、不关心结果。
 */
@CapacitorPlugin(name = "TimerService")
public class TimerServicePlugin extends Plugin {

    private static final int NOTIF_PERMISSION_REQUEST_CODE = 0x5154;

    @PluginMethod
    public void start(PluginCall call) {
        ensureNotificationPermission();
        if (dispatch(call, TimerNotifyService.ACTION_START)) {
            JSObject ret = new JSObject();
            ret.put("ok", true);
            call.resolve(ret);
        } else {
            call.resolve();
        }
    }

    @PluginMethod
    public void sync(PluginCall call) {
        dispatch(call, TimerNotifyService.ACTION_SYNC);
        call.resolve();
    }

    @PluginMethod
    public void stop(PluginCall call) {
        try {
            getContext().stopService(new Intent(getContext(), TimerNotifyService.class));
        } catch (Exception e) {
            Log.w(TimerNotifyService.TAG, "stop failed", e);
        }
        call.resolve();
    }

    /** @return true 表示 startForegroundService 已成功投递 */
    private boolean dispatch(PluginCall call, String action) {
        Intent i = new Intent(getContext(), TimerNotifyService.class).setAction(action);
        String task = call.getString("taskName");
        i.putExtra(TimerNotifyService.EXTRA_TASK,
            task == null || task.trim().isEmpty() ? "专注" : task);
        // 数值一律走字符串传桥：Capacitor 的 getDouble 对大整数（org.json 解析为 Long）返回 null，
        // 曾导致暂停/继续时服务拿到默认值，把通知计时归零
        putLongExtra(i, TimerNotifyService.EXTRA_START_TS, call.getString("startTs"));
        putLongExtra(i, TimerNotifyService.EXTRA_PAUSED_ACCUM, call.getString("pausedAccumMs"));
        putLongExtra(i, TimerNotifyService.EXTRA_PAUSED_AT, call.getString("pausedAt"));
        try {
            ContextCompat.startForegroundService(getContext(), i);
            return true;
        } catch (Exception e) {
            // 通知/服务被系统拒绝（如后台启动限制）不影响 App 内计时，静默即可
            Log.w(TimerNotifyService.TAG, action + " rejected", e);
            return false;
        }
    }

    private void putLongExtra(Intent i, String key, String raw) {
        if (raw == null || raw.trim().isEmpty()) {
            return;
        }
        try {
            i.putExtra(key, Long.parseLong(raw.trim()));
        } catch (NumberFormatException ignored) {
            // 解析失败不投递该字段，服务端保持原状态
        }
    }

    private void ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) {
            return;
        }
        AppCompatActivity activity = getActivity();
        if (activity == null) {
            return;
        }
        if (ActivityCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED) {
            return;
        }
        try {
            ActivityCompat.requestPermissions(
                activity,
                new String[] { Manifest.permission.POST_NOTIFICATIONS },
                NOTIF_PERMISSION_REQUEST_CODE
            );
        } catch (Exception e) {
            Log.w(TimerNotifyService.TAG, "notification permission request failed", e);
        }
    }
}
