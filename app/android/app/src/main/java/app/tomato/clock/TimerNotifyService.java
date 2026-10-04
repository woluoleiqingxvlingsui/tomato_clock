package app.tomato.clock;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.ServiceCompat;

/**
 * 专注计时前台服务：通知栏常驻计时卡（与番茄ToDo 同机制）。
 *
 * 走字交给 SystemUI：通知带 chronometer（base = 起算点），由系统侧每秒绘制，
 * 本进程被后台冻结甚至回收时通知栏照样走字；服务只负责事件驱动的发布/重发。
 * 60 秒心跳是保险丝：进程重建或 SystemUI 丢失后按时间戳重算自愈重发。
 * 不持 WakeLock：elapsed 永远由时间戳重算，不依赖 CPU 每秒醒来。
 *
 * 类型选 specialUse：targetSdk 35 下 dataSync 有 6 小时硬超时，specialUse 没有。
 * 状态写 SharedPreferences：服务被系统回收重建（START_STICKY 传回 null intent）
 * 时从偏好恢复，继续显示正确时间。
 */
public class TimerNotifyService extends Service {

    public static final String TAG = "TomatoTimer";
    public static final String ACTION_START = "app.tomato.clock.timer.START";
    public static final String ACTION_SYNC = "app.tomato.clock.timer.SYNC";
    public static final String EXTRA_TASK = "task";
    public static final String EXTRA_START_TS = "startTs";
    public static final String EXTRA_PAUSED_ACCUM = "pausedAccum";
    public static final String EXTRA_PAUSED_AT = "pausedAt"; // -1 = 运行中

    private static final String CHANNEL_ID = "tomato-timer-v2";
    private static final String LEGACY_CHANNEL_ID = "tomato-timer";
    private static final int NOTIF_ID = 0x5153;
    private static final long HEARTBEAT_MS = 60_000;
    private static final String PREFS = "tomato_timer_state";

    private final Handler handler = new Handler(Looper.getMainLooper());

    private String taskName = "专注";
    private long startTs;
    private long pausedAccum;
    private long pausedAt = -1;
    private boolean heartbeatScheduled = false;

    private final Runnable heartbeat = new Runnable() {
        @Override
        public void run() {
            heartbeatScheduled = false;
            updateNotification();
            scheduleHeartbeat();
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            // extras「有效才覆盖」：某字段解析失败/缺失时保持原值，绝不把计时归零
            String task = intent.getStringExtra(EXTRA_TASK);
            if (task != null && !task.trim().isEmpty()) {
                taskName = task;
            }
            long ts = intent.getLongExtra(EXTRA_START_TS, -1);
            if (ts > 0) {
                startTs = ts;
            }
            long acc = intent.getLongExtra(EXTRA_PAUSED_ACCUM, -1);
            if (acc >= 0) {
                pausedAccum = acc;
            }
            long pAt = intent.getLongExtra(EXTRA_PAUSED_AT, Long.MIN_VALUE);
            if (pAt >= -1) {
                pausedAt = pAt;
            }
            if (startTs <= 0) {
                startTs = System.currentTimeMillis(); // 首次 START 兜底
            }
            persistState();
        } else {
            // START_STICKY 被系统重建：从偏好恢复；没有有效会话就退场
            restoreState();
            if (startTs <= 0) {
                stopSelf();
                return START_NOT_STICKY;
            }
        }

        if (!startAsForeground()) {
            return START_NOT_STICKY;
        }
        restartHeartbeat();
        updateNotification();
        return START_STICKY;
    }

    /** 心跳不承担走字（chronometer 由系统侧绘制），只在进程重建或 SystemUI 丢失后按时间戳重算自愈重发 */
    private void restartHeartbeat() {
        cancelHeartbeat();
        scheduleHeartbeat();
    }

    private void scheduleHeartbeat() {
        if (heartbeatScheduled) {
            return;
        }
        heartbeatScheduled = true;
        handler.postDelayed(heartbeat, HEARTBEAT_MS);
    }

