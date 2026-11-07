package io.github.l1vef4stdieyoung.photoframe;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Opens the photo frame when the tablet has finished starting up. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String a = intent.getAction();
        if (Intent.ACTION_BOOT_COMPLETED.equals(a) || "android.intent.action.QUICKBOOT_POWERON".equals(a) || Intent.ACTION_MY_PACKAGE_REPLACED.equals(a)) {
            Intent i = new Intent(context, MainActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
            try {
                context.startActivity(i);
            } catch (Exception ignored) {
                // Android blocks this unless "display over other apps" is allowed; the user can grant it in Settings.
            }
        }
    }
}
