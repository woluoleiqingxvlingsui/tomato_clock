package app.tomato.clock;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;

import androidx.activity.result.ActivityResult;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * 备份 / 恢复的原生实现：把 JSON 交给系统文件选择器（SAF）保存或读取。
 *
 * 刻意用 SAF 而不是 MediaStore / 直接写外部存储：
 * ACTION_CREATE_DOCUMENT 与 ACTION_OPEN_DOCUMENT 都【不需要任何权限】，
 * 用户自己选保存位置（默认是「下载」），App 不碰真实的文件系统路径。
 * 这样「不声明多余权限」的原则依然成立。
 *
 * 网页预览（浏览器里）没有这个插件，JS 侧会自动退回 Blob 下载 / file input。
 */
@CapacitorPlugin(name = "DataTransfer")
public class DataTransferPlugin extends Plugin {

    /** 导出内容要跨一次 activity 往返，先存着，回调里再写盘 */
    private String pendingJson;

    /**
     * 导出：弹系统「保存到文件」对话框，用户选好位置后把 JSON 写进去。
     */
    @PluginMethod
    public void saveJson(PluginCall call) {
        String json = call.getString("json");
        if (json == null || json.isEmpty()) {
            call.reject("missing json");
            return;
        }
        String filename = call.getString("filename");
        pendingJson = json;

        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("application/json");
        intent.putExtra(Intent.EXTRA_TITLE, filename == null || filename.trim().isEmpty()
                ? "tomato-clock.json"
                : filename);
        startActivityForResult(call, intent, "exportResult");
    }

    @ActivityCallback
    private void exportResult(PluginCall call, ActivityResult result) {
        if (call == null) {
            pendingJson = null;
            return;
        }
        if (result.getResultCode() != Activity.RESULT_OK) {
            pendingJson = null;
            JSObject ret = new JSObject();
            ret.put("ok", false);
            ret.put("cancelled", true);
            call.resolve(ret);
            return;
        }
        Uri uri = result.getData() == null ? null : result.getData().getData();
        String json = pendingJson;
        pendingJson = null;
        if (uri == null || json == null) {
            JSObject ret = new JSObject();
            ret.put("ok", false);
            call.resolve(ret);
            return;
        }
        try (OutputStream os = getContext().getContentResolver().openOutputStream(uri)) {
            if (os == null) {
                JSObject ret = new JSObject();
                ret.put("ok", false);
                call.resolve(ret);
                return;
            }
            os.write(json.getBytes(StandardCharsets.UTF_8));
            os.flush();
            JSObject ret = new JSObject();
            ret.put("ok", true);
            call.resolve(ret);
        } catch (Exception e) {
            call.reject("write failed: " + e.getMessage());
        }
    }

    /**
     * 导入：弹系统「选择文件」对话框，用户选中后把文本读回来给 JS。
     */
    @PluginMethod
    public void pickJson(PluginCall call) {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        // 允许选到没有 .json 后缀、但内容确实是 JSON 的文件
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{
                "application/json", "text/plain", "application/octet-stream"
        });
        startActivityForResult(call, intent, "importResult");
    }

    @ActivityCallback
    private void importResult(PluginCall call, ActivityResult result) {
        if (call == null) {
            return;
        }
        if (result.getResultCode() != Activity.RESULT_OK) {
            JSObject ret = new JSObject();
            ret.put("cancelled", true);
            call.resolve(ret);
            return;
        }
        Uri uri = result.getData() == null ? null : result.getData().getData();
        if (uri == null) {
            JSObject ret = new JSObject();
            ret.put("cancelled", true);
            call.resolve(ret);
            return;
        }
        try (InputStream is = getContext().getContentResolver().openInputStream(uri)) {
            if (is == null) {
                call.reject("cannot open file");
                return;
            }
            // 不能用 readAllBytes()：那是 API 33+ 才有的方法，本项目 minSdk 23
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int n;
            while ((n = is.read(chunk)) > 0) {
                buf.write(chunk, 0, n);
            }
            String text = new String(buf.toByteArray(), StandardCharsets.UTF_8);
            JSObject ret = new JSObject();
            ret.put("json", text);
            call.resolve(ret);
        } catch (Exception e) {
            call.reject("read failed: " + e.getMessage());
        }
    }
}