    private void cancelHeartbeat() {
        if (heartbeatScheduled) {
            handler.removeCallbacks(heartbeat);
            heartbeatScheduled = false;
        }
    }

    private boolean startAsForeground() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) {
            NotificationChannel ch = new NotificationChannel(
                CHANNEL_ID,
                getString(R.string.timer_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT // 锁屏/通知栏置顶展示；声音由下面关掉
            );
            ch.setSound(null, null);
            ch.setShowBadge(false);
            // 渠道级锁屏可见性：不显式设的话 HyperOS 可能按隐私内容处理，锁屏不给显示
            ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            nm.createNotificationChannel(ch);
            // v1.1 的渠道配置已固化（没设锁屏可见性），换新 ID 才能生效；顺手清理旧渠道
            nm.deleteNotificationChannel(LEGACY_CHANNEL_ID);
        }
        try {
            // ServiceCompat 内部完成 23→35 的版本分支（<29 不带 foregroundServiceType）
            ServiceCompat.startForeground(
                this,
                NOTIF_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            );
            return true;
        } catch (Exception e) {
            Log.w(TAG, "startForeground rejected", e);
            return false;
        }
    }

    private void updateNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) {
            return;
        }
        try {
            nm.notify(NOTIF_ID, buildNotification());
        } catch (Exception e) {
            Log.w(TAG, "notify failed", e);
        }
    }

    private Notification buildNotification() {
        boolean paused = pausedAt > 0;
        long now = paused ? pausedAt : System.currentTimeMillis();
        long elapsed = Math.max(0, now - startTs - pausedAccum);

        PendingIntent contentIntent = PendingIntent.getActivity(
            this,
            1,
            new Intent(this, MainActivity.class)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        NotificationCompat.Builder b = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_timer)
            .setContentTitle(taskName)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(contentIntent)
            .addAction(0, "查看", contentIntent);
        if (paused) {
            // chronometer 停不下来，暂停态换静态文案并隐藏时间位
            b.setContentText("已暂停 · " + fmtShort(elapsed)).setShowWhen(false);
        } else {
            // 走字在系统侧：chronometer 按 base 推算已专注时长，进程被后台冻结也照走
            b.setContentText("专注中")
                .setWhen(startTs + pausedAccum)
                .setUsesChronometer(true);
        }
        if (Build.VERSION.SDK_INT >= 31) {
            b.setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE);
        }
        return b.build();
    }

    /** 短格式：37:42 / 1:02:33（与番茄ToDo 卡片一致） */
    private static String fmtShort(long ms) {
        long s = ms / 1000;
        long h = s / 3600;
        long m = (s % 3600) / 60;
        long sec = s % 60;
        if (h > 0) {
            return h + ":" + two(m) + ":" + two(sec);
        }
        return m + ":" + two(sec);
    }

    private static String two(long v) {
        return v < 10 ? "0" + v : String.valueOf(v);
    }

    private void persistState() {
        SharedPreferences sp = getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        sp.edit()
            .putString("task", taskName)
            .putLong("startTs", startTs)
            .putLong("pausedAccum", pausedAccum)
            .putLong("pausedAt", pausedAt)
            .apply();
    }

    private void restoreState() {
        SharedPreferences sp = getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        taskName = sp.getString("task", "专注");
        startTs = sp.getLong("startTs", 0);
        pausedAccum = sp.getLong("pausedAccum", 0);
        pausedAt = sp.getLong("pausedAt", -1);
    }

    /** specialUse 理论上不触发系统超时，但国产 ROM 魔改行为不可预测，一行代码买保险 */
    @Override
    public void onTimeout(int startId, int fgsType) {
        Log.w(TAG, "onTimeout fgsType=" + fgsType + ", stopping");
        stopSelf();
    }

    @Override
    public void onDestroy() {
        cancelHeartbeat();
        super.onDestroy();
    }
}
