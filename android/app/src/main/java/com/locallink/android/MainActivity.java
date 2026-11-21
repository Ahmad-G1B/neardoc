package com.locallink.android;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;

import com.journeyapps.barcodescanner.ScanContract;
import com.journeyapps.barcodescanner.ScanOptions;

import java.util.List;

/**
 * O+ Connect-style local companion for LinkBridge:
 * QR pairing, two-way Wi-Fi file transfer, and clipboard sync.
 */
public final class MainActivity extends AppCompatActivity {
    private TextView pairedBanner;
    private TextView status;
    private Button sendFilesButton;
    private Button pauseTransferButton;
    private Button stopTransferButton;
    private Button receiveNowButton;
    private Button sendClipButton;
    private Button getClipButton;
    private Button checkConnectionButton;
    private Button unpairButton;

    private ActivityResultLauncher<ScanOptions> qrScanner;
    private ActivityResultLauncher<String[]> filePicker;

    private final Handler pollHandler = new Handler(Looper.getMainLooper());
    private boolean pollingActive = false;
    private boolean pollInFlight = false;
    private boolean uploadInFlight = false;
    private boolean uploadCancelled = false;

    private final Runnable pollTask = new Runnable() {
        @Override
        public void run() {
            if (!pollingActive) return;
            PairingClient.PairedMac mac = PairingClient.loadPaired(MainActivity.this);
            if (mac != null && !pollInFlight && !uploadInFlight) {
                pollInFlight = true;
                PairingClient.pollPending(MainActivity.this, mac, new PairingClient.PendingCallback() {
                    @Override public void onClipboardReceived(String text) {
                        runOnUiThread(() -> {
                            pollInFlight = false;
                            copyToClipboard(text);
                            String msg = "Synced Mac clipboard (" + text.length() + " chars).";
                            showStatus(msg);
                            LocalLog.add(MainActivity.this, msg);
                        });
                    }
                    @Override public void onFileReceived(String fileName) {
                        runOnUiThread(() -> {
                            pollInFlight = false;
                            String msg = "Received " + fileName + " → Downloads/Bridge.";
                            showStatus(msg);
                            LocalLog.add(MainActivity.this, msg);
                        });
                    }
                    @Override public void onNone() {
                        runOnUiThread(() -> pollInFlight = false);
                    }
                    @Override public void onError(String message) {
                        runOnUiThread(() -> pollInFlight = false);
                    }
                });
            }
            pollHandler.postDelayed(this, 3_000);
        }
    };

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        qrScanner = registerForActivityResult(new ScanContract(), result -> {
            String contents = result.getContents();
            if (contents == null) {
                showStatus("QR scan cancelled.");
                return;
            }
            String[] fields = contents.trim().split("\\|", -1);
            if (fields.length != 4 || !"LB1".equals(fields[0])) {
                showStatus("That QR code is not a Bridge pairing code.");
                LocalLog.add(this, "Rejected unrecognized QR code");
                return;
            }
            final int port;
            try { port = Integer.parseInt(fields[2]); }
            catch (NumberFormatException error) { showStatus("The QR code has an invalid port."); return; }

            showStatus("Pairing with Mac on your local network…");
            LocalLog.add(this, "QR pairing started for " + fields[1] + ":" + port);
            PairingClient.verify(this, fields[1], port, fields[3], (success, message) -> runOnUiThread(() -> {
                showStatus(message);
                LocalLog.add(this, message);
                refreshPairedState();
            }));
        });

        filePicker = registerForActivityResult(new ActivityResultContracts.OpenMultipleDocuments(), uris -> {
            if (uris == null || uris.isEmpty()) return;
            PairingClient.PairedMac mac = PairingClient.loadPaired(this);
            if (mac == null) {
                showStatus("Pair with your Mac first.");
                return;
            }
            sendSelectedFiles(mac, uris);
        });

