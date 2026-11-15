package org.los.tv.addon;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * los-tv: фоновая загрузка образов для плитки «Проприетарные компоненты».
 *
 * Загрузка вынесена в foreground-сервис: если пользователь свернёт приложение
 * и откроет YouTube, система не убьёт процесс, а по завершении придёт
 * уведомление «Образы скачаны — откройте плитку и нажмите Установить».
 *
 * Прогресс доступен активности через статические поля (она опрашивает их
 * раз в секунду, пока видима).
 */
public class DownloadService extends Service {

    static volatile boolean running = false;
    static volatile boolean finished = false;
    static volatile String statusText = null;
    static volatile String errorText = null;
    static volatile boolean cancelRequested = false;

    private static final String CHANNEL_ID = "los-tv-addon-download";
    private static final int PROGRESS_ID = 1001;
    private static final int DONE_ID = 1002;

    private static final File ADDON_DIR = new File("/sdcard/los-tv-proprietary");
    private static final File CONFIG_FILE = new File("/system/etc/los-tv-addon/links.txt");

    private Thread worker;

    static class Entry {
        String id;
        String title;
        String url;
        String sha256;
        long size;

        File localFile() {
            return new File(ADDON_DIR, fileNameFromUrl(url));
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (running) {
            return START_NOT_STICKY;
        }
        running = true;
        finished = false;
        errorText = null;
        cancelRequested = false;
        statusText = getString(R.string.download_starting);

        createChannel();
        startForeground(PROGRESS_ID, progressNotification(statusText));

        worker = new Thread(this::runDownloads, "los-tv-download");
        worker.start();
        return START_NOT_STICKY;
    }

    private void runDownloads() {
        try {
            List<Entry> entries = loadDownloads();
            for (Entry e : entries) {
                if (cancelRequested) break;
                File f = e.localFile();
                if (f.exists() && e.size > 0 && f.length() == e.size) {
                    statusText = getString(R.string.download_present, e.title);
                    updateProgress(statusText);
                    continue;
                }
                downloadOne(e, f);
            }
            if (cancelRequested) {
                statusText = getString(R.string.download_cancelled);
            } else {
                finished = true;
                statusText = getString(R.string.download_done);
                postDoneNotification();
            }
        } catch (Exception ex) {
            String msg = ex.getMessage() == null ? ex.toString() : ex.getMessage();
            errorText = msg;
            statusText = getString(R.string.download_error, msg);
        } finally {
            running = false;
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
        }
    }

    private void downloadOne(Entry e, File dest) throws Exception {
        ADDON_DIR.mkdirs();
        long existing = dest.exists() ? dest.length() : 0;
        if (e.size > 0 && existing > e.size) {
            dest.delete();
            existing = 0;
        }

        String begin = getString(R.string.download_begin, e.title, mb(existing), mb(e.size));
        statusText = begin;
        updateProgress(begin);

        HttpURLConnection c = (HttpURLConnection) new URL(e.url).openConnection();
        c.setConnectTimeout(30000);
        c.setReadTimeout(60000);
        c.setInstanceFollowRedirects(true);
        c.setRequestProperty("User-Agent", "los-tv-addon/1.0");
        if (existing > 0) c.setRequestProperty("Range", "bytes=" + existing + "-");

        int code = c.getResponseCode();
        if (code == 416) {
            // Уже скачано полностью — проверим хэш ниже.
        } else {
            if (code == 200 && existing > 0) {
                existing = 0; // сервер не поддержал Range
            } else if (code != 200 && code != 206) {
                throw new IOException("HTTP " + code);
            }

            long total = e.size > 0 ? e.size : existing + c.getContentLength();
            try (InputStream in = c.getInputStream();
                 RandomAccessFile raf = new RandomAccessFile(dest, "rw")) {
                raf.seek(existing);
                byte[] buf = new byte[256 * 1024];
                long done = existing;
                long lastReport = 0;
                int n;
                while (!cancelRequested && (n = in.read(buf)) > 0) {
                    raf.write(buf, 0, n);
                    done += n;
                    if (done - lastReport >= 4L * 1024 * 1024) {
                        String s = getString(R.string.download_progress,
                                e.title, mb(done), mb(total), pct(done, total));
                        statusText = s;
                        updateProgress(s);
                        lastReport = done;
                    }
                }
                raf.getFD().sync();
            }
        }
        c.disconnect();

        if (cancelRequested) return;

        if (e.size > 0 && dest.length() != e.size) {
            throw new IOException("размер не совпал: " + dest.length() + " != " + e.size);
        }
        if (e.sha256 != null && !e.sha256.isEmpty()) {
            String verify = getString(R.string.download_verify, e.title);
            statusText = verify;
            updateProgress(verify);
            String actual = sha256(dest);
            if (!e.sha256.equalsIgnoreCase(actual)) {
                throw new IOException("sha256 не совпал: " + actual);
            }
        }
        statusText = getString(R.string.download_ok, e.title);
        updateProgress(statusText);
    }

    private void updateProgress(String text) {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) {
            nm.notify(PROGRESS_ID, progressNotification(text));
        }
    }

    private Notification progressNotification(String text) {
        return new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(getString(R.string.download_notify_title))
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    private void postDoneNotification() {
        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification n = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(getString(R.string.download_notify_done_title))
                .setContentText(getString(R.string.download_notify_done_text))
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build();
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(DONE_ID, n);
    }

    private void createChannel() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm == null) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL_ID,
                getString(R.string.download_notify_channel), NotificationManager.IMPORTANCE_LOW);
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);
    }

    private List<Entry> loadDownloads() {
        List<Entry> list = new ArrayList<>();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(
                new FileInputStream(CONFIG_FILE), "UTF-8"))) {
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                String[] p = line.split("\\|", -1);
                if (p.length < 4 || !"D".equals(p[0])) continue;
                Entry e = new Entry();
                e.id = p[1];
                e.title = p[2];
                e.url = p[3];
                if (p.length > 4) e.sha256 = p[4];
                if (p.length > 5) {
                    try { e.size = Long.parseLong(p[5]); } catch (Exception ignored) { }
                }
                list.add(e);
            }
        } catch (Exception ignored) {
            // Нет конфигурации — загружать нечего.
        }
        return list;
    }

    static String fileNameFromUrl(String url) {
        int slash = url.lastIndexOf('/');
        String name = slash >= 0 ? url.substring(slash + 1) : url;
        int q = name.indexOf('?');
        if (q >= 0) name = name.substring(0, q);
        return name;
    }

    static String mb(long bytes) {
        if (bytes <= 0) return "?";
        return String.format(Locale.US, "%.1f МБ", bytes / 1048576.0);
    }

    static String pct(long done, long total) {
        if (total <= 0) return "?";
        return String.format(Locale.US, "%d%%", done * 100 / total);
    }

    static String sha256(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(f)) {
            byte[] b = new byte[1 << 20];
            int n;
            while ((n = in.read(b)) > 0) md.update(b, 0, n);
        }
        StringBuilder sb = new StringBuilder();
        for (byte x : md.digest()) sb.append(String.format(Locale.US, "%02x", x));
        return sb.toString();
    }
}
