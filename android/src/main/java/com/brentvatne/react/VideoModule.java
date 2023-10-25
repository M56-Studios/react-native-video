package com.brentvatne.react;

import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

public class VideoModule extends ReactContextBaseJavaModule {

    private static ReactExoplayerView videoView;
    private final ReactApplicationContext reactContext;

    public static void setVideoView(ReactExoplayerView view) {
        videoView = view;
    }

    public VideoModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
    }

    @Override
    public String getName() {
        return "VideoModule";
    }

    @ReactMethod
    public void cleanUpResources() {
        if (videoView != null) {
            videoView.cleanUpResources();
        }
    }
}
