package app.tomato.clock;

import android.content.Context;
import android.os.SystemClock;
import android.provider.Settings;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.util.UUID;

/** 不需权限或联网；elapsedRealtime 包含深度休眠且不受日历校时影响。 */
@CapacitorPlugin(name = "FocusClock")
public class ClockPlugin extends Plugin {
    // API 23 或 ROM 不提供 boot_count 时，只信任本次进程生命周期。
    private static final String PROCESS_EPOCH = "process:" + UUID.randomUUID();

    static String epoch(Context context) {
        try {
            String boot = Settings.Global.getString(context.getContentResolver(), "boot_count");
            if (boot != null && !boot.isEmpty()) return "boot:" + boot;
        } catch (Exception ignored) { }
        return PROCESS_EPOCH;
    }

    @PluginMethod
    public void sample(PluginCall call) {
        JSObject out = new JSObject();
        out.put("monoMs", (double) SystemClock.elapsedRealtime());
        out.put("wallMs", (double) System.currentTimeMillis());
        out.put("epoch", epoch(getContext()));
        call.resolve(out);
    }
}
