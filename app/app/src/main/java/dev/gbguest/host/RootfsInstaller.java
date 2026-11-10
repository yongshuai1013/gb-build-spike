package dev.gbguest.host;

import android.content.Context;
import android.system.Os;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.zip.GZIPInputStream;

/** Extracts assets/rootfs.tar.gz into filesDir/gbroot.
 *  Re-extracts only when the asset changed: the SHA-256 of the asset
 *  is stored in gbroot/.asset-sha256 after a successful extract and
 *  compared on every start (DESIGN-M1: version-stamp comparison;
 *  a content hash is the stamp, so swapping in the real gb-rootfs
 *  artifact in CI automatically triggers a fresh extract). */
public final class RootfsInstaller {
    public static final String ASSET_NAME = "rootfs.tar.gz";

    private RootfsInstaller() {}

    public static File gbroot(Context ctx) {
        return new File(ctx.getFilesDir(), "gbroot");
    }

    public static synchronized File ensureInstalled(Context ctx)
            throws IOException {
        File root = gbroot(ctx);
        String want = assetSha256(ctx);
        File stamp = new File(root, ".asset-sha256");
        if (root.isDirectory() && stamp.isFile()
                && want.equals(readSmall(stamp))) {
            HostLog.log(ctx, "rootfs up to date, sha256=" + want);
            return root;
        }
        HostLog.log(ctx, "extracting rootfs, sha256=" + want);
        deleteRecursive(root);
        //noinspection ResultOfMethodCallIgnored
        root.mkdirs();
        InputStream raw = ctx.getAssets().open(ASSET_NAME);
        try {
            extractTarGz(new BufferedInputStream(raw), root);
        } finally {
            raw.close();
        }
        writeSmall(stamp, want);
        // Skeleton the launcher/gate rely on even for a real rootfs.
        mkdirs(new File(root, "dev/log"));
        mkdirs(new File(root, "dev/socket"));
        mkdirs(new File(root, "data"));
        touch(new File(root, "dev/console"));
        File init = new File(root, "init");
        if (init.isFile()) init.setExecutable(true, false);
        HostLog.log(ctx, "rootfs extracted to " + root);
        return root;
    }

    // ---- minimal ustar extractor (no external deps) ----
    private static void extractTarGz(InputStream in, File destDir)
            throws IOException {
        GZIPInputStream gz = new GZIPInputStream(in);
        byte[] header = new byte[512];
        String longName = null;
        while (true) {
            if (!readFully(gz, header)) return;
            if (isZeroBlock(header)) {
                // Two zero blocks end the archive; one is enough here.
                return;
            }
            String name = cstr(header, 0, 100);
            long size = parseOctal(header, 124, 12);
            int type = header[156];
            String prefix = cstr(header, 345, 155);
            if (!prefix.isEmpty()) name = prefix + "/" + name;
            if (type == 'L') { // GNU long name for the next entry
                byte[] buf = new byte[(int) size];
                readFully(gz, buf);
                skipPadding(gz, size);
                longName = new String(buf, "UTF-8").trim();
                continue;
            }
            if (longName != null) { name = longName; longName = null; }
            File out = new File(destDir, name);
            if (!out.getCanonicalPath().startsWith(
                    destDir.getCanonicalPath())) {
                throw new IOException("tar entry escapes dest: " + name);
            }
            int mode = (int) parseOctal(header, 100, 8);
            if (type == '5' || name.endsWith("/")) {
                mkdirs(out);
                skip(gz, size); skipPadding(gz, size);
            } else if (type == '2') { // symlink
                byte[] buf = new byte[(int) size];
                readFully(gz, buf); skipPadding(gz, size);
                String target = cstr(header, 157, 100);
                mkdirs(out.getParentFile());
                //noinspection ResultOfMethodCallIgnored
                out.delete();
                try { Os.symlink(target, out.getAbsolutePath()); }
                catch (Exception ignored) {
                    // Symlink unsupported/failed: file-based channels
                    // (console/log) do not depend on it; keep going.
                }
            } else { // regular file ('0', '1' hardlink treated as copy-less skip is wrong; treat '1' like '0' with empty body is not possible, so regular path)
                mkdirs(out.getParentFile());
                FileOutputStream fos = new FileOutputStream(out);
                try {
                    long left = size;
                    byte[] buf = new byte[8192];
                    while (left > 0) {
                        int n = gz.read(buf, 0,
                                (int) Math.min(buf.length, left));
                        if (n < 0) throw new IOException("EOF in tar");
                        fos.write(buf, 0, n);
                        left -= n;
                    }
                } finally { fos.close(); }
                skipPadding(gz, size);
                if ((mode & 0111) != 0) out.setExecutable(true, false);
                if ((mode & 0200) != 0) out.setWritable(true, false);
            }
        }
    }

