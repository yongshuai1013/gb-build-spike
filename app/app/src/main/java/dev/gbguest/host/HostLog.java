package dev.gbguest.host;

import android.content.Context;
import android.os.Environment;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** Host-side logger. Primary copy in filesDir/logs/host.log; a mirror
 *  is appended to Download/gbguest-host.log so logs are visible in a
 *  file manager even if the app dies (PaxVM-style file-first logs).
 *  Mirror failures are swallowed: internal log is the source of truth. */
public final class HostLog {
    private static volatile File internalLog;
    private static final SimpleDateFormat FMT =
            new SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US);

    private HostLog() {}

    public static synchronized void init(Context ctx) {
        if (internalLog != null) return;
        File dir = new File(ctx.getFilesDir(), "logs");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        internalLog = new File(dir, "host.log");
        log(ctx, "host log initialised");
    }

    public static synchronized void log(Context ctx, String msg) {
        String line = FMT.format(new Date()) + " " + msg + "\n";
        try {
            if (internalLog == null) init(ctx);
            append(internalLog, line);
        } catch (Exception ignored) {}
        try {
            File dl = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS);
            append(new File(dl, "gbguest-host.log"), line);
        } catch (Exception ignored) {}
    }

    private static void append(File f, String line) throws IOException {
        File parent = f.getParentFile();
        if (parent != null) parent.mkdirs();
        FileWriter w = new FileWriter(f, true);
        try { w.write(line); } finally { w.close(); }
    }
}
