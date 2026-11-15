/*
 * los-tv: full-screen message shown before the automatic reboot into recovery.
 *
 * On the first boot after an OTA the add-on restore script reboots silently
 * to install Widevine/NDK.  This activity gives the user a readable message
 * and keeps the screen on; the script waits 4 seconds before rebooting.
 */
package org.los.tv.addon;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

public class RebootActivity extends Activity {

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable finishRunnable = new Runnable() {
        @Override
        public void run() {
            finish();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED);
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);

        int pad = (int) (48 * getResources().getDisplayMetrics().density);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setBackgroundColor(Color.BLACK);
        root.setPadding(pad, pad, pad, pad);

        TextView message = new TextView(this);
        message.setText(R.string.reboot_for_components);
        message.setTextColor(Color.LTGRAY);
        message.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30);
        message.setGravity(Gravity.CENTER);
        root.addView(message);

        setContentView(root);
        handler.postDelayed(finishRunnable, 8000);
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(finishRunnable);
        super.onDestroy();
    }
}
