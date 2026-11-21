package com.locallink.android;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.util.Base64;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Locale;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Local-network authenticated client for NearDoc (QR pairing, file transfer, clipboard sync).
 */
final class PairingClient {
    private static final String PREFS = "linkbridge_pair";
    private static final String KEY_HOST = "host";
    private static volatile boolean transferPaused = false;
    private static volatile boolean transferCancelled = false;
    private static volatile Socket activeTransferSocket = null;

    static void resetTransferControls() {
        transferPaused = false;
        transferCancelled = false;
    }

    static void setTransferPaused(boolean paused) {
        transferPaused = paused;
    }

    static boolean isTransferPaused() {
        return transferPaused;
    }

    static void cancelActiveTransfer() {
        transferCancelled = true;
        transferPaused = false;
        Socket s = activeTransferSocket;
        if (s != null) {
            try { s.close(); } catch (Exception ignored) { }
        }
    }
    private static final String KEY_PORT = "port";
    private static final String KEY_TOKEN = "token";
    private static final String KEY_MAC_NAME = "mac_name";

    static final class PairedMac {
        final String host;
        final int port;
        final String token;
        final String macName;

        PairedMac(String host, int port, String token, String macName) {
            this.host = host;
            this.port = port;
            this.token = token;
            this.macName = macName;
        }
    }

    interface StatusCallback {
        void onComplete(boolean success, String message);
    }

    interface TextCallback {
        void onComplete(boolean success, String textOrError);
    }

    interface PendingCallback {
        void onClipboardReceived(String text);
        void onFileReceived(String fileName);
        void onNone();
        void onError(String message);
    }

    static PairedMac loadPaired(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String host = prefs.getString(KEY_HOST, null);
        int port = prefs.getInt(KEY_PORT, -1);
        String token = prefs.getString(KEY_TOKEN, null);
        String macName = prefs.getString(KEY_MAC_NAME, "Mac");
        if (host == null || port <= 0 || token == null || token.isEmpty()) return null;
        return new PairedMac(host, port, token, macName);
    }

