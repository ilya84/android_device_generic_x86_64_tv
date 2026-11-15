package org.los.tv.addon;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;

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
 * los-tv: плитка «Проприетарные компоненты».
 *
 * Объясняет, что будет установлено, показывает QR-коды и ссылки на APK,
 * скачивает два образа Google (ChromeOS и google_apis), сохраняет LINKS.txt
 * и запускает установку через recovery (запрос + штатный reboot в recovery).
 *
 * Сервис /system/bin/los-tv-addon-check.sh при загрузке выставляет свойства
 * sys.los_tv.addon_installed / sys.los_tv.addon_payload и управляет видимостью
 * плитки; здесь мы только читаем их и умеем скрыть плитку по просьбе.
 */
public class MainActivity extends Activity {

    private static final File ADDON_DIR = new File("/sdcard/los-tv-proprietary");
    private static final File REQUEST_FILE = new File(ADDON_DIR, ".install-request");
    private static final File LINKS_TXT = new File(ADDON_DIR, "LINKS.txt");
    private static final File CONFIG_FILE = new File("/system/etc/los-tv-addon/links.txt");

    private static final String PROP_INSTALLED = "sys.los_tv.addon_installed";
    private static final String PROP_PAYLOAD = "sys.los_tv.addon_payload";

    private static final int QR_SIZE = 300;
    private static final String TAG = "LosTvAddon";

    private final List<Entry> entries = new ArrayList<>();
    private final Handler ui = new Handler(Looper.getMainLooper());

    private ScrollView scrollView;
    private TextView statusView;
    private TextView progressView;
    private Button downloadButton;
    private Button installButton;
    private Button linksButton;
    private Button hideButton;


    // ------------------------------------------------------------------ data

    static class Entry {
        String type;     // "D" (download) or "L" (link)
        String id;
        String title;
        String url;
        String sha256;
        long size;
        String note;

        File localFile() {
            return new File(ADDON_DIR, fileNameFromUrl(url));
        }
    }

    static String fileNameFromUrl(String url) {
        int slash = url.lastIndexOf('/');
        String name = slash >= 0 ? url.substring(slash + 1) : url;
        int q = name.indexOf('?');
        if (q >= 0) name = name.substring(0, q);
        return name;
    }

