package app.tomato.clock;

import android.Manifest;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

import androidx.core.content.ContextCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

/**
 * 暴露给 JS 的锁屏/通知栏计时卡开关（window.Capacitor.Plugins.TimerService）。
 *
 * start：开始专注时调用（携带事项与时间戳）；sync：暂停/恢复/页面恢复时同步状态；
 * stop：结束时调用。电脑浏览器里 JS 侧判定非原生平台根本不会调用。
 *
 * POST_NOTIFICATIONS 只影响那条常驻通知可不可见，不影响服务能否运行——
 * 未授权时 startForeground 照样成功。Android 13+ 首次 start 会顺带申请权限，
 * 授权/拒绝后都补发一次通知；JS 侧不等这个结果。
 */
@CapacitorPlugin(
    name = "TimerService",
    permissions = @Permission(
        alias = "notifications",
        strings = { Manifest.permission.POST_NOTIFICATIONS }
    )
)
public class TimerServicePlugin extends Plugin {

    private static final String NOTIF_ALIAS = "notifications";

    @PluginMethod
    public void start(PluginCall call) {
        boolean dispatched = dispatch(call, TimerNotifyService.ACTION_START);
        // Android 13+ 首次开始专注才申请通知权限；授权后立刻补发一次通知，
        // 否则要等最多 60 秒的心跳，用户会以为通知卡坏了。
        if (Build.VERSION.SDK_INT >= 33
            && getPermissionState(NOTIF_ALIAS) != PermissionState.GRANTED) {
            requestPermissionForAlias(NOTIF_ALIAS, call, "notificationPermissionCallback");
            return;
        }
        resolveStart(call, dispatched);
    }

    @PermissionCallback
    private void notificationPermissionCallback(PluginCall call) {
        // 无论允许还是拒绝都重发一次：允许时通知立刻可见，拒绝时也不会留下半启动状态
        resyncNotification();
        resolveStart(call, true);
    }

    private void resolveStart(PluginCall call, boolean ok) {
        if (call == null) {
            return;
        }
        JSObject ret = new JSObject();
        ret.put("ok", ok);
        call.resolve(ret);
    }

    private void resyncNotification() {
        Intent i = new Intent(getContext(), TimerNotifyService.class)
            .setAction(TimerNotifyService.ACTION_SYNC);
        try {
            ContextCompat.startForegroundService(getContext(), i);
        } catch (Exception e) {
            Log.w(TimerNotifyService.TAG, "resync rejected", e);
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
            // 先清恢复状态再停服务：否则 START_STICKY 的 null-intent 重建可能复活旧计时
            TimerNotifyService.clearSavedState(getContext());
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

}
