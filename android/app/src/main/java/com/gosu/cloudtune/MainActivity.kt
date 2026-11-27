package com.gosu.cloudtune

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.gosu.cloudtune.ui.CloudTuneAppRuntime
import com.gosu.cloudtune.ui.CloudTuneRootApp
import com.gosu.cloudtune.ui.CloudTuneViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val appRuntime = CloudTuneAppRuntime.getOrCreate(applicationContext)
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
            CloudTuneRootApp(viewModel = viewModel)
        }
    }
}