    static void savePaired(Context context, PairedMac mac) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_HOST, mac.host)
            .putInt(KEY_PORT, mac.port)
            .putString(KEY_TOKEN, mac.token)
            .putString(KEY_MAC_NAME, mac.macName)
            .apply();
    }

    static void clearPaired(Context context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply();
    }

    static void verify(Context context, String host, int port, String secret, StatusCallback callback) {
        new Thread(() -> {
            try (Socket socket = connect(host, port, 8_000)) {
                String nonce = randomNonce();
                String proof = hmac(secret, "client:" + nonce);
                String deviceName = Build.MANUFACTURER + " " + Build.MODEL;
                OutputStream out = socket.getOutputStream();
                out.write(("LB1 " + nonce + " " + proof + " " + b64Encode(deviceName) + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();

                InputStream in = socket.getInputStream();
                String reply = readLineAscii(in);
                String[] parts = reply == null ? new String[0] : reply.split(" ");
                if (parts.length < 3 || !"OK".equals(parts[0])
                        || !hmac(secret, "server:" + nonce + ":" + parts[1]).equals(parts[2])) {
                    throw new SecurityException("The Mac could not be verified. Generate a fresh QR code and try again.");
                }
                if (parts.length >= 5) {
                    String token = parts[3];
                    String macName = b64Decode(parts[4]);
                    savePaired(context, new PairedMac(host, port, token, macName));
                    callback.onComplete(true, "Paired with " + macName + " (" + host + ":" + port + ").");
                } else {
                    callback.onComplete(true, "Paired with the Mac on your local network.");
                }
            } catch (Exception error) {
                callback.onComplete(false, "Pairing failed: " + describe(error));
            }
        }, "LinkBridgePairing").start();
    }

    static void ping(PairedMac mac, StatusCallback callback) {
        new Thread(() -> {
            try (Socket socket = connect(mac.host, mac.port, 4_000)) {
                String nonce = randomNonce();
                String proof = hmac(mac.token, "PING:" + nonce);
                OutputStream out = socket.getOutputStream();
                out.write(("PING " + nonce + " " + proof + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
                String reply = readLineAscii(socket.getInputStream());
                if (reply != null && reply.startsWith("PONG ")) {
                    String macName = b64Decode(reply.substring(5).trim());
                    callback.onComplete(true, "Connected to " + macName + " on local Wi-Fi.");
                } else {
                    callback.onComplete(false, "Mac rejected the session. Pair again with a new QR code.");
                }
            } catch (Exception error) {
                callback.onComplete(false, "Mac unreachable: " + describe(error));
            }
        }, "LinkBridgePing").start();
    }

    static void pushClipboard(PairedMac mac, String text, StatusCallback callback) {
        new Thread(() -> {
            try (Socket socket = connect(mac.host, mac.port, 8_000)) {
                byte[] payload = text.getBytes(StandardCharsets.UTF_8);
                String nonce = randomNonce();
                String proof = hmac(mac.token, "CLIP_PUSH:" + nonce + ":" + payload.length);
                OutputStream out = new BufferedOutputStream(socket.getOutputStream());
                out.write(("CLIP_PUSH " + nonce + " " + proof + " " + payload.length + "\n").getBytes(StandardCharsets.UTF_8));
                out.write(payload);
                out.flush();
                String reply = readLineAscii(socket.getInputStream());
                if ("OK".equals(reply)) {
                    callback.onComplete(true, "Sent clipboard (" + text.length() + " chars) to " + mac.macName + ".");
                } else {
                    callback.onComplete(false, "Mac declined clipboard update (" + reply + ").");
                }
            } catch (Exception error) {
                callback.onComplete(false, "Clipboard send failed: " + describe(error));
            }
        }, "LinkBridgeClipPush").start();
    }

    static void pullClipboard(PairedMac mac, TextCallback callback) {
        new Thread(() -> {
            try (Socket socket = connect(mac.host, mac.port, 8_000)) {
                String nonce = randomNonce();
                String proof = hmac(mac.token, "CLIP_PULL:" + nonce);
                OutputStream out = socket.getOutputStream();
                out.write(("CLIP_PULL " + nonce + " " + proof + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
                InputStream in = socket.getInputStream();
                String header = readLineAscii(in);
                if (header == null || !header.startsWith("OK ")) {
                    callback.onComplete(false, "Could not fetch Mac clipboard (" + header + ").");
                    return;
                }
                int len = Integer.parseInt(header.substring(3).trim());
                byte[] bytes = readExact(in, len);
                callback.onComplete(true, new String(bytes, StandardCharsets.UTF_8));
            } catch (Exception error) {
                callback.onComplete(false, "Clipboard fetch failed: " + describe(error));
            }
        }, "LinkBridgeClipPull").start();
    }

    static void pushNotification(PairedMac mac, String appName, String title, String body, String notifKey, boolean isCall) {
        new Thread(() -> {
            try (Socket socket = connect(mac.host, mac.port, 4_000)) {
                String nonce = randomNonce();
                String appB64 = b64Encode(appName);
                String titleB64 = b64Encode(title);
                String bodyB64 = b64Encode(body);
                String keyB64 = b64Encode(notifKey == null ? "" : notifKey);
                String kind = isCall ? "CALL" : "MSG";
                String proof = hmac(mac.token, "NOTIF_PUSH:" + nonce + ":" + appB64 + ":" + titleB64 + ":" + bodyB64);
                OutputStream out = socket.getOutputStream();
                out.write(("NOTIF_PUSH " + nonce + " " + proof + " " + appB64 + " " + titleB64 + " " + bodyB64 + " " + keyB64 + " " + kind + "\n")
                    .getBytes(StandardCharsets.UTF_8));
                out.flush();
                readLineAscii(socket.getInputStream());
            } catch (Exception ignored) {
                // Silent best-effort when Mac is asleep or NearDoc is closed.
            }
        }, "BridgeNotifPush").start();
    }

    interface ProgressCallback {
        void onProgress(String message);
        void onComplete(boolean success, String message);
    }

    static void sendFile(Context context, PairedMac mac, Uri uri, ProgressCallback callback) {
        new Thread(() -> {
            File tempCopy = null;
            try {
                ContentResolver resolver = context.getContentResolver();
                String name = queryDisplayName(resolver, uri);
                long size = querySize(resolver, uri);
                InputStream fileInput;

                if (size < 0) {
                    callback.onProgress("Preparing " + name + "…");
                    tempCopy = File.createTempFile("lb_upload_", ".tmp", context.getCacheDir());
                    try (InputStream src = resolver.openInputStream(uri);
                         OutputStream dst = new FileOutputStream(tempCopy)) {
                        if (src == null) throw new IOException("Cannot open selected file.");
                        copyStream(src, dst);
                    }
                    size = tempCopy.length();
                    fileInput = new FileInputStream(tempCopy);
                } else {
                    fileInput = resolver.openInputStream(uri);
                    if (fileInput == null) throw new IOException("Cannot open selected file.");
                }

                String totalMb = String.format(Locale.ROOT, "%.1f", size / (1024.0 * 1024.0));
                try (InputStream source = fileInput; Socket socket = connect(mac.host, mac.port, 15_000)) {
                    activeTransferSocket = socket;
                    socket.setSoTimeout(300_000);
                    socket.setKeepAlive(true);
                    socket.setTcpNoDelay(true);
                    socket.setSendBufferSize(512 * 1024);
                    String nonce = randomNonce();
                    String encodedName = b64Encode(name);
                    String proof = hmac(mac.token, "FILE_PUSH:" + nonce + ":" + encodedName + ":" + size);
                    OutputStream out = new BufferedOutputStream(socket.getOutputStream(), 262_144);
                    out.write(("FILE_PUSH " + nonce + " " + proof + " " + encodedName + " " + size + "\n").getBytes(StandardCharsets.UTF_8));

                    byte[] buf = new byte[262_144];
                    long sent = 0;
                    long lastReport = 0;
                    boolean reportedPause = false;
                    int n;
                    while ((n = source.read(buf)) != -1) {
                        while (transferPaused && !transferCancelled) {
                            if (!reportedPause) {
                                reportedPause = true;
                                String sentMb = String.format(Locale.ROOT, "%.1f", sent / (1024.0 * 1024.0));
                                callback.onProgress("Paused " + name + " at " + sentMb + " / " + totalMb + " MB. Tap Resume to continue.");
                            }
                            try { Thread.sleep(150); } catch (InterruptedException ignored) { }
                        }
                        if (transferCancelled) {
                            callback.onComplete(false, "Transfer stopped for " + name + ".");
                            return;
                        }
                        reportedPause = false;
                        out.write(buf, 0, n);
                        sent += n;
                        long now = System.currentTimeMillis();
                        if (now - lastReport >= 500) {
                            lastReport = now;
                            String sentMb = String.format(Locale.ROOT, "%.1f", sent / (1024.0 * 1024.0));
                            int pct = size > 0 ? (int) ((sent * 100L) / size) : 100;
                            callback.onProgress("Sending " + name + ": " + sentMb + " / " + totalMb + " MB (" + pct + "%)…");
                        }
                    }
                    out.flush();
                    callback.onProgress("Finalizing " + name + " on " + mac.macName + "…");

                    String reply = readLineAscii(socket.getInputStream());
                    if ("OK".equals(reply)) {
                        callback.onComplete(true, "Sent " + name + " (" + totalMb + " MB) to " + mac.macName + " (Downloads/NearDoc).");
                    } else {
                        callback.onComplete(false, "Mac rejected " + name + " (" + reply + ").");
                    }
                }
            } catch (Exception error) {
                if (transferCancelled) {
                    callback.onComplete(false, "Transfer stopped.");
                } else {
                    callback.onComplete(false, "File send failed: " + describe(error));
                }
            } finally {
                activeTransferSocket = null;
                if (tempCopy != null) tempCopy.delete();
            }
        }, "LinkBridgeFileSend").start();
    }

    static void pollPending(Context context, PairedMac mac, PendingCallback callback) {
        new Thread(() -> {
            try (Socket socket = connect(mac.host, mac.port, 3_500)) {
                String nonce = randomNonce();
                String proof = hmac(mac.token, "PENDING:" + nonce);
                OutputStream out = socket.getOutputStream();
                out.write(("PENDING " + nonce + " " + proof + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
                InputStream in = socket.getInputStream();
                String header = readLineAscii(in);
                if (header == null || "NONE".equals(header)) {
                    callback.onNone();
                    return;
                }
                String[] parts = header.split(" ");
                if (parts.length >= 3 && "CLIP".equals(parts[0])) {
                    int len = Integer.parseInt(parts[2]);
                    byte[] bytes = readExact(in, len);
                    callback.onClipboardReceived(new String(bytes, StandardCharsets.UTF_8));
                } else if (parts.length >= 4 && "FILE".equals(parts[0])) {
                    String fileId = parts[1];
                    String fileName = b64Decode(parts[2]);
                    downloadFileFromMac(context, mac, fileId, fileName, callback);
                } else {
                    callback.onNone();
                }
            } catch (Exception error) {
                callback.onError(describe(error));
            }
        }, "LinkBridgePoll").start();
    }

    private static void downloadFileFromMac(Context context, PairedMac mac, String fileId, String fileName, PendingCallback callback) {
        try (Socket socket = connect(mac.host, mac.port, 15_000)) {
            socket.setSoTimeout(60_000);
            String nonce = randomNonce();
            String proof = hmac(mac.token, "FILE_PULL:" + nonce + ":" + fileId);
            OutputStream out = socket.getOutputStream();
            out.write(("FILE_PULL " + nonce + " " + proof + " " + fileId + "\n").getBytes(StandardCharsets.UTF_8));
            out.flush();

            InputStream in = socket.getInputStream();
            String header = readLineAscii(in);
            if (header == null || !header.startsWith("OK ")) {
                callback.onError("Could not download " + fileName + " (" + header + ").");
                return;
            }
            long totalBytes = Long.parseLong(header.substring(3).trim());
            saveToDownloads(context, fileName, in, totalBytes);
            callback.onFileReceived(fileName);
        } catch (Exception error) {
            callback.onError("Download failed for " + fileName + ": " + describe(error));
        }
    }

    private static void saveToDownloads(Context context, String fileName, InputStream in, long totalBytes) throws IOException {
        ContentResolver resolver = context.getContentResolver();
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, fileName);
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/NearDoc");
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);

        Uri uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        if (uri == null) throw new IOException("Could not create Downloads/NearDoc entry.");

        try (OutputStream out = resolver.openOutputStream(uri)) {
            if (out == null) throw new IOException("Could not open Downloads output stream.");
            byte[] buf = new byte[65_536];
            long remaining = totalBytes;
            while (remaining > 0) {
                int toRead = (int) Math.min(buf.length, remaining);
                int n = in.read(buf, 0, toRead);
                if (n < 0) throw new IOException("Unexpected end of stream.");
                out.write(buf, 0, n);
                remaining -= n;
            }
            out.flush();
        } catch (IOException error) {
            resolver.delete(uri, null, null);
            throw error;
        }

        ContentValues done = new ContentValues();
        done.put(MediaStore.MediaColumns.IS_PENDING, 0);
        resolver.update(uri, done, null, null);
    }

    private static Socket connect(String host, int port, int timeoutMs) throws IOException {
        Socket socket = new Socket();
        socket.connect(new InetSocketAddress(host, port), timeoutMs);
        socket.setSoTimeout(timeoutMs);
        return socket;
    }

    private static String readLineAscii(InputStream in) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int b;
        while ((b = in.read()) != -1) {
            if (b == '\n') break;
            if (b != '\r') buf.write(b);
            if (buf.size() > 16_384) throw new IOException("Header line too long");
        }
        if (b == -1 && buf.size() == 0) return null;
        return new String(buf.toByteArray(), StandardCharsets.UTF_8);
    }

    private static byte[] readExact(InputStream in, int length) throws IOException {
        byte[] result = new byte[length];
        int offset = 0;
        while (offset < length) {
            int n = in.read(result, offset, length - offset);
            if (n < 0) throw new IOException("Unexpected end of stream");
            offset += n;
        }
        return result;
    }

    private static void copyStream(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[65_536];
        int n;
        while ((n = in.read(buf)) != -1) {
            out.write(buf, 0, n);
        }
    }

    private static String queryDisplayName(ContentResolver resolver, Uri uri) {
        try (Cursor cursor = resolver.query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) {
                    String value = cursor.getString(idx);
                    if (value != null && !value.trim().isEmpty()) return value.trim();
                }
            }
        } catch (Exception ignored) { }
        String last = uri.getLastPathSegment();
        return (last == null || last.trim().isEmpty()) ? "shared-file" : last.trim();
    }

    private static long querySize(ContentResolver resolver, Uri uri) {
        try (Cursor cursor = resolver.query(uri, new String[]{OpenableColumns.SIZE}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int idx = cursor.getColumnIndex(OpenableColumns.SIZE);
                if (idx >= 0 && !cursor.isNull(idx)) {
                    long len = cursor.getLong(idx);
                    if (len >= 0) return len;
                }
            }
        } catch (Exception ignored) { }
        try (android.content.res.AssetFileDescriptor afd = resolver.openAssetFileDescriptor(uri, "r")) {
            if (afd != null && afd.getLength() >= 0) return afd.getLength();
        } catch (Exception ignored) { }
        return -1;
    }

    private static String randomNonce() {
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        return hex(bytes);
    }

    private static String hmac(String secret, String value) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        return hex(mac.doFinal(value.getBytes(StandardCharsets.UTF_8)));
    }

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) out.append(String.format(Locale.ROOT, "%02x", value & 0xff));
        return out.toString();
    }

    private static String b64Encode(String text) {
        return Base64.encodeToString(text.getBytes(StandardCharsets.UTF_8), Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
    }

    private static String b64Decode(String value) {
        return new String(Base64.decode(value, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP), StandardCharsets.UTF_8);
    }

    private static String describe(Exception error) {
        return error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage();
    }
}
