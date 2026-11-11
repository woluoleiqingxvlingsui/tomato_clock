package app.tomato.clock;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class TimerElapsedTest {
    @Test public void countsBackgroundAndSleepUsingElapsedRealtime() {
        assertEquals(3_660_000, TimerElapsed.measure(60_000, 500_000, 4_100_000, false, true));
    }
    @Test public void pauseDoesNotAccumulateTime() {
        assertEquals(60_000, TimerElapsed.measure(60_000, 500_000, 4_100_000, true, true));
    }
    @Test public void rebootCannotReuseOldUptimeEvenIfNewUptimeIsLarger() {
        assertEquals(60_000, TimerElapsed.measure(60_000, 500_000, 4_100_000, false, false));
    }
    @Test public void backwardsSampleDoesNotSubtractSavedFocus() {
        assertEquals(60_000, TimerElapsed.measure(60_000, 500_000, 100, false, true));
    }
}
