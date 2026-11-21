package com.locallink.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.IBinder;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.graphics.PixelFormat;
import android.util.DisplayMetrics;
import android.view.WindowManager;
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;

/**
 * Owns Android's visible screen-capture lifetime. Transport will be attached only after pairing
 * has authenticated a local Mac; this service never opens an arbitrary network socket.
 */
public final class ScreenShareService extends Service {
    static final String ACTION_START = "com.locallink.android.START_SCREEN_SHARE";
    static final String ACTION_STOP = "com.locallink.android.STOP_SCREEN_SHARE";
    static final String EXTRA_RESULT_CODE = "result_code";
    static final String EXTRA_RESULT_DATA = "result_data";
    private static final String CHANNEL_ID = "screen_share";
    private MediaProjection projection;
    private Socket socket; private DataOutputStream output; private ImageReader reader; private VirtualDisplay display;
    private android.os.HandlerThread captureThread;

    @Override public void onCreate() {
        super.onCreate();
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "Screen sharing", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Shown while Local Link is allowed to capture the screen.");
        getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || ACTION_STOP.equals(intent.getAction())) { stopSharing(); return START_NOT_STICKY; }
        if (!ACTION_START.equals(intent.getAction())) return START_NOT_STICKY;
        startForeground(11, activeNotification());
        MediaProjectionManager manager = (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        Intent result = intent.getParcelableExtra(EXTRA_RESULT_DATA);
        projection = manager.getMediaProjection(intent.getIntExtra(EXTRA_RESULT_CODE, 0), result);
        if (projection == null) { stopSharing(); return START_NOT_STICKY; }
        LocalLog.add(this, "Screen-share consent granted");
        projection.registerCallback(new MediaProjection.Callback() {
            @Override public void onStop() { stopSharing(); }
        }, null);
        String host = getSharedPreferences("pairing", MODE_PRIVATE).getString("host", null);
        String session = getSharedPreferences("pairing", MODE_PRIVATE).getString("session", null);
        if (host == null || session == null) { stopSharing(); return START_NOT_STICKY; }
        new Thread(() -> stream(host, session), "LocalLinkStream").start();
        return START_NOT_STICKY;
    }

    private void stream(String host, String session) {
        try {
            socket = new Socket(); socket.connect(new InetSocketAddress(host, 39873), 8000); socket.setTcpNoDelay(true);
            BufferedReader input = new BufferedReader(new InputStreamReader(socket.getInputStream(), "UTF-8"));
            output = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));
            // Screen media only begins after the receiver proves possession of the pairing secret.
            output.write(("LLS1 " + session + "\n").getBytes("UTF-8")); output.flush();
            if (!"OK".equals(input.readLine())) throw new IOException("Mac rejected session");
            int w = Math.min(960, getResources().getDisplayMetrics().widthPixels);
            int h = getResources().getDisplayMetrics().heightPixels * w / getResources().getDisplayMetrics().widthPixels;
            int density = getResources().getDisplayMetrics().densityDpi;
            reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2);
            captureThread = new android.os.HandlerThread("LinkBridgeCapture"); captureThread.start();
            reader.setOnImageAvailableListener(r -> {
                Image image = null;
                try {
                    image = r.acquireLatestImage(); if (image == null) return;
                    Image.Plane plane = image.getPlanes()[0]; ByteBuffer pixels = plane.getBuffer();
                    int stride = plane.getRowStride(), pixel = plane.getPixelStride();
                    android.graphics.Bitmap bitmap = android.graphics.Bitmap.createBitmap(w, h, android.graphics.Bitmap.Config.ARGB_8888);
                    int[] colors = new int[w*h];
                    for (int y=0;y<h;y++) for(int x=0;x<w;x++){int i=y*stride+x*pixel; int rr=pixels.get(i)&255,gg=pixels.get(i+1)&255,bb=pixels.get(i+2)&255,aa=pixels.get(i+3)&255;colors[y*w+x]=android.graphics.Color.argb(aa,rr,gg,bb);}
                    bitmap.setPixels(colors,0,w,0,0,w,h); ByteArrayOutputStream bytes=new ByteArrayOutputStream(); bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG,55,bytes); bitmap.recycle(); byte[] frame=bytes.toByteArray();
                    synchronized(this){if(output!=null){output.writeInt(frame.length);output.write(frame);output.flush();}}
                } catch(Exception e){LocalLog.add(this, "Frame send failed: " + e.getMessage());stopSharing();} finally {if(image!=null) image.close();}
            }, new android.os.Handler(captureThread.getLooper()));
            display=projection.createVirtualDisplay("LocalLink",w,h,density,DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,reader.getSurface(),null,null);
            LocalLog.add(this, "Full-display capture started at " + w + "x" + h);
        } catch(Exception e){LocalLog.add(this, "Screen stream failed: " + e.getClass().getSimpleName() + ": " + e.getMessage());stopSharing();}
    }

    private Notification activeNotification() {
        Intent stop = new Intent(this, ScreenShareService.class).setAction(ACTION_STOP);
        android.app.PendingIntent pendingStop = android.app.PendingIntent.getService(this, 0, stop,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT | android.app.PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Local Link screen sharing is active")
            .setContentText("Your screen is being sent to the paired Mac. Tap Stop to end.")
            .addAction(new Notification.Action.Builder(null, "Stop", pendingStop).build())
            .setOngoing(true)
            .build();
    }

    private synchronized void stopSharing() {
        MediaProjection current = projection; projection = null;
        try { if(display!=null) display.release(); } catch(Exception ignored){} display=null;
        try { if(reader!=null) reader.close(); } catch(Exception ignored){} reader=null;
        try { if(socket!=null) socket.close(); } catch(Exception ignored){} socket=null; output=null;
        if(captureThread!=null){captureThread.quitSafely();captureThread=null;}
        if (current != null) current.stop();
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
