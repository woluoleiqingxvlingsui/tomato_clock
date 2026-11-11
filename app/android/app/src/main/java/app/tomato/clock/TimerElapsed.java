package app.tomato.clock;

/** 与日历时间无关的通知计时；重启后保留已知时长，等待页面核对恢复。 */
final class TimerElapsed {
    private TimerElapsed() { }

    static long measure(long saved, long anchor, long now, boolean paused, boolean sameBoot) {
        if (paused || !sameBoot) return Math.max(0, saved);
        return Math.max(0, saved) + Math.max(0, now - anchor);
    }
}
