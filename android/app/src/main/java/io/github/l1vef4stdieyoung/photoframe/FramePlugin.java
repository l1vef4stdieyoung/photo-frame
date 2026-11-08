package io.github.l1vef4stdieyoung.photoframe;

import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.view.WindowManager;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;

/**
 * Native helpers the photo frame web page can call through window.Capacitor.nativePromise('Frame', ...).
 */
@CapacitorPlugin(name = "Frame")
public class FramePlugin extends Plugin {

    /** Sets the real backlight brightness for this window. value 0..1, or -1 to follow the system setting. */
    @PluginMethod
    public void setBrightness(PluginCall call) {
        final double v = call.getDouble("value", -1.0);
        getActivity().runOnUiThread(() -> {
            WindowManager.LayoutParams lp = getActivity().getWindow().getAttributes();
            lp.screenBrightness = v < 0 ? WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE : (float) Math.max(0.01, Math.min(1.0, v));
            getActivity().getWindow().setAttributes(lp);
            call.resolve();
        });
    }

    /** Plain HTTP GET done by Android, so web pages' cross-origin rules don't apply. */
    @PluginMethod
    public void httpGet(PluginCall call) {
        final String url = call.getString("url");
        final JSObject headers = call.getObject("headers", new JSObject());
        if (url == null || !(url.startsWith("https://") || url.startsWith("http://"))) {
            call.reject("Invalid URL");
            return;
        }
        new Thread(() -> {
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(15000);
                c.setReadTimeout(25000);
                c.setInstanceFollowRedirects(true);
                c.setRequestProperty("User-Agent", "photo-frame-app/" + version());
                Iterator<String> keys = headers.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    c.setRequestProperty(k, headers.getString(k));
                }
                int code = c.getResponseCode();
                InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream();
                StringBuilder sb = new StringBuilder();
                if (in != null) {
                    try (BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
                        char[] buf = new char[8192];
                        int n;
                        while ((n = r.read(buf)) > 0) sb.append(buf, 0, n);
                    }
                }
                JSObject res = new JSObject();
                res.put("status", code);
                res.put("body", sb.toString());
                call.resolve(res);
            } catch (Exception e) {
                call.reject(e.getMessage() == null ? "Request failed" : e.getMessage());
            } finally {
                if (c != null) c.disconnect();
            }
        }).start();
    }

    /** App version and whether "display over other apps" (needed to start on boot) is allowed. */
    @PluginMethod
    public void getInfo(PluginCall call) {
        JSObject res = new JSObject();
        res.put("version", version());
        res.put("android", Build.VERSION.RELEASE);
        res.put("overlay", Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(getContext()));
        // device details for the setup's device detection
        String model = prop("ro.product.vendor.model");
        if (model.isEmpty()) model = prop("ro.product.odm.model");
        if (model.isEmpty()) model = Build.MODEL;
        String maker = prop("ro.product.vendor.manufacturer");
        if (maker.isEmpty() || "unknown".equalsIgnoreCase(maker)) maker = Build.MANUFACTURER;
        res.put("model", model);
        res.put("manufacturer", maker);
        res.put("soc", Build.VERSION.SDK_INT >= 31 ? Build.SOC_MODEL : Build.HARDWARE);
        res.put("tablet", getContext().getResources().getConfiguration().smallestScreenWidthDp >= 600);
        res.put("cores", Runtime.getRuntime().availableProcessors());
        try {
            ActivityManager am = (ActivityManager) getContext().getSystemService(Context.ACTIVITY_SERVICE);
            ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
            am.getMemoryInfo(mi);
            res.put("ramMb", mi.totalMem / 1048576L);
            res.put("lowRam", am.isLowRamDevice());
        } catch (Exception ignored) { }
        call.resolve(res);
    }

    /** Reads a system property (e.g. the real model on custom Android builds); "" when unavailable. */
    private static String prop(String key) {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            Object v = sp.getMethod("get", String.class).invoke(null, key);
            return v == null ? "" : v.toString().trim();
        } catch (Exception e) {
            return "";
        }
    }

    /** Opens a link outside the app (browser, Spotify login, APK download). */
    @PluginMethod
    public void openUrl(PluginCall call) {
        String url = call.getString("url");
        if (url == null) { call.reject("No URL"); return; }
        try {
            Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            call.resolve();
        } catch (Exception e) {
            call.reject(e.getMessage());
        }
    }

    /** Opens Android's "display over other apps" screen for this app. */
    @PluginMethod
    public void requestOverlay(PluginCall call) {
        try {
            Intent i = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getContext().getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            call.resolve();
        } catch (Exception e) {
            call.reject(e.getMessage());
        }
    }

    /* ---------------- ambient light sensor (for automatic brightness) ---------------- */
    private SensorManager sensors;
    private Sensor lightSensor;
    private SensorEventListener lightListener;
    private volatile float lastLux = -1f;
    private boolean lightWanted = false;

    private void registerLight() {
        if (sensors == null) sensors = (SensorManager) getContext().getSystemService(Context.SENSOR_SERVICE);
        if (sensors == null) return;
        if (lightSensor == null) lightSensor = sensors.getDefaultSensor(Sensor.TYPE_LIGHT);
        if (lightSensor == null || lightListener != null) return;
        lightListener = new SensorEventListener() {
            @Override public void onSensorChanged(SensorEvent e) { lastLux = e.values[0]; }
            @Override public void onAccuracyChanged(Sensor s, int accuracy) { }
        };
        sensors.registerListener(lightListener, lightSensor, SensorManager.SENSOR_DELAY_NORMAL);
    }

    private void unregisterLight() {
        if (sensors != null && lightListener != null) sensors.unregisterListener(lightListener);
        lightListener = null;
    }

    /** Starts listening to the light sensor. Resolves { available, max }. */
    @PluginMethod
    public void startLight(PluginCall call) {
        lightWanted = true;
        registerLight();
        JSObject res = new JSObject();
        res.put("available", lightSensor != null);
        res.put("max", lightSensor != null ? lightSensor.getMaximumRange() : 0);
        call.resolve(res);
    }

    /** Latest reading in lux (-1 until the sensor has reported). */
    @PluginMethod
    public void getLight(PluginCall call) {
        JSObject res = new JSObject();
        res.put("available", lightSensor != null);
        res.put("lux", lastLux);
        call.resolve(res);
    }

    @PluginMethod
    public void stopLight(PluginCall call) {
        lightWanted = false;
        unregisterLight();
        call.resolve();
    }

    /* the sensor only runs while the app is on screen */
    @Override
    protected void handleOnPause() { super.handleOnPause(); unregisterLight(); }

    @Override
    protected void handleOnResume() { super.handleOnResume(); if (lightWanted) registerLight(); }

    private String version() {
        try {
            PackageInfo pi = getContext().getPackageManager().getPackageInfo(getContext().getPackageName(), 0);
            return pi.versionName;
        } catch (Exception e) {
            return "?";
        }
    }
}