    // ------------------------------------------------------------------- ui

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildUi());

        // Ссылки на APK полезно иметь файлом сразу, не дожидаясь нажатия:
        // пользователь забирает их по adb/USB или читает с телефона.
        saveLinksFile();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshState();
        pollDownload();
    }

    private View buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.BLACK);

        // Прокручиваемый контент: получает фокус и листается D-pad'ом.
        // Кнопки — в фиксированной нижней панели, поэтому доступны всегда.
        final ScrollView scroll = new ScrollView(this);
        scrollView = scroll;
        scroll.setBackgroundColor(Color.BLACK);
        scroll.setFocusable(true);
        scroll.setFocusableInTouchMode(true);
        scroll.setOnKeyListener((v, keyCode, event) -> {
            if (event.getAction() != android.view.KeyEvent.ACTION_DOWN) return false;
            int step = dp(200);
            if (keyCode == android.view.KeyEvent.KEYCODE_DPAD_DOWN) {
                if (!atBottom(scroll)) {
                    scroll.smoothScrollBy(0, step);
                    return true;
                }
                // Дошли до конца — уходим в нижнюю панель, иначе фокус
                // «застревает» на ScrollView и кнопки недоступны.
                if (installButton != null && installButton.isEnabled()) {
                    installButton.requestFocus();
                    return true;
                }
                if (downloadButton != null && downloadButton.isEnabled()) {
                    downloadButton.requestFocus();
                    return true;
                }
                return false;
            }
            if (keyCode == android.view.KeyEvent.KEYCODE_DPAD_UP) {
                if (scroll.canScrollVertically(-1)) {
                    scroll.smoothScrollBy(0, -step);
                    return true;
                }
                return false;
            }
            return false;
        });
        LinearLayout.LayoutParams scrollLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(scroll, scrollLp);

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(48);
        content.setPadding(pad, pad, pad, dp(16));
        scroll.addView(content, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT, ScrollView.LayoutParams.WRAP_CONTENT));

        TextView title = text(getString(R.string.app_name), 34, Color.WHITE, true);
        content.addView(title);

        statusView = text("", 20, 0xFFB0BEC5, false);
        statusView.setPadding(0, dp(12), 0, dp(12));
        content.addView(statusView);

        TextView info = text(getString(R.string.intro), 18, 0xFFE0E0E0, false);
        info.setLineSpacing(dp(4), 1.0f);
        content.addView(info);

        // --- ссылки и QR ---
        TextView header = text(getString(R.string.links_header), 24, Color.WHITE, true);
        header.setPadding(0, dp(24), 0, dp(8));
        content.addView(header);

        loadEntries();
        for (Entry e : entries) {
            if (!"L".equals(e.type)) continue;
            addEntryViews(content, e);
        }

        TextView imagesHeader = text(getString(R.string.images_header), 24, Color.WHITE, true);
        imagesHeader.setPadding(0, dp(24), 0, dp(8));
        content.addView(imagesHeader);

        for (Entry e : entries) {
            if (!"D".equals(e.type)) continue;
            addEntryViews(content, e);
        }
        content.addView(text(getString(R.string.images_hint), 16, 0xFFB0BEC5, false));

        // --- нижняя панель ---
        LinearLayout footer = new LinearLayout(this);
        footer.setOrientation(LinearLayout.VERTICAL);
        footer.setBackgroundColor(0xFF101010);
        footer.setPadding(pad, dp(8), pad, dp(12));

        progressView = text("", 16, 0xFF90CAF9, false);
        progressView.setPadding(0, 0, 0, dp(4));
        footer.addView(progressView);

        // Две строки: длинная подпись «Убрать плитку…» не влезает в один ряд.
        LinearLayout row1 = new LinearLayout(this);
        row1.setOrientation(LinearLayout.HORIZONTAL);
        row1.setGravity(Gravity.CENTER_VERTICAL);
        footer.addView(row1);

        LinearLayout row2 = new LinearLayout(this);
        row2.setOrientation(LinearLayout.HORIZONTAL);
        row2.setGravity(Gravity.CENTER_VERTICAL);
        footer.addView(row2);

        downloadButton = button(getString(R.string.download));
        downloadButton.setOnClickListener(v -> startDownload());
        row1.addView(downloadButton);

        installButton = button(getString(R.string.install));
        installButton.setOnClickListener(v -> startInstall());
        row1.addView(installButton);

        linksButton = button(getString(R.string.save_links));
        linksButton.setOnClickListener(v -> saveLinksFile());
        row1.addView(linksButton);

        hideButton = button(getString(R.string.hide_tile));
        hideButton.setOnClickListener(v -> hideTile());
        row2.addView(hideButton);

        // Из первой строки кнопок D-pad вверх возвращает к тексту.
        View.OnKeyListener backToScroll = (v, keyCode, event) -> {
            if (event.getAction() == android.view.KeyEvent.ACTION_DOWN &&
                    keyCode == android.view.KeyEvent.KEYCODE_DPAD_UP) {
                scroll.requestFocus();
                scroll.smoothScrollBy(0, -dp(220));
                return true;
            }
            return false;
        };
        downloadButton.setOnKeyListener(backToScroll);
        installButton.setOnKeyListener(backToScroll);
        linksButton.setOnKeyListener(backToScroll);

        root.addView(footer);

        // Фокус — на прокручиваемом контенте, иначе D-pad сразу прыгает
        // на первую кнопку и текст сверху не полистать.
        scroll.post(scroll::requestFocus);

        return root;
    }

    private void addEntryViews(LinearLayout parent, Entry e) {
        parent.addView(text(e.title, 20, Color.WHITE, true));
        if (!TextUtils.isEmpty(e.url)) {
            parent.addView(text(e.url, 14, 0xFF64B5F6, false));
        }
        if (!TextUtils.isEmpty(e.note)) {
            parent.addView(text(e.note, 15, 0xFFB0BEC5, false));
        }
        ImageView qr = new ImageView(this);
        Bitmap bmp = qrBitmap(e.url, QR_SIZE);
        if (bmp != null) {
            qr.setImageBitmap(bmp);
            qr.setBackgroundColor(Color.WHITE);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(QR_SIZE), dp(QR_SIZE));
            lp.topMargin = dp(8);
            lp.bottomMargin = dp(20);
            parent.addView(qr, lp);
        }
    }

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView v = new TextView(this);
        v.setText(s);
        v.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        v.setTextColor(color);
        if (bold) v.setTypeface(null, android.graphics.Typeface.BOLD);
        return v;
    }

    private Button button(String s) {
        Button b = new Button(this);
        b.setText(s);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        b.setSingleLine(true);
        b.setTextColor(getColorStateList(R.color.btn_text));
        b.setBackgroundResource(R.drawable.btn_bg);
        b.setPadding(dp(20), dp(8), dp(20), dp(8));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.rightMargin = dp(8);
        b.setLayoutParams(lp);
        return b;
    }

    private boolean atBottom(ScrollView s) {
        View child = s.getChildAt(0);
        return child != null && s.getScrollY() + s.getHeight() >= child.getHeight() - dp(8);
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    // ---------------------------------------------------------------- config

    private void loadEntries() {
        entries.clear();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(
                new FileInputStream(CONFIG_FILE), "UTF-8"))) {
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                String[] p = line.split("\\|", -1);
                if (p.length < 4) continue;
                Entry e = new Entry();
                e.type = p[0];
                e.id = p[1];
                e.title = p[2];
                e.url = p[3];
                if (p.length > 4) e.sha256 = p[4];
                if (p.length > 5) {
                    try { e.size = Long.parseLong(p[5]); } catch (Exception ignored) { }
                }
                if (p.length > 6) e.note = p[6];
                entries.add(e);
            }
        } catch (Exception ignored) {
            // Файла нет или он битый — используем встроенный минимум.
        }
        if (entries.isEmpty()) {
            Entry a = new Entry();
            a.type = "L"; a.id = "playstore";
            a.title = "Play Store (Android TV) — APKMirror";
            a.url = "https://www.apkmirror.com/apk/google-inc/google-play-store-android-tv/";
            entries.add(a);
            Entry b = new Entry();
            b.type = "L"; b.id = "youtube";
            b.title = "YouTube TV — APKMirror";
            b.url = "https://www.apkmirror.com/apk/google-inc/youtube-for-android-tv-android-tv/";
            entries.add(b);
        }
    }

    private List<Entry> downloads() {
        List<Entry> list = new ArrayList<>();
        for (Entry e : entries) if ("D".equals(e.type)) list.add(e);
        return list;
    }

    private List<Entry> links() {
        List<Entry> list = new ArrayList<>();
        for (Entry e : entries) if ("L".equals(e.type)) list.add(e);
        return list;
    }

    // ----------------------------------------------------------------- state

    private boolean componentsInstalled() {
        return new File("/system/lib64/libndk_translation.so").exists()
                && new File("/system/vendor/bin/hw/android.hardware.drm-service-lazy.widevine").exists();
    }

    private boolean payloadPresent() {
        if ("1".equals(prop(PROP_PAYLOAD))) return true;
        return new File("/mnt/cdrom/los-tv-proprietary.tar.gz").exists()
                || new File("/data/los-tv-proprietary.tar.gz").exists();
    }

    private void refreshState() {
        boolean installed = componentsInstalled() || "1".equals(prop(PROP_INSTALLED));
        boolean payload = payloadPresent();
        int have = 0;
        int need = 0;
        for (Entry e : downloads()) {
            need++;
            if (e.localFile().exists()) have++;
        }

        StringBuilder sb = new StringBuilder();
        if (installed) {
            sb.append(getString(R.string.state_installed));
        } else {
            sb.append(getString(R.string.state_not_installed));
            if (payload) sb.append(getString(R.string.state_payload));
        }
        sb.append("\n").append(getString(R.string.state_files, have, need));
        statusView.setText(sb.toString());

        boolean external = Environment.isExternalStorageManager();
        if (!external && !installed) {
            statusView.append("\n" + getString(R.string.state_no_storage));
        }

        downloadButton.setEnabled(!installed && !DownloadService.running && (have < need));
        if (DownloadService.running) {
            downloadButton.setEnabled(false);
        }
        bindInstallState(installed, payload, have, need);
    }

    private void bindInstallState(boolean installed, boolean payload, int have, int need) {
        if (installed) {
            installButton.setText(getString(R.string.add_apps_short));
            installButton.setEnabled(true);
            return;
        }
        installButton.setText(getString(R.string.install));
        installButton.setEnabled(!DownloadService.running && (have == need || payload));
    }

    // -------------------------------------------------------------- download

    private final Runnable pollRunnable = new Runnable() {
        @Override
        public void run() {
            if (DownloadService.statusText != null) {
                progressView.setText(DownloadService.statusText);
            }
            if (DownloadService.running) {
                ui.postDelayed(this, 1000);
            } else if (DownloadService.errorText != null) {
                progressView.setText(getString(R.string.download_error, DownloadService.errorText));
            } else if (DownloadService.finished) {
                progressView.setText(R.string.download_done);
                refreshState();
            }
        }
    };

    private void startDownload() {
        if (DownloadService.running) return;
        progressView.setText(R.string.download_background);
        startForegroundService(new Intent(this, DownloadService.class));
        ui.removeCallbacks(pollRunnable);
        ui.postDelayed(pollRunnable, 500);
    }

    private void pollDownload() {
        ui.removeCallbacks(pollRunnable);
        if (DownloadService.running) {
            ui.postDelayed(pollRunnable, 300);
        }
    }

    // --------------------------------------------------------------- install

    private void startInstall() {
        boolean payload = payloadPresent();
        int need = 0, have = 0;
        for (Entry e : downloads()) {
            need++;
            if (e.localFile().exists()) have++;
        }
        boolean installed = componentsInstalled();

        if (!installed && !payload && have < need) {
            progressView.setText(R.string.install_need_files);
            return;
        }
        if (installed && !hasApks()) {
            progressView.setText(R.string.install_need_apks);
            return;
        }

        try {
            ADDON_DIR.mkdirs();
            try (FileOutputStream fos = new FileOutputStream(REQUEST_FILE)) {
                fos.write("install\n".getBytes("UTF-8"));
                fos.getFD().sync();
            }
        } catch (Exception ex) {
            progressView.setText(getString(R.string.install_error, String.valueOf(ex.getMessage())));
            return;
        }

        progressView.setText(R.string.install_rebooting);
        installButton.setEnabled(false);

        ui.postDelayed(() -> {
            try {
                PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
                if (pm == null) {
                    android.util.Log.e(TAG, "PowerManager is null");
                    progressView.setText(R.string.install_error + " (no PowerManager)");
                    return;
                }
                pm.reboot("recovery");
                android.util.Log.i(TAG, "reboot(recovery) requested");
            } catch (Throwable t) {
                android.util.Log.e(TAG, "reboot(recovery) failed", t);
                progressView.setText("Не удалось перезагрузиться: " + t);
            }
        }, 1500);
    }

    private boolean hasApks() {
        File[] files = ADDON_DIR.listFiles();
        if (files == null) return false;
        for (File f : files) {
            String n = f.getName().toLowerCase(Locale.US);
            if (n.endsWith(".apk") || n.endsWith(".apkm")) return true;
        }
        return false;
    }

    // ----------------------------------------------------------------- links

    private void saveLinksFile() {
        try {
            ADDON_DIR.mkdirs();
            StringBuilder sb = new StringBuilder();
            sb.append(getString(R.string.links_file_header)).append("\n\n");
            for (Entry e : links()) {
                sb.append(e.title).append("\n");
                sb.append("  ").append(e.url).append("\n");
                if (!TextUtils.isEmpty(e.note)) sb.append("  ").append(e.note).append("\n");
                sb.append("\n");
            }
            sb.append(getString(R.string.links_file_footer)).append("\n");
            try (FileOutputStream fos = new FileOutputStream(LINKS_TXT)) {
                fos.write(sb.toString().getBytes("UTF-8"));
            }
            progressView.setText(getString(R.string.links_saved, LINKS_TXT.getAbsolutePath()));
        } catch (Exception ex) {
            progressView.setText(getString(R.string.links_save_error, String.valueOf(ex.getMessage())));
        }
    }

    // ------------------------------------------------------------------ tile

    private void hideTile() {
        try {
            getPackageManager().setComponentEnabledSetting(
                    new ComponentName(this, MainActivity.class),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP);
            progressView.setText(R.string.tile_hidden);
            finish();
        } catch (Exception ex) {
            progressView.setText(getString(R.string.tile_hide_error, String.valueOf(ex.getMessage())));
        }
    }

    // ------------------------------------------------------------------- qr

    private Bitmap qrBitmap(String data, int size) {
        if (TextUtils.isEmpty(data)) return null;
        try {
            BitMatrix m = new QRCodeWriter().encode(data, BarcodeFormat.QR_CODE, size, size);
            int w = m.getWidth(), h = m.getHeight();
            int[] px = new int[w * h];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    px[y * w + x] = m.get(x, y) ? Color.BLACK : Color.WHITE;
                }
            }
            return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888);
        } catch (Exception e) {
            return null;
        }
    }

    // -------------------------------------------------------------- helpers

    private static String prop(String name) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"getprop", name});
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                String s = r.readLine();
                p.waitFor();
                return s == null ? "" : s.trim();
            }
        } catch (Exception e) {
            return "";
        }
    }
}