        setContentView(createView());
        refreshPairedState();
        LocalLog.add(this, "Bridge opened");
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshPairedState();
        pollingActive = true;
        pollHandler.removeCallbacks(pollTask);
        pollHandler.postDelayed(pollTask, 1_000);
    }

    @Override
    protected void onPause() {
        super.onPause();
        pollingActive = false;
        pollHandler.removeCallbacks(pollTask);
    }

    private void sendSelectedFiles(PairingClient.PairedMac mac, List<Uri> uris) {
        uploadInFlight = true;
        uploadCancelled = false;
        PairingClient.resetTransferControls();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        sendFilesButton.setEnabled(false);
        pauseTransferButton.setText("Pause transfer");
        pauseTransferButton.setEnabled(true);
        stopTransferButton.setEnabled(true);
        sendNextFile(mac, uris, 0);
    }

    private void sendNextFile(PairingClient.PairedMac mac, List<Uri> uris, int index) {
        if (uploadCancelled || index >= uris.size()) {
            uploadInFlight = false;
            uploadCancelled = false;
            PairingClient.resetTransferControls();
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            pauseTransferButton.setText("Pause transfer");
            pauseTransferButton.setEnabled(false);
            stopTransferButton.setEnabled(false);
            refreshPairedState();
            return;
        }
        showStatus("Preparing file " + (index + 1) + " of " + uris.size() + "…");
        PairingClient.sendFile(this, mac, uris.get(index), new PairingClient.ProgressCallback() {
            @Override public void onProgress(String message) {
                runOnUiThread(() -> showStatus(message));
            }
            @Override public void onComplete(boolean success, String message) {
                runOnUiThread(() -> {
                    showStatus(message);
                    LocalLog.add(MainActivity.this, message);
                    sendNextFile(mac, uris, index + 1);
                });
            }
        });
    }

    private View createView() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dp(22), dp(36), dp(22), dp(28));
        root.setBackgroundColor(Color.rgb(15, 23, 42));
        scroll.addView(root);

        TextView title = text("Bridge", 32, Color.WHITE);
        title.setGravity(Gravity.CENTER);
        root.addView(title);

        TextView subtitle = text("Mac ↔ Android Local Companion", 15, Color.rgb(148, 163, 184));
        subtitle.setGravity(Gravity.CENTER);
        subtitle.setPadding(0, dp(4), 0, dp(18));
        root.addView(subtitle);

        pairedBanner = text("Not paired with a Mac yet", 15, Color.rgb(226, 232, 240));
        pairedBanner.setPadding(dp(16), dp(14), dp(16), dp(14));
        pairedBanner.setBackgroundColor(Color.rgb(30, 41, 59));
        root.addView(pairedBanner, fullWidthParams(0));

        Button scan = actionButton("Scan Bridge QR on Mac", v -> {
            ScanOptions options = new ScanOptions();
            options.setDesiredBarcodeFormats(ScanOptions.QR_CODE);
            options.setPrompt("Scan the QR shown in Bridge on your Mac");
            options.setBeepEnabled(false);
            options.setOrientationLocked(false);
            qrScanner.launch(options);
        });
        root.addView(scan, fullWidthParams(16));

        status = text("Ready. Pair with QR to enable Wi-Fi file transfer and clipboard sync.", 14, Color.rgb(186, 202, 222));
        status.setGravity(Gravity.CENTER);
        status.setPadding(dp(6), dp(14), dp(6), dp(14));
        root.addView(status, fullWidthParams(0));

        TextView transferLabel = text("WI-FI TRANSFER & CLIPBOARD", 12, Color.rgb(148, 163, 184));
        transferLabel.setPadding(0, dp(8), 0, dp(6));
        root.addView(transferLabel, fullWidthParams(0));

        sendFilesButton = actionButton("Send file(s) to Mac", v -> filePicker.launch(new String[]{"*/*"}));
        root.addView(sendFilesButton, fullWidthParams(4));

        LinearLayout transferControls = new LinearLayout(this);
        transferControls.setOrientation(LinearLayout.HORIZONTAL);
        pauseTransferButton = actionButton("Pause transfer", v -> {
            if (!uploadInFlight) return;
            boolean nextPaused = !PairingClient.isTransferPaused();
            PairingClient.setTransferPaused(nextPaused);
            pauseTransferButton.setText(nextPaused ? "Resume transfer" : "Pause transfer");
            if (!nextPaused) showStatus("Resuming transfer…");
        });
        pauseTransferButton.setEnabled(false);
        stopTransferButton = actionButton("Stop transfer", v -> {
            if (!uploadInFlight) return;
            uploadCancelled = true;
            PairingClient.cancelActiveTransfer();
            showStatus("Stopping transfer…");
        });
        stopTransferButton.setEnabled(false);
        LinearLayout.LayoutParams halfParams = new LinearLayout.LayoutParams(0, -2, 1f);
        transferControls.addView(pauseTransferButton, halfParams);
        transferControls.addView(stopTransferButton, halfParams);
        root.addView(transferControls, fullWidthParams(6));

        receiveNowButton = actionButton("Receive pending files / clipboard from Mac", v -> {
            PairingClient.PairedMac mac = PairingClient.loadPaired(this);
            if (mac == null) { showStatus("Pair with your Mac first."); return; }
            showStatus("Checking " + mac.macName + " for queued items…");
            PairingClient.pollPending(this, mac, new PairingClient.PendingCallback() {
                @Override public void onClipboardReceived(String text) {
                    runOnUiThread(() -> {
                        copyToClipboard(text);
                        String msg = "Synced Mac clipboard (" + text.length() + " chars).";
                        showStatus(msg);
                        LocalLog.add(MainActivity.this, msg);
                    });
                }
                @Override public void onFileReceived(String fileName) {
                    runOnUiThread(() -> {
                        String msg = "Saved " + fileName + " to Downloads/Bridge.";
                        showStatus(msg);
                        LocalLog.add(MainActivity.this, msg);
                    });
                }
                @Override public void onNone() {
                    runOnUiThread(() -> showStatus("Nothing queued on " + mac.macName + " right now."));
                }
                @Override public void onError(String message) {
                    runOnUiThread(() -> {
                        showStatus("Check failed: " + message);
                        LocalLog.add(MainActivity.this, "Poll failed: " + message);
                    });
                }
            });
        });
        root.addView(receiveNowButton, fullWidthParams(6));

        sendClipButton = actionButton("Send phone clipboard to Mac", v -> {
            PairingClient.PairedMac mac = PairingClient.loadPaired(this);
            if (mac == null) { showStatus("Pair with your Mac first."); return; }
            String clip = readFromClipboard();
            if (clip != null && !clip.isEmpty()) {
                showStatus("Sending clipboard to " + mac.macName + "…");
                PairingClient.pushClipboard(mac, clip, (ok, msg) -> runOnUiThread(() -> {
                    showStatus(msg);
                    LocalLog.add(this, msg);
                }));
                return;
            }
            Uri clipUri = readUriFromClipboard();
            if (clipUri != null) {
                showStatus("Clipboard has an image/file — sending it to " + mac.macName + "…");
                sendSelectedFiles(mac, java.util.Collections.singletonList(clipUri));
                return;
            }
            showStatus("Phone clipboard has no text or image to send.");
        });
        root.addView(sendClipButton, fullWidthParams(6));

        getClipButton = actionButton("Get Mac clipboard", v -> {
            PairingClient.PairedMac mac = PairingClient.loadPaired(this);
            if (mac == null) { showStatus("Pair with your Mac first."); return; }
            showStatus("Fetching clipboard from " + mac.macName + "…");
            PairingClient.pullClipboard(mac, (ok, textOrErr) -> runOnUiThread(() -> {
                if (ok) {
                    copyToClipboard(textOrErr);
                    String msg = "Copied Mac clipboard (" + textOrErr.length() + " chars).";
                    showStatus(msg);
                    LocalLog.add(this, msg);
                } else {
                    showStatus(textOrErr);
                    LocalLog.add(this, textOrErr);
                }
            }));
        });
        root.addView(getClipButton, fullWidthParams(6));

        TextView deviceLabel = text("CONNECTION & TOOLS", 12, Color.rgb(148, 163, 184));
        deviceLabel.setPadding(0, dp(16), 0, dp(6));
        root.addView(deviceLabel, fullWidthParams(0));

        checkConnectionButton = actionButton("Check Mac connection", v -> {
            PairingClient.PairedMac mac = PairingClient.loadPaired(this);
            if (mac == null) { showStatus("Pair with your Mac first."); return; }
            showStatus("Pinging " + mac.macName + "…");
            PairingClient.ping(mac, (ok, msg) -> runOnUiThread(() -> {
                showStatus(msg);
                LocalLog.add(this, msg);
            }));
        });
        root.addView(checkConnectionButton, fullWidthParams(4));

        unpairButton = actionButton("Unpair Mac", v -> {
            PairingClient.clearPaired(this);
            refreshPairedState();
            showStatus("Unpaired. Scan a new QR code on your Mac to reconnect.");
            LocalLog.add(this, "Unpaired from Mac");
        });
        root.addView(unpairButton, fullWidthParams(6));

        Button notifAccess = actionButton("Enable Notification Sync to Mac", v -> {
            try { startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); }
            catch (Exception error) { showStatus("Could not open Notification access settings."); }
        });
        root.addView(notifAccess, fullWidthParams(6));

        Button developer = actionButton("Open Developer options (USB mirroring)", v -> {
            try { startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)); }
            catch (Exception error) { showStatus("Could not open Developer options."); }
        });
        root.addView(developer, fullWidthParams(6));

        Button logs = actionButton("View diagnostic log", v -> new AlertDialog.Builder(this)
            .setTitle("Bridge log")
            .setMessage(LocalLog.read(this))
            .setPositiveButton("Close", null)
            .show());
        root.addView(logs, fullWidthParams(6));

        return scroll;
    }

    private void refreshPairedState() {
        PairingClient.PairedMac mac = PairingClient.loadPaired(this);
        boolean paired = mac != null;
        sendFilesButton.setEnabled(paired);
        receiveNowButton.setEnabled(paired);
        sendClipButton.setEnabled(paired);
        getClipButton.setEnabled(paired);
        checkConnectionButton.setEnabled(paired);
        unpairButton.setEnabled(paired);

        if (paired) {
            pairedBanner.setText("PAIRED WITH " + mac.macName.toUpperCase() + "\n" + mac.host + ":" + mac.port + " · Auto-receiving files & clipboard while open");
            pairedBanner.setBackgroundColor(Color.rgb(20, 62, 48));
        } else {
            pairedBanner.setText("PRIVATE LOCAL BRIDGE\nPut both devices on the same Wi-Fi, open Bridge on Mac, click Pair phone with QR, and scan here.");
            pairedBanner.setBackgroundColor(Color.rgb(30, 41, 59));
        }
    }

    private void copyToClipboard(String text) {
        ClipboardManager manager = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (manager != null) {
            manager.setPrimaryClip(ClipData.newPlainText("Bridge", text));
        }
    }

    private String readFromClipboard() {
        try {
            ClipboardManager manager = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (manager == null || !manager.hasPrimaryClip()) return null;
            ClipData clip = manager.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return null;
            ClipData.Item item = clip.getItemAt(0);
            // Never call coerceToText() on image/file URIs — Android reads the whole binary into RAM and OOM-crashes.
            CharSequence seq = item.getText();
            if (seq == null) seq = item.getHtmlText();
            if (seq == null) return null;
            String text = seq.toString();
            return text.length() > 500_000 ? text.substring(0, 500_000) : text;
        } catch (Throwable error) {
            LocalLog.add(this, "Clipboard read failed: " + error.getClass().getSimpleName());
            return null;
        }
    }

    private Uri readUriFromClipboard() {
        try {
            ClipboardManager manager = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (manager == null || !manager.hasPrimaryClip()) return null;
            ClipData clip = manager.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return null;
            return clip.getItemAt(0).getUri();
        } catch (Throwable ignored) {
            return null;
        }
    }

    private Button actionButton(String label, View.OnClickListener listener) {
        Button button = new Button(this);
        button.setAllCaps(false);
        button.setText(label);
        button.setOnClickListener(listener);
        return button;
    }

    private LinearLayout.LayoutParams fullWidthParams(int topDp) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = dp(topDp);
        return params;
    }

    private void showStatus(String value) { if (status != null) status.setText(value); }

    private TextView text(String value, int size, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        return view;
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
