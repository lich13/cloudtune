package com.gosu.cloudtune

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.gosu.cloudtune.ui.CloudTuneAppRuntime
import com.gosu.cloudtune.ui.CloudTuneRootApp
import com.gosu.cloudtune.ui.CloudTuneViewModel

class MainActivity : ComponentActivity() {
    private var isInPipMode by mutableStateOf(false)
    private var runtimeRef: CloudTuneAppRuntime? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val appRuntime = CloudTuneAppRuntime.getOrCreate(applicationContext)
        runtimeRef = appRuntime
        val factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                return CloudTuneViewModel(runtime = appRuntime).also {
                    it.bootstrap()
                } as T
            }
        }
        val viewModel = ViewModelProvider(this, factory)[CloudTuneViewModel::class.java]
        setContent {
            CloudTuneRootApp(
                viewModel = viewModel,
                isInPipMode = isInPipMode,
                onRequestVideoPip = { enterVideoPipMode() }
            )
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        val rt = runtimeRef ?: return
        if (rt.activeVideoUrl != null && rt.isVideoPlaying) {
            enterVideoPipMode()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode = isInPictureInPictureMode
    }

    fun enterVideoPipMode(): Boolean {
        return runCatching {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        }.getOrDefault(false)
    }
}
