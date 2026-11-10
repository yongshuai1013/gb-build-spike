package dev.gbguest.host;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Build;
import android.os.IBinder;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructSockaddrUn;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/** Foreground service that owns the guest init process tree and the
 *  gate socket (DESIGN-M1 host app section).
 *  - Starts/monitors/stops gbroot/init (ProcessBuilder, env GBROOT,
 *    GBVPID=1, GBGATE=1, cwd=gbroot, stdout+stderr appended to
 *    filesDir/logs/launcher.log).
 *  - Serves $GBROOT/dev/socket/gate as a filesystem LocalServerSocket.
 *    M1 protocol: a line "PING" gets "PONG"; any other line is filed
 *    as a CONSOLE line into filesDir/logs/gate.log. In M1 the file
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
    private volatile LocalServerSocket gateSocket;
    private Thread acceptThread;
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
                        "init exited rc=" + rc);
                HostLog.log(getApplicationContext(),
                        "guest init exited rc=" + rc);
            }, "gb-monitor");
            monitorThread.start();
        } catch (Exception e) {
            writeStatus(ctx, "ERROR: " + e);
            HostLog.log(ctx, "guest start failed: " + e);
        }
    }

    private void startGateServer(Context ctx, File sockFile) {
        try {
            // LocalServerSocket(String) only opens the ABSTRACT
            // namespace; the guest connects to a real filesystem path
            // ($GBROOT/dev/socket/gate), so bind a filesystem
            // sockaddr_un via android.system.Os (public since API 26)
            // and wrap the listening fd in a LocalServerSocket.
            java.io.FileDescriptor fd = Os.socket(
                    OsConstants.AF_UNIX, OsConstants.SOCK_STREAM, 0);
            Os.bind(fd, new StructSockaddrUn(
                    sockFile.getAbsolutePath()));
            Os.listen(fd, 50);
            LocalServerSocket server = new LocalServerSocket(fd);
            gateSocket = server;
            HostLog.log(ctx, "gate socket listening at "
                    + sockFile.getAbsolutePath());
            acceptThread = new Thread(() -> {
                while (running && gateSocket != null) {
                    try {
                        LocalSocket client = gateSocket.accept();
                        new Thread(() -> handleGateClient(ctx, client),
                                "gb-gate-client").start();
                    } catch (IOException e) {
                        if (running) HostLog.log(ctx,
                                "gate accept failed: " + e);
                        return;
                    }
                }
            }, "gb-gate-accept");
            acceptThread.start();
        } catch (Exception e) {
            HostLog.log(ctx, "gate socket bind failed: " + e);
            writeStatus(ctx, "gate socket bind failed: " + e);
        }
    }

    private void handleGateClient(Context ctx, LocalSocket client) {
        try {
            BufferedReader in = new BufferedReader(new InputStreamReader(
                    client.getInputStream(), StandardCharsets.UTF_8));
            OutputStream out = client.getOutputStream();
            String line;
            while ((line = in.readLine()) != null) {
                if ("PING".equals(line.trim())) {
                    out.write("PONG\n".getBytes(StandardCharsets.UTF_8));
                    out.flush();
                } else {
                    // Any other line is filed as a CONSOLE line.
                    appendGateLog(ctx, "CONSOLE " + line);
                }
            }
        } catch (IOException e) {
            HostLog.log(ctx, "gate client error: " + e);
        } finally {
            try { client.close(); } catch (IOException ignored) {}
        }
    }

    private void appendGateLog(Context ctx, String line) {
        try {
            File dir = new File(ctx.getFilesDir(), "logs");
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
            FileOutputStream fos =
                    new FileOutputStream(new File(dir, "gate.log"), true);
            try {
                fos.write((line + "\n").getBytes(StandardCharsets.UTF_8));
            } finally { fos.close(); }
        } catch (IOException ignored) {}
    }

    private synchronized void stopGuest(String why) {
        if (!running && initProcess == null) return;
        running = false;
        Context ctx = getApplicationContext();
        HostLog.log(ctx, "stopping guest: " + why);
        writeStatus(ctx, "stopping: " + why);
        // Close the gate socket first so the accept loop ends.
        try { if (gateSocket != null) gateSocket.close(); }
        catch (IOException ignored) {}
        gateSocket = null;
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