    private static boolean readFully(InputStream in, byte[] buf)
            throws IOException {
        int off = 0;
        while (off < buf.length) {
            int n = in.read(buf, off, buf.length - off);
            if (n < 0) return off > 0;
            off += n;
        }
        return true;
    }

    private static boolean isZeroBlock(byte[] b) {
        for (byte v : b) if (v != 0) return false;
        return true;
    }

    private static String cstr(byte[] b, int off, int len) {
        int end = off;
        while (end < off + len && b[end] != 0) end++;
        try { return new String(b, off, end - off, "UTF-8").trim(); }
        catch (Exception e) { return ""; }
    }

    private static long parseOctal(byte[] b, int off, int len) {
        String s = cstr(b, off, len).trim();
        if (s.isEmpty()) return 0;
        try { return Long.parseLong(s, 8); }
        catch (NumberFormatException e) { return 0; }
    }

    private static void skip(InputStream in, long n) throws IOException {
        long left = n;
        byte[] buf = new byte[8192];
        while (left > 0) {
            int r = in.read(buf, 0, (int) Math.min(buf.length, left));
            if (r < 0) throw new IOException("EOF skipping tar data");
            left -= r;
        }
    }

    private static void skipPadding(InputStream in, long size)
            throws IOException {
        long pad = (512 - (size % 512)) % 512;
        if (pad > 0) skip(in, pad);
    }

    private static String assetSha256(Context ctx) throws IOException {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            InputStream in = ctx.getAssets().open(ASSET_NAME);
            try {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            } finally { in.close(); }
            StringBuilder sb = new StringBuilder();
            for (byte b : md.digest()) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("SHA-256 unavailable", e);
        }
    }

    private static String readSmall(File f) throws IOException {
        FileInputStream in = new FileInputStream(f);
        try {
            byte[] buf = new byte[256];
            int n = in.read(buf);
            return n > 0 ? new String(buf, 0, n, "UTF-8").trim() : "";
        } finally { in.close(); }
    }

    private static void writeSmall(File f, String s) throws IOException {
        FileOutputStream out = new FileOutputStream(f);
        try { out.write(s.getBytes("UTF-8")); } finally { out.close(); }
    }

    private static void mkdirs(File f) {
        if (f != null) f.mkdirs();
    }

    private static void touch(File f) throws IOException {
        mkdirs(f.getParentFile());
        if (!f.exists()) new FileOutputStream(f).close();
    }

    private static void deleteRecursive(File f) {
        if (f == null || !f.exists()) return;
        if (f.isDirectory() && !isSymlink(f)) {
            File[] kids = f.listFiles();
            if (kids != null) for (File k : kids) deleteRecursive(k);
        }
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }

    private static boolean isSymlink(File f) {
        try {
            String canon = f.getCanonicalPath();
            return !canon.equals(f.getAbsolutePath())
                    && new File(canon).exists()
                    && android.system.Os.lstat(f.getAbsolutePath()) != null
                    && (android.system.Os.lstat(f.getAbsolutePath()).st_mode
                        & 0170000) == 0120000;
        } catch (Exception e) {
            return false;
        }
    }
}
