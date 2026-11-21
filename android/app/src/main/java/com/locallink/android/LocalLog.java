package com.locallink.android;

import android.content.Context;
import java.io.*;
import java.text.SimpleDateFormat;
import java.util.*;

final class LocalLog {
    static synchronized void add(Context context, String message) {
        String row = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date()) + "  " + message + "\n";
        try (FileOutputStream out = new FileOutputStream(new File(context.getFilesDir(), "linkbridge.log"), true)) { out.write(row.getBytes("UTF-8")); }
        catch (IOException ignored) { }
    }
    static String read(Context context) {
        File file = new File(context.getFilesDir(), "linkbridge.log"); if (!file.exists()) return "No diagnostic events yet.";
        try (BufferedReader in = new BufferedReader(new FileReader(file))) { StringBuilder b = new StringBuilder(); String line; while ((line=in.readLine())!=null) b.append(line).append('\n'); return b.toString(); }
        catch (IOException e) { return "Could not read diagnostic log."; }
    }
}
