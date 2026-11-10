package dev.gbguest.host;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Foreground service that owns the guest init process tree and the
 *  gate socket (DESIGN-M1 host app section).
 *  - Starts/monitors/stops gbroot/init (ProcessBuilder, env GBROOT,
 *    GBVPID=1, GBGATE=1, cwd=gbroot, stdout+stderr appended to
 *    filesDir/logs/launcher.log).
 *  - Serves $GBROOT/dev/socket/gate as a real filesystem unix socket.
 *    The public Java SDK cannot create one (LocalServerSocket(String)
 *    is abstract-namespace only; StructSockaddrUn/Os.bind are @hide,
 *    proven by CI compile failures on runs 42758265048/42758537220),
 *    so the listener is a tiny POSIX helper (app/gate-helper/gated.c,
 *    NDK-built in CI, bundled as assets/gate/<abi>/gated) that this
 *    service extracts, execs, monitors and kills. M1 protocol: a line
 *    "PING" gets "PONG"; any other line is filed as a CONSOLE line
 *    into filesDir/logs/gate.log by the helper. In M1 the file
 *    channels (dev/console, dev/log/*) are the primary path; this
 *    socket is the in-place interface for later milestones. */
public class GateService extends Service {
    public static final String ACTION_START =
            "dev.gbguest.host.action.START";
    public static final String ACTION_STOP =
            "dev.gbguest.host.action.STOP";
    private static final String CHANNEL_ID = "gbguest-gate";
    private static final int NOTIF_ID = 1;

    private volatile boolean running;
    private volatile Process initProcess;
    private volatile Process gateProcess;
    private Thread monitorThread;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public void onCreate() {
        super.onCreate();
        HostLog.init(this);
    }

    @Override public int onStartCommand(Intent intent, int flags,
                                        int startId) {
        String action = intent == null ? null : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopGuest("stop requested from UI");
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }
        startForeground(NOTIF_ID, buildNotification());
        if (!running) {
            running = true;
            new Thread(this::startGuest, "gb-launcher").start();
        }
        return START_STICKY;
    }

    private void startGuest() {
        Context ctx = getApplicationContext();
        try {
            File gbroot = RootfsInstaller.ensureInstalled(ctx);
            writeStatus(ctx, "extracted, gbroot=" + gbroot);
            // Gate socket directory must exist and any stale socket
            // file from a previous run must be removed before bind.
            File sockDir = new File(gbroot, "dev/socket");
            //noinspection ResultOfMethodCallIgnored
            sockDir.mkdirs();
            File sockFile = new File(sockDir, "gate");
            //noinspection ResultOfMethodCallIgnored
            sockFile.delete();
            startGateServer(ctx, sockFile);

            File init = new File(gbroot, "init");
            if (!init.isFile()) {
                writeStatus(ctx, "ERROR: gbroot/init missing");
                HostLog.log(ctx, "guest start aborted: init missing");
                return;
            }
            init.setExecutable(true, false);
            File logsDir = new File(ctx.getFilesDir(), "logs");
            //noinspection ResultOfMethodCallIgnored
            logsDir.mkdirs();
            File launcherLog = new File(logsDir, "launcher.log");

            ProcessBuilder pb = new ProcessBuilder(init.getAbsolutePath());
            pb.directory(gbroot);
            pb.environment().put("GBROOT", gbroot.getAbsolutePath());
            pb.environment().put("GBVPID", "1");
            pb.environment().put("GBGATE", "1");
            // stdout+stderr combined, appended to launcher.log.
            pb.redirectErrorStream(true);
            pb.redirectOutput(ProcessBuilder.Redirect.appendTo(launcherLog));
            initProcess = pb.start();
            writeStatus(ctx, "running, init started, launcher log="
                    + launcherLog);
            HostLog.log(ctx, "guest init started");
            monitorThread = new Thread(() -> {
                int rc = -1;
                try { rc = initProcess.waitFor(); }
                catch (InterruptedException ignored) {}
                writeStatus(getApplicationContext(),
                        "init exited rc=" + rc + decodeRc(rc));
                HostLog.log(getApplicationContext(),
                        "guest init exited rc=" + rc + decodeRc(rc));
            }, "gb-monitor");
            monitorThread.start();
        } catch (Exception e) {
            writeStatus(ctx, "ERROR: " + e);
            HostLog.log(ctx, "guest start failed: " + e);
        }
    }

    /** Process.waitFor() reports a process killed by signal N as
     * 128+N. Decode the cases this line cares about so the log is
     * self-explanatory (159 = SIGSYS: the host seccomp filter denied
     * a guest syscall - the M1 first-run failure mode). */
    private static String decodeRc(int rc) {
        if (rc <= 128) return "";
        switch (rc - 128) {
            case 6:  return " (killed by SIGABRT)";
            case 9:  return " (killed by SIGKILL)";
            case 11: return " (killed by SIGSEGV)";
            case 31: return " (killed by SIGSYS: host seccomp denied a syscall)";
            default: return " (killed by signal " + (rc - 128) + ")";
        }
    }

    private void startGateServer(Context ctx, File sockFile) {
        try {
            File gated = extractGateHelper(ctx);
            File logsDir = new File(ctx.getFilesDir(), "logs");
            //noinspection ResultOfMethodCallIgnored
            logsDir.mkdirs();
            File gateLog = new File(logsDir, "gate.log");
            ProcessBuilder pb = new ProcessBuilder(
                    gated.getAbsolutePath(),
                    sockFile.getAbsolutePath(),
                    gateLog.getAbsolutePath());
            pb.redirectErrorStream(true);
            pb.redirectOutput(ProcessBuilder.Redirect.appendTo(
                    new File(logsDir, "gate-helper.log")));
            gateProcess = pb.start();
            HostLog.log(ctx, "gated helper started for "
                    + sockFile.getAbsolutePath());
            new Thread(() -> {
                int rc = -1;
                try { rc = gateProcess.waitFor(); }
                catch (InterruptedException ignored) {}
                if (running) {
                    HostLog.log(getApplicationContext(),
                            "gated helper exited rc=" + rc);
                    writeStatus(getApplicationContext(),
                            "gate helper exited rc=" + rc);
                }
            }, "gb-gated-monitor").start();
        } catch (Exception e) {
            HostLog.log(ctx, "gate helper start failed: " + e);
            writeStatus(ctx, "gate helper start failed: " + e);
        }
    }

    /** Extracts assets/gate/<abi>/gated to filesDir/gate/gated. */
    private File extractGateHelper(Context ctx) throws IOException {
        String abi = Build.SUPPORTED_ABIS.length > 0
                ? Build.SUPPORTED_ABIS[0] : "arm64-v8a";
        File dir = new File(ctx.getFilesDir(), "gate");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        File out = new File(dir, "gated");
        InputStream in = ctx.getAssets().open("gate/" + abi + "/gated");
        try {
            FileOutputStream fos = new FileOutputStream(out);
            try {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) fos.write(buf, 0, n);
            } finally { fos.close(); }
        } finally { in.close(); }
        out.setExecutable(true, false);
        return out;
    }

    private synchronized void stopGuest(String why) {
        if (!running && initProcess == null) return;
        running = false;
        Context ctx = getApplicationContext();
        HostLog.log(ctx, "stopping guest: " + why);
        writeStatus(ctx, "stopping: " + why);
        // Kill the gate helper first so no new guest lines arrive.
        Process gp = gateProcess;
        gateProcess = null;
        if (gp != null) gp.destroy();
        Process p = initProcess;
        initProcess = null;
        if (p != null) {
            p.destroy();
            // Best-effort tree cleanup: kill anything whose command
            // line references gbroot (guest services spawned by init
            // are separate processes the JVM does not track).
            try {
                File gbroot = RootfsInstaller.gbroot(ctx);
                new ProcessBuilder("sh", "-c",
                        "for pid in $(pgrep -f '"
                                + gbroot.getAbsolutePath() + "' 2>/dev/null);"
                                + " do kill -9 $pid 2>/dev/null; done")
                        .start();
            } catch (Exception ignored) {}
        }
        writeStatus(ctx, "stopped: " + why);
    }

    @Override public void onDestroy() {
        stopGuest("service destroyed");
        super.onDestroy();
    }

    static void writeStatus(Context ctx, String status) {
        try {
            File dir = new File(ctx.getFilesDir(), "logs");
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
            FileOutputStream fos =
                    new FileOutputStream(new File(dir, "status.txt"));
            try {
                fos.write(status.getBytes(StandardCharsets.UTF_8));
            } finally { fos.close(); }
        } catch (IOException ignored) {}
    }

    public static String readStatus(Context ctx) {
        try {
            File f = new File(new File(ctx.getFilesDir(), "logs"),
                    "status.txt");
            if (!f.isFile()) return "not started";
            java.io.FileInputStream in = new java.io.FileInputStream(f);
            try {
                byte[] buf = new byte[512];
                int n = in.read(buf);
                return n > 0 ? new String(buf, 0, n,
                        StandardCharsets.UTF_8).trim() : "unknown";
            } finally { in.close(); }
        } catch (IOException e) {
            return "unknown";
        }
    }

    private Notification buildNotification() {
        NotificationManager nm = (NotificationManager)
                getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm != null) {
            nm.createNotificationChannel(new NotificationChannel(
                    CHANNEL_ID, "GB guest gate",
                    NotificationManager.IMPORTANCE_LOW));
        }
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT
                        | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return b.setContentTitle("GB guest running")
                .setContentText("GateService keeps guest init alive")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentIntent(pi)
                .build();
    }
}
