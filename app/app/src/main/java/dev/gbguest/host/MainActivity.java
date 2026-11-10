package dev.gbguest.host;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.Button;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** Single-activity host shell (DESIGN-M1): status line, start/stop,
 *  live log tail, export. All guest lifecycle work lives in
 *  GateService; this activity only sends it intents and renders the
 *  log files the guest/launcher/gate produce. */
public class MainActivity extends Activity {
    private TextView statusView;
    private TextView logView;
    private ScrollView logScroll;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable refresher = new Runnable() {
        @Override public void run() {
            refresh();
            ui.postDelayed(this, 1000);
        }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        HostLog.init(this);
        statusView = findViewById(R.id.status);
        logView = findViewById(R.id.log);
        logScroll = findViewById(R.id.log_scroll);
        Button startBtn = findViewById(R.id.btn_start);
        Button stopBtn = findViewById(R.id.btn_stop);
        Button exportBtn = findViewById(R.id.btn_export);
        startBtn.setOnClickListener(v -> startGuest());
        stopBtn.setOnClickListener(v -> stopGuest());
        exportBtn.setOnClickListener(v -> exportLogs());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                && checkSelfPermission(
                        Manifest.permission.WRITE_EXTERNAL_STORAGE)
                        != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{
                    Manifest.permission.WRITE_EXTERNAL_STORAGE}, 7);
        }
    }

    @Override protected void onResume() {
        super.onResume();
        ui.post(refresher);
    }

    @Override protected void onPause() {
        ui.removeCallbacks(refresher);
        super.onPause();
    }

    private void startGuest() {
        HostLog.log(this, "UI: start pressed");
        Intent i = new Intent(this, GateService.class);
        i.setAction(GateService.ACTION_START);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(i);
        } else {
            startService(i);
        }
    }

    private void stopGuest() {
        HostLog.log(this, "UI: stop pressed");
        Intent i = new Intent(this, GateService.class);
        i.setAction(GateService.ACTION_STOP);
        startService(i);
    }

    // ---- live log tail ----
    private void refresh() {
        statusView.setText("GateService: " + GateService.readStatus(this));
        StringBuilder sb = new StringBuilder();
        File gbroot = RootfsInstaller.gbroot(this);
        appendTail(sb, "== dev/console ==", new File(gbroot, "dev/console"));
        File logDir = new File(gbroot, "dev/log");
        File[] guestLogs = logDir.listFiles();
        if (guestLogs != null) {
            java.util.Arrays.sort(guestLogs);
            for (File f : guestLogs) {
                if (f.isFile()) {
                    appendTail(sb, "== dev/log/" + f.getName() + " ==", f);
                }
            }
        }
        File logs = new File(getFilesDir(), "logs");
        appendTail(sb, "== launcher.log ==", new File(logs, "launcher.log"));
        appendTail(sb, "== gate.log ==", new File(logs, "gate.log"));
        appendTail(sb, "== host.log ==", new File(logs, "host.log"));
        logView.setText(sb.toString());
        logScroll.post(() -> logScroll.fullScroll(View.FOCUS_DOWN));
    }

    private void appendTail(StringBuilder sb, String title, File f) {
        sb.append(title).append('\n');
        sb.append(tail(f, 8192)).append('\n');
    }

    private static String tail(File f, int maxBytes) {
        if (!f.isFile()) return "(missing)";
        try {
            long len = f.length();
            FileInputStream in = new FileInputStream(f);
            try {
                if (len > maxBytes) in.skip(len - maxBytes);
                byte[] buf = new byte[(int) Math.min(len, maxBytes)];
                int off = 0, n;
                while (off < buf.length
                        && (n = in.read(buf, off, buf.length - off)) > 0) {
                    off += n;
                }
                return new String(buf, 0, off, "UTF-8");
            } finally { in.close(); }
        } catch (IOException e) {
            return "(unreadable: " + e + ")";
        }
    }

    // ---- export: zip logs + key rootfs files to Download, share ----
    private void exportLogs() {
        HostLog.log(this, "UI: export pressed");
        new Thread(() -> {
            try {
                File zip = buildExportZip();
                HostLog.log(this, "export zip written: " + zip);
                shareZip(zip);
            } catch (Exception e) {
                HostLog.log(this, "export failed: " + e);
            }
        }, "gb-export").start();
    }

    private File buildExportZip() throws IOException {
        String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss",
                Locale.US).format(new Date());
        File dl = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS);
        //noinspection ResultOfMethodCallIgnored
        dl.mkdirs();
        File zip = new File(dl, "gbguest-logs-" + stamp + ".zip");
        List<File> files = new ArrayList<>();
        File logs = new File(getFilesDir(), "logs");
        addIfFile(files, new File(logs, "launcher.log"));
        addIfFile(files, new File(logs, "gate.log"));
        addIfFile(files, new File(logs, "host.log"));
        addIfFile(files, new File(logs, "status.txt"));
        File gbroot = RootfsInstaller.gbroot(this);
        addIfFile(files, new File(gbroot, "dev/console"));
        addIfFile(files, new File(gbroot, ".asset-sha256"));
        File guestLogDir = new File(gbroot, "dev/log");
        File[] gl = guestLogDir.listFiles();
        if (gl != null) for (File f : gl) addIfFile(files, f);
        ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(zip));
        try {
            for (File f : files) {
                String name = f.getAbsolutePath()
                        .substring(getFilesDir().getAbsolutePath().length() + 1);
                zos.putNextEntry(new ZipEntry(name));
                FileInputStream in = new FileInputStream(f);
                try {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) > 0) zos.write(buf, 0, n);
                } finally { in.close(); }
                zos.closeEntry();
            }
        } finally { zos.close(); }
        return zip;
    }

    private static void addIfFile(List<File> list, File f) {
        if (f != null && f.isFile()) list.add(f);
    }

    private void shareZip(File zip) {
        Uri uri = FileProvider.getUriForFile(this,
                getPackageName() + ".fileprovider", zip);
        Intent share = new Intent(Intent.ACTION_SEND);
        share.setType("application/zip");
        share.putExtra(Intent.EXTRA_STREAM, uri);
        share.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        Intent chooser = Intent.createChooser(share, "Share GB guest logs");
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(chooser);
    }
}
