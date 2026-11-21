package com.locallink.android;

import android.app.Notification;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

/**
 * Forwards incoming Android notifications and incoming calls over the paired local Wi-Fi bridge
 * to macOS Notification Center.
 */
public final class NotificationBridgeService extends NotificationListenerService {
    private String lastSignature = "";
    private long lastSentAt = 0L;

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        if (sbn == null) return;
        String pkg = sbn.getPackageName();
        if (pkg == null || pkg.equals(getPackageName()) || "android".equals(pkg) || "com.android.systemui".equals(pkg)) {
            return;
        }
        Notification notif = sbn.getNotification();
        if (notif == null) return;

        boolean isCall = Notification.CATEGORY_CALL.equals(notif.category)
            || pkg.contains("incallui")
            || pkg.contains("dialer")
            || pkg.contains("telecom");

        // Allow incoming call notifications even when marked ongoing, but skip other ongoing/summary notifications.
        if (!isCall && ((notif.flags & Notification.FLAG_ONGOING_EVENT) != 0 || (notif.flags & Notification.FLAG_GROUP_SUMMARY) != 0)) {
            return;
        }

        PairingClient.PairedMac mac = PairingClient.loadPaired(this);
        if (mac == null) return;

        Bundle extras = notif.extras;
        String title = safeString(extras == null ? null : extras.getCharSequence(Notification.EXTRA_TITLE));
        String body = safeString(extras == null ? null : extras.getCharSequence(Notification.EXTRA_BIG_TEXT));
        if (body.isEmpty()) {
            body = safeString(extras == null ? null : extras.getCharSequence(Notification.EXTRA_TEXT));
        }
        if (title.isEmpty() && body.isEmpty()) return;

        String appName = resolveAppName(pkg);
        String signature = pkg + "|" + title + "|" + body + "|" + isCall;
        long now = System.currentTimeMillis();
        if (signature.equals(lastSignature) && (now - lastSentAt) < 2_500L) {
            return;
        }
        lastSignature = signature;
        lastSentAt = now;

        PairingClient.pushNotification(mac, appName, title, body, sbn.getKey(), isCall);
    }

    private String resolveAppName(String pkg) {
        try {
            PackageManager pm = getPackageManager();
            ApplicationInfo info = pm.getApplicationInfo(pkg, 0);
            CharSequence label = pm.getApplicationLabel(info);
            if (label != null && label.length() > 0) return label.toString();
        } catch (Exception ignored) { }
        return pkg;
    }

    private static String safeString(CharSequence cs) {
        return cs == null ? "" : cs.toString().trim();
    }
}
