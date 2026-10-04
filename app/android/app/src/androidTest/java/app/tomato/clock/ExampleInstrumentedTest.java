package app.tomato.clock;

import static org.junit.Assert.*;

import android.content.Context;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;

/**
 * Instrumented test, which will execute on an Android device.
 *
 * @see <a href="http://d.android.com/tools/testing">Testing documentation</a>
 */
@RunWith(AndroidJUnit4.class)
public class ExampleInstrumentedTest {

    @Test
    public void useAppContext() throws Exception {
        // Context of the app under test.
        Context appContext = InstrumentationRegistry.getInstrumentation().getTargetContext();

        // 必须与 build.gradle 的 applicationId / capacitor.config.json 的 appId 一致，
        // 否则 connectedAndroidTest 必红（模板里原本写的是 com.getcapacitor.app）
        assertEquals("app.tomato.clock", appContext.getPackageName());
    }
}
