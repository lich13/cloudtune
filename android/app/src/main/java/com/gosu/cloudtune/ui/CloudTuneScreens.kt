package com.gosu.cloudtune.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.MediaRouter2
import android.os.Build
import android.provider.Settings
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.activity.compose.PredictiveBackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.PlayerView
import com.gosu.cloudtune.core.AppearanceMode
import com.gosu.cloudtune.core.BreadcrumbItem
import com.gosu.cloudtune.core.BrowserPaneState
import com.gosu.cloudtune.core.BrowserScope
import com.gosu.cloudtune.core.Cloud189Constants
import com.gosu.cloudtune.core.Cloud189Protocol
import com.gosu.cloudtune.core.CloudTuneFormatters
import com.gosu.cloudtune.core.LoopMode
import com.gosu.cloudtune.core.ModuleTab
import com.gosu.cloudtune.core.PlaybackMode
import com.gosu.cloudtune.core.TrackSummary
import java.util.Locale
import kotlinx.coroutines.CancellationException

private val TabularNumStyle = TextStyle(fontFeatureSettings = "tnum")
private val PhonePrimaryTabs = listOf(ModuleTab.MUSIC, ModuleTab.VIDEO, ModuleTab.CLOUD, ModuleTab.TRANSFERS)

@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
private fun showMediaRouter2SystemOutputSwitcher(context: Context): Boolean {
    return runCatching {
        MediaRouter2.getInstance(context).showSystemOutputSwitcher()
    }.getOrDefault(false)
}

private fun openSystemAudioOutputSwitcher(context: Context, runtime: CloudTuneAppRuntime) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        if (showMediaRouter2SystemOutputSwitcher(context)) return
    }
    val candidates = listOf(
        Intent("com.android.settings.panel.action.MEDIA_OUTPUT").apply {
            putExtra("com.android.settings.panel.extra.PACKAGE_NAME", context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        },
        Intent(Settings.Panel.ACTION_VOLUME).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        },
        Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    )
    for (intent in candidates) {
        if (runCatching { context.startActivity(intent) }.isSuccess) {
            return
        }
    }
    runtime.setStatus("无法打开音频输出切换面板，请在系统控制中心切换蓝牙或扬声器。", StatusKind.ERROR)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudTuneRootApp(
    viewModel: CloudTuneViewModel,
    isInPipMode: Boolean = false,
    onRequestVideoPip: () -> Unit = {}
) {
    val runtime = viewModel.runtime
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, runtime) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> runtime.setUiForegroundVisible(true)
                Lifecycle.Event.ON_STOP -> runtime.setUiForegroundVisible(false)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    val systemDark = isSystemInDarkTheme()
    val useDark = when (runtime.themeMode) {
        AppearanceMode.LIGHT -> false
        AppearanceMode.DARK -> true
        AppearanceMode.SYSTEM -> systemDark
    }
    val isTablet = LocalConfiguration.current.screenWidthDp >= 600

    CloudTuneTheme(
        darkTheme = useDark,
        dynamicColor = runtime.dynamicColorEnabled
    ) {
        val colors = LocalCloudTuneColors.current
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(colors.canvas)
        ) {
            if (isInPipMode && runtime.activeVideoUrl != null) {
                InAppVideoOverlay(
                    runtime = runtime,
                    isInPipMode = true,
                    onRequestPip = onRequestVideoPip
                )
            } else {
                if (!runtime.isAuthenticated) {
                    LoginStageScreen(runtime)
                } else if (isTablet) {
                    TabletWorkspaceScaffold(runtime)
                } else {
                    PhoneWorkspaceScaffold(runtime)
                }

                if (runtime.isShowingNowPlayingSheet && runtime.isAuthenticated) {
                    if (runtime.enableLiveLoops) {
                        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
                        ModalBottomSheet(
                            onDismissRequest = { runtime.isShowingNowPlayingSheet = false },
                            sheetState = sheetState,
                            containerColor = colors.surface
                        ) {
                            NowPlayingFullSheetContent(
                                runtime = runtime,
                                applySystemInsets = false,
                                onCollapse = { runtime.isShowingNowPlayingSheet = false }
                            )
                        }
                    } else {
                        Surface(
                            modifier = Modifier.fillMaxSize(),
                            color = colors.surface
                        ) {
                            NowPlayingFullSheetContent(
                                runtime = runtime,
                                applySystemInsets = true,
                                onCollapse = { runtime.isShowingNowPlayingSheet = false }
                            )
                        }
                    }
                }

                if (runtime.isShowingWebLoginDialog) {
                    TianyiOfficialWebLoginDialog(runtime)
                }

                if (runtime.activeVideoUrl != null) {
                    InAppVideoOverlay(
                        runtime = runtime,
                        isInPipMode = false,
                        onRequestPip = onRequestVideoPip
                    )
                }

                runtime.pendingExternalVideoAction?.let { pending ->
                    AlertDialog(
                        onDismissRequest = { runtime.pendingExternalVideoAction = null },
                        title = { Text("外部播放器打开", fontWeight = FontWeight.Bold) },
                        text = {
                            Text("该视频尚未完整缓存至本地。您可以先缓存至本地以获得最佳兼容性，或将本地代理流交给已安装的视频播放器。")
                        },
                        confirmButton = {
                            TextButton(onClick = {
                                runtime.downloadVideoAndOpenExternally(context, pending.video)
                            }) {
                                Text("先缓存再打开")
                            }
                        },
                        dismissButton = {
                            Row {
                                if (pending.streamUrl != null) {
                                    TextButton(onClick = {
                                        runtime.launchLoopbackStreamInVideoApp(context, pending)
                                    }) {
                                        Text("直接串流打开")
                                    }
                                }
                                TextButton(onClick = { runtime.pendingExternalVideoAction = null }) {
                                    Text("取消")
                                }
                            }
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun PineActionButton(
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    Box(
        modifier = modifier
            .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (enabled) colors.accent else colors.accent.copy(alpha = 0.45f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            color = colors.accentForeground,
            fontSize = 13.5.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

@Composable
private fun NeutralOutlineButton(
    text: String,
    modifier: Modifier = Modifier,
    isActive: Boolean = false,
    onClick: () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    val bg = if (isActive) colors.rowActiveSurface else colors.surfaceSecondary
    val border = if (isActive) colors.rowActiveBorder else colors.separator
    val fg = if (isActive) colors.accent else colors.inkPrimary
    Box(
        modifier = modifier
            .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(bg)
            .border(1.dp, border, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            color = fg,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

@Composable
private fun LosslessTag(track: TrackSummary?) {
    if (track == null || !track.isLosslessAudio) return
    val colors = LocalCloudTuneColors.current
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(colors.accentSoft)
            .padding(horizontal = 7.dp, vertical = 2.dp)
    ) {
        Text(
            text = track.fileExtensionUpper,
            color = colors.accent,
            fontSize = 10.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold
        )
    }
}

@Composable
private fun MineralArtworkCover(
    bitmap: android.graphics.Bitmap?,
    seedText: String,
    size: Dp,
    cornerRadius: Dp = 12.dp
) {
    val colors = LocalCloudTuneColors.current
    val shape = RoundedCornerShape(cornerRadius)
    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(size)
                .clip(shape)
                .border(0.5.dp, colors.separator, shape)
        )
    } else {
        val bucket = (seedText.hashCode() and 0x7FFFFFFF) % 4
        val tonePair = if (colors.isDark) {
            when (bucket) {
                0 -> Color(0xFF223730) to Color(0xFF172526)
                1 -> Color(0xFF232F3A) to Color(0xFF171E28)
                2 -> Color(0xFF2C302D) to Color(0xFF1C2020)
                else -> Color(0xFF243433) to Color(0xFF182224)
            }
        } else {
            when (bucket) {
                0 -> Color(0xFFDCEBE6) to Color(0xFFCCE0DA)
                1 -> Color(0xFFDDE5EE) to Color(0xFFCFD9E6)
                2 -> Color(0xFFE4E7E3) to Color(0xFFD6DBD5)
                else -> Color(0xFFD9E7E5) to Color(0xFFCADCD9)
            }
        }
        Box(
            modifier = Modifier
                .size(size)
                .clip(shape)
                .background(Brush.linearGradient(listOf(tonePair.first, tonePair.second)))
                .border(0.5.dp, colors.separator, shape),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                val rOuter = this.size.minDimension * 0.32f
                val rInner = this.size.minDimension * 0.19f
                drawCircle(
                    color = colors.accent.copy(alpha = if (colors.isDark) 0.34f else 0.24f),
                    radius = rOuter,
                    style = Stroke(width = 2.dp.toPx())
                )
                drawCircle(
                    color = colors.accent.copy(alpha = if (colors.isDark) 0.22f else 0.16f),
                    radius = rInner,
                    style = Stroke(width = 1.dp.toPx())
                )
            }
            Icon(
                imageVector = AppIcons.Music,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(size * 0.36f)
            )
        }
    }
}

@Composable
private fun InteractivePlayerSlider(
    currentTime: Double,
    duration: Double,
    onScrubStateChanged: (Boolean) -> Unit,
    onSeekCommitted: (Double) -> Unit
) {
    val colors = LocalCloudTuneColors.current
    val safeDuration = duration.takeIf { it.isFinite() && it > 0.0 } ?: 0.0
    var scrubbingValue by remember { mutableStateOf<Float?>(null) }
    val shownSeconds = scrubbingValue?.toDouble() ?: currentTime.coerceIn(0.0, maxOf(0.0, safeDuration))

    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Slider(
            value = if (safeDuration > 0.0) shownSeconds.toFloat().coerceIn(0f, safeDuration.toFloat()) else 0f,
            onValueChange = { next ->
                if (safeDuration > 0.0) {
                    scrubbingValue = next
                    onScrubStateChanged(true)
                }
            },
            onValueChangeFinished = {
                val target = scrubbingValue?.toDouble()
                scrubbingValue = null
                onScrubStateChanged(false)
                if (target != null && safeDuration > 0.0) {
                    onSeekCommitted(target)
                }
            },
            valueRange = 0f..(if (safeDuration > 0.0) safeDuration.toFloat() else 1f),
            enabled = safeDuration > 0.0,
            colors = SliderDefaults.colors(
                thumbColor = colors.accent,
                activeTrackColor = colors.accent,
                inactiveTrackColor = colors.inkPrimary.copy(alpha = 0.12f)
            )
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                CloudTuneFormatters.formatClock(shownSeconds),
                style = TabularNumStyle,
                color = colors.inkTertiary,
                fontSize = 11.5.sp
            )
            Text(
                CloudTuneFormatters.formatClock(safeDuration),
                style = TabularNumStyle,
                color = colors.inkTertiary,
                fontSize = 11.5.sp
            )
        }
    }
}

@Composable
private fun StatusNoticeBanner(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    val validationErr = runtime.settingsValidationError?.takeIf { it.isNotBlank() }
    val busy = runtime.busyLabel?.takeIf { it.isNotBlank() }
    val status = runtime.statusMessage?.takeIf { it.isNotBlank() }
    val rawMsg = validationErr ?: busy ?: status ?: return
    val isError = validationErr != null || (busy == null && runtime.statusKind == StatusKind.ERROR)

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = if (isError) colors.destructive.copy(alpha = if (colors.isDark) 0.18f else 0.10f) else colors.noticeBackground,
        border = BorderStroke(1.dp, if (isError) colors.destructive.copy(alpha = 0.35f) else colors.rowActiveBorder.copy(alpha = 0.4f))
    ) {
        Text(
            text = rawMsg,
            color = colors.inkPrimary,
            fontSize = 12.5.sp,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp)
        )
    }
}

@Composable
private fun LoginStageScreen(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    val safeInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(safeInsets)
            .imePadding(),
        contentAlignment = Alignment.Center
    ) {
        LazyColumn(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .fillMaxWidth(),
            contentPadding = PaddingValues(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            item {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    MineralArtworkCover(bitmap = null, seedText = "CloudTune", size = 56.dp, cornerRadius = 16.dp)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "CloudTune",
                        color = colors.inkPrimary,
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        "连接天翼云盘，串流与缓存无损音乐与现场视频",
                        color = colors.inkSecondary,
                        fontSize = 13.5.sp,
                        textAlign = TextAlign.Center
                    )
                }
            }

            if (!(runtime.statusMessage ?: runtime.busyLabel).isNullOrBlank()) {
                item { StatusNoticeBanner(runtime) }
            }

            item {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(18.dp),
                    color = colors.surface,
                    border = BorderStroke(1.dp, colors.separator)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(20.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        // Fixed #F6F1E8 substrate + #13271F foreground across light & dark themes
                        Box(
                            modifier = Modifier
                                .size(212.dp)
                                .clip(RoundedCornerShape(16.dp))
                                .background(colors.qrSubstrate)
                                .border(1.dp, colors.separator, RoundedCornerShape(16.dp))
                                .padding(12.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            val bmp = runtime.qrBitmap
                            if (bmp != null) {
                                Image(
                                    bitmap = bmp.asImageBitmap(),
                                    contentDescription = "天翼云盘二维码",
                                    modifier = Modifier.fillMaxSize()
                                )
                            } else {
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Icon(
                                        AppIcons.QrCode,
                                        contentDescription = null,
                                        tint = colors.qrForeground,
                                        modifier = Modifier.size(48.dp)
                                    )
                                    Spacer(Modifier.height(6.dp))
                                    Text("扫码二维码将在此显示", color = colors.qrForeground, fontSize = 12.sp)
                                }
                            }
                        }

                        runtime.qrHint?.takeIf { it.isNotBlank() }?.let { hint ->
                            Text(hint, color = colors.inkSecondary, fontSize = 12.5.sp, textAlign = TextAlign.Center)
                        }

                        PineActionButton(
                            text = "天翼官方网页一键登录",
                            modifier = Modifier.fillMaxWidth(),
                            onClick = { runtime.isShowingWebLoginDialog = true }
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            NeutralOutlineButton(
                                text = if (runtime.qrBitmap != null) "刷新二维码" else "生成扫码二维码",
                                modifier = Modifier.weight(1f),
                                onClick = { runtime.beginQrLogin() }
                            )
                            if (runtime.qrBitmap != null) {
                                NeutralOutlineButton(
                                    text = "保存到相册",
                                    modifier = Modifier.weight(1f),
                                    onClick = { runtime.saveQrToGallery(context) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PhoneWorkspaceScaffold(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    var settingsBackProgress by remember { mutableFloatStateOf(0f) }

    PredictiveBackHandler(
        enabled = runtime.activeModule == ModuleTab.SETTINGS &&
            runtime.activeVideoUrl == null &&
            !runtime.isShowingNowPlayingSheet
    ) { progress ->
        try {
            progress.collect { event ->
                settingsBackProgress = event.progress
            }
            settingsBackProgress = 0f
            runtime.activeModule = ModuleTab.MUSIC
        } catch (_: CancellationException) {
            settingsBackProgress = 0f
        }
    }

    Scaffold(
        containerColor = colors.canvas,
        contentWindowInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout),
        topBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colors.surface)
                    .windowInsetsPadding(WindowInsets.statusBars.union(WindowInsets.displayCutout))
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp)
                        .padding(horizontal = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (runtime.activeModule == ModuleTab.SETTINGS) {
                        IconButton(
                            onClick = { runtime.activeModule = ModuleTab.MUSIC },
                            modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                        ) {
                            Icon(AppIcons.ArrowBack, contentDescription = "返回", tint = colors.inkPrimary)
                        }
                    } else {
                        Spacer(Modifier.width(8.dp))
                    }

                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = runtime.activeModule.title,
                            color = colors.inkPrimary,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1
                        )
                        val sub = when (runtime.activeModule) {
                            ModuleTab.MUSIC -> "${runtime.committedSettings.musicFolder?.name ?: "未设曲库"} · ${runtime.tracks.size} 首"
                            ModuleTab.VIDEO -> runtime.videoBrowser.payload?.currentFolderName ?: "我的云盘"
                            ModuleTab.CLOUD -> runtime.cloudBrowser.payload?.currentFolderName ?: "我的云盘"
                            ModuleTab.TRANSFERS -> "${CloudTuneFormatters.formatBytes(runtime.transferSnapshot.totalSpeedBytesPerSecond)}/s"
                            ModuleTab.SETTINGS -> runtime.accountName ?: "已连接"
                        }
                        Text(
                            text = sub,
                            style = TabularNumStyle,
                            color = colors.inkTertiary,
                            fontSize = 11.5.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }

                    if (runtime.activeModule != ModuleTab.SETTINGS) {
                        IconButton(
                            onClick = { runtime.activeModule = ModuleTab.SETTINGS },
                            modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                        ) {
                            Icon(AppIcons.Settings, contentDescription = "设置", tint = colors.inkSecondary)
                        }
                    }
                }
                HorizontalDivider(color = colors.separator)
            }
        },
        bottomBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colors.surface)
                    .windowInsetsPadding(
                        WindowInsets.navigationBars.union(
                            WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal)
                        )
                    )
            ) {
                MiniPlayerBar(
                    runtime = runtime,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                )
                HorizontalDivider(color = colors.separator)
                NavigationBar(
                    containerColor = colors.surface,
                    tonalElevation = 0.dp,
                    windowInsets = WindowInsets(0, 0, 0, 0)
                ) {
                    PhonePrimaryTabs.forEach { tab ->
                        val icon = when (tab) {
                            ModuleTab.MUSIC -> AppIcons.Music
                            ModuleTab.VIDEO -> AppIcons.Video
                            ModuleTab.CLOUD -> AppIcons.Cloud
                            ModuleTab.TRANSFERS -> AppIcons.Transfers
                            ModuleTab.SETTINGS -> AppIcons.Settings
                        }
                        NavigationBarItem(
                            selected = runtime.activeModule == tab,
                            onClick = { runtime.activeModule = tab },
                            icon = { Icon(icon, contentDescription = tab.title) },
                            label = { Text(tab.title, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold) },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = colors.accent,
                                selectedTextColor = colors.accent,
                                indicatorColor = colors.accentSoft,
                                unselectedIconColor = colors.inkSecondary,
                                unselectedTextColor = colors.inkSecondary
                            )
                        )
                    }
                }
            }
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding)
                .fillMaxSize()
                .imePadding()
                .graphicsLayer {
                    if (runtime.activeModule == ModuleTab.SETTINGS) {
                        translationX = settingsBackProgress * 28.dp.toPx()
                        alpha = 1f - settingsBackProgress * 0.08f
                    }
                }
        ) {
            ActiveModuleContent(runtime)
        }
    }
}

@Composable
private fun TabletWorkspaceScaffold(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    val railInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout)
        .only(WindowInsetsSides.Vertical + WindowInsetsSides.Start)
    val contentInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout)
        .only(WindowInsetsSides.Vertical + WindowInsetsSides.End)

    Row(modifier = Modifier.fillMaxSize()) {
        NavigationRail(
            containerColor = colors.surface,
            windowInsets = railInsets
        ) {
            Spacer(Modifier.height(12.dp))
            ModuleTab.entries.forEach { tab ->
                val icon = when (tab) {
                    ModuleTab.MUSIC -> AppIcons.Music
                    ModuleTab.VIDEO -> AppIcons.Video
                    ModuleTab.CLOUD -> AppIcons.Cloud
                    ModuleTab.TRANSFERS -> AppIcons.Transfers
                    ModuleTab.SETTINGS -> AppIcons.Settings
                }
                NavigationRailItem(
                    selected = runtime.activeModule == tab,
                    onClick = { runtime.activeModule = tab },
                    icon = { Icon(icon, contentDescription = tab.title) },
                    label = { Text(tab.title, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold) }
                )
            }
        }

        Box(
            modifier = Modifier
                .width(1.dp)
                .fillMaxHeight()
                .background(colors.separator)
        )

        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .windowInsetsPadding(contentInsets)
                .imePadding()
        ) {
            Column(
                modifier = Modifier
                    .weight(0.62f)
                    .fillMaxHeight()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colors.surface)
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = runtime.activeModule.title,
                        color = colors.inkPrimary,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f)
                    )
                    Text(
                        text = "${runtime.accountName ?: ""} · 缓存 ${CloudTuneFormatters.formatBytes(runtime.cacheUsageBytes)}",
                        style = TabularNumStyle,
                        color = colors.inkTertiary,
                        fontSize = 12.sp
                    )
                }
                HorizontalDivider(color = colors.separator)
                Box(modifier = Modifier.weight(1f)) {
                    ActiveModuleContent(runtime)
                }
            }

            Box(
                modifier = Modifier
                    .width(1.dp)
                    .fillMaxHeight()
                    .background(colors.separator)
            )

            TabletNowPlayingQueuePane(
                runtime = runtime,
                modifier = Modifier
                    .weight(0.38f)
                    .fillMaxHeight()
                    .background(colors.surface)
            )
        }
    }
}

@Composable
private fun ActiveModuleContent(runtime: CloudTuneAppRuntime) {
    when (runtime.activeModule) {
        ModuleTab.MUSIC -> MusicLibraryContent(runtime)
        ModuleTab.VIDEO -> VideoWorkspaceContent(runtime)
        ModuleTab.CLOUD -> CloudBrowserContent(runtime)
        ModuleTab.TRANSFERS -> TransfersWorkspaceContent(runtime)
        ModuleTab.SETTINGS -> SettingsWorkspaceContent(runtime)
    }
}

@Composable
private fun MiniPlayerBar(runtime: CloudTuneAppRuntime, modifier: Modifier = Modifier) {
    val colors = LocalCloudTuneColors.current
    val track = runtime.currentTrack
    val title = runtime.nowPlayingTitle ?: track?.name ?: "选择曲目开始播放"
    val subtitle = runtime.nowPlayingArtist
        ?: runtime.nowPlayingAlbum
        ?: track?.folderPath
        ?: "${CloudTuneFormatters.formatClock(runtime.currentTime)} / ${CloudTuneFormatters.formatClock(runtime.duration)}"
    val pct = if (runtime.duration > 0.0) {
        (runtime.currentTime / runtime.duration).coerceIn(0.0, 1.0).toFloat()
    } else 0f

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .clickable { runtime.isShowingNowPlayingSheet = true },
        shape = RoundedCornerShape(14.dp),
        color = colors.surfaceElevated,
        border = BorderStroke(1.dp, colors.separator)
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 10.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                MineralArtworkCover(
                    bitmap = runtime.nowPlayingArtwork,
                    seedText = title,
                    size = 40.dp,
                    cornerRadius = 10.dp
                )
                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = title,
                            color = colors.inkPrimary,
                            fontSize = 13.5.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        LosslessTag(track)
                    }
                    Text(
                        text = subtitle,
                        style = TabularNumStyle,
                        color = colors.inkTertiary,
                        fontSize = 11.5.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                IconButton(
                    onClick = { runtime.togglePlayback() },
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(colors.accent),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            if (runtime.isPlaying) AppIcons.Pause else AppIcons.Play,
                            contentDescription = if (runtime.isPlaying) "暂停" else "播放",
                            tint = colors.accentForeground,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }

                IconButton(
                    onClick = { runtime.playAdjacent(1) },
                    enabled = runtime.canSkipNext,
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Icon(
                        AppIcons.SkipNext,
                        contentDescription = "下一首",
                        tint = if (runtime.canSkipNext) colors.inkPrimary else colors.inkTertiary.copy(alpha = 0.45f),
                        modifier = Modifier.size(20.dp)
                    )
                }
            }
            if (runtime.duration > 0.0) {
                LinearProgressIndicator(
                    progress = { pct },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(2.dp),
                    color = colors.accent,
                    trackColor = Color.Transparent
                )
            }
        }
    }
}

@Composable
private fun NowPlayingFullSheetContent(
    runtime: CloudTuneAppRuntime,
    applySystemInsets: Boolean = true,
    onCollapse: () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    val track = runtime.currentTrack
    val title = runtime.nowPlayingTitle ?: track?.name ?: "未选择曲目"
    val artistLine = listOfNotNull(
        runtime.nowPlayingArtist?.takeIf { it.isNotBlank() },
        (runtime.nowPlayingAlbum ?: track?.folderPath)?.takeIf { it.isNotBlank() }
    ).joinToString(" · ").ifBlank { "CloudTune" }
    val safeInsets = WindowInsets.systemBars.union(WindowInsets.displayCutout)
    val listModifier = if (applySystemInsets) {
        Modifier.fillMaxSize().windowInsetsPadding(safeInsets)
    } else {
        Modifier.fillMaxSize()
    }

    LazyColumn(
        modifier = listModifier,
        contentPadding = PaddingValues(horizontal = 22.dp, vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                    onClick = onCollapse,
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Icon(AppIcons.ChevronDown, contentDescription = "收起", tint = colors.inkPrimary)
                }
                Text(
                    "正在播放",
                    color = colors.inkSecondary,
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f)
                )
                IconButton(
                    onClick = { openSystemAudioOutputSwitcher(context, runtime) },
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Icon(AppIcons.SpeakerWave, contentDescription = "音频输出设备", tint = colors.inkPrimary)
                }
            }
        }

        item {
            MineralArtworkCover(
                bitmap = runtime.nowPlayingArtwork,
                seedText = title,
                size = 216.dp,
                cornerRadius = 24.dp
            )
        }

        item {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        text = title,
                        color = colors.inkPrimary,
                        fontSize = 19.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 2,
                        textAlign = TextAlign.Center,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    LosslessTag(track)
                }
                Text(
                    text = artistLine,
                    color = colors.inkSecondary,
                    fontSize = 13.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        item {
            InteractivePlayerSlider(
                currentTime = runtime.currentTime,
                duration = runtime.duration,
                onScrubStateChanged = { runtime.isUserScrubbing = it },
                onSeekCommitted = { runtime.seekTo(it) }
            )
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                    onClick = { runtime.toggleShuffle() },
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Icon(
                        AppIcons.Shuffle,
                        contentDescription = "随机播放",
                        tint = if (runtime.shuffle) colors.accent else colors.inkTertiary
                    )
                }
                IconButton(
                    onClick = { runtime.playAdjacent(-1) },
                    enabled = runtime.canSkipPrevious,
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Icon(
                        AppIcons.SkipPrevious,
                        contentDescription = "上一首",
                        tint = if (runtime.canSkipPrevious) colors.inkPrimary else colors.inkTertiary.copy(alpha = 0.4f),
                        modifier = Modifier.size(28.dp)
                    )
                }
                Box(
                    modifier = Modifier
                        .size(60.dp)
                        .clip(CircleShape)
                        .background(colors.accent)
                        .clickable { runtime.togglePlayback() },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        if (runtime.isPlaying) AppIcons.Pause else AppIcons.Play,
                        contentDescription = if (runtime.isPlaying) "暂停" else "播放",
                        tint = colors.accentForeground,
                        modifier = Modifier.size(28.dp)
                    )
                }
                IconButton(
                    onClick = { runtime.playAdjacent(1) },
                    enabled = runtime.canSkipNext,
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Icon(
                        AppIcons.SkipNext,
                        contentDescription = "下一首",
                        tint = if (runtime.canSkipNext) colors.inkPrimary else colors.inkTertiary.copy(alpha = 0.4f),
                        modifier = Modifier.size(28.dp)
                    )
                }
                val loopLabel = when (runtime.loopMode) {
                    LoopMode.OFF -> "不循环"
                    LoopMode.ALL -> "列表"
                    LoopMode.ONE -> "单曲"
                }
                NeutralOutlineButton(
                    text = loopLabel,
                    isActive = runtime.loopMode != LoopMode.OFF,
                    onClick = { runtime.cycleLoopMode() }
                )
            }
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "待播队列 (${runtime.upcomingTracks.size})",
                    style = TabularNumStyle,
                    color = colors.inkPrimary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f)
                )
                if (runtime.upNextQueue.isNotEmpty()) {
                    TextButton(onClick = { runtime.clearUpNextQueue() }) {
                        Text("清空插播", color = colors.accent, fontSize = 12.5.sp)
                    }
                }
            }
        }

        items(runtime.upcomingTracks, key = { "sheet-q-${it.id}" }) { upcoming ->
            val isManualUpNext = runtime.upNextQueue.any { it.id == upcoming.id }
            TrackListRow(
                track = upcoming,
                isActive = false,
                trailingLabel = if (isManualUpNext) "插播" else "待播",
                onPlay = { runtime.playFromUpcomingQueue(upcoming) },
                onPlayNext = if (isManualUpNext) ({ runtime.removeFromQueue(upcoming.id) }) else ({ runtime.playNext(upcoming) }),
                playNextActionTitle = if (isManualUpNext) "移出插播" else "下一首"
            )
        }
    }
}

@Composable
private fun TabletNowPlayingQueuePane(
    runtime: CloudTuneAppRuntime,
    modifier: Modifier = Modifier
) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    val track = runtime.currentTrack
    val title = runtime.nowPlayingTitle ?: track?.name ?: "未选择曲目"
    val subtitle = listOfNotNull(
        runtime.nowPlayingArtist?.takeIf { it.isNotBlank() },
        (runtime.nowPlayingAlbum ?: track?.folderPath)?.takeIf { it.isNotBlank() }
    ).joinToString(" · ").ifBlank { "选择左侧曲目即可播放" }

    Column(
        modifier = modifier.padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(14.dp))
                    .clickable(onClickLabel = "展开正在播放详情") { runtime.isShowingNowPlayingSheet = true },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                MineralArtworkCover(
                    bitmap = runtime.nowPlayingArtwork,
                    seedText = title,
                    size = 64.dp,
                    cornerRadius = 14.dp
                )
                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = title,
                            color = colors.inkPrimary,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        LosslessTag(track)
                    }
                    Text(
                        text = subtitle,
                        color = colors.inkSecondary,
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            IconButton(
                onClick = { openSystemAudioOutputSwitcher(context, runtime) },
                modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            ) {
                Icon(AppIcons.SpeakerWave, contentDescription = "音频输出", tint = colors.inkSecondary)
            }
        }

        InteractivePlayerSlider(
            currentTime = runtime.currentTime,
            duration = runtime.duration,
            onScrubStateChanged = { runtime.isUserScrubbing = it },
            onSeekCommitted = { runtime.seekTo(it) }
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(
                onClick = { runtime.toggleShuffle() },
                modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            ) {
                Icon(
                    AppIcons.Shuffle,
                    contentDescription = "随机",
                    tint = if (runtime.shuffle) colors.accent else colors.inkTertiary
                )
            }
            IconButton(
                onClick = { runtime.playAdjacent(-1) },
                enabled = runtime.canSkipPrevious,
                modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            ) {
                Icon(
                    AppIcons.SkipPrevious,
                    contentDescription = "上一首",
                    tint = if (runtime.canSkipPrevious) colors.inkPrimary else colors.inkTertiary.copy(alpha = 0.4f)
                )
            }
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(colors.accent)
                    .clickable { runtime.togglePlayback() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    if (runtime.isPlaying) AppIcons.Pause else AppIcons.Play,
                    contentDescription = if (runtime.isPlaying) "暂停" else "播放",
                    tint = colors.accentForeground,
                    modifier = Modifier.size(22.dp)
                )
            }
            IconButton(
                onClick = { runtime.playAdjacent(1) },
                enabled = runtime.canSkipNext,
                modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            ) {
                Icon(
                    AppIcons.SkipNext,
                    contentDescription = "下一首",
                    tint = if (runtime.canSkipNext) colors.inkPrimary else colors.inkTertiary.copy(alpha = 0.4f)
                )
            }
            val loopText = when (runtime.loopMode) {
                LoopMode.OFF -> "不循环"
                LoopMode.ALL -> "列表"
                LoopMode.ONE -> "单曲"
            }
            NeutralOutlineButton(
                text = loopText,
                isActive = runtime.loopMode != LoopMode.OFF,
                onClick = { runtime.cycleLoopMode() }
            )
        }

        HorizontalDivider(color = colors.separator)

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "待播队列 (${runtime.upcomingTracks.size})",
                style = TabularNumStyle,
                color = colors.inkPrimary,
                fontSize = 13.5.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f)
            )
            if (runtime.upNextQueue.isNotEmpty()) {
                TextButton(onClick = { runtime.clearUpNextQueue() }) {
                    Text("清空插播", color = colors.accent, fontSize = 12.sp)
                }
            }
        }

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            items(runtime.upcomingTracks, key = { "tab-q-${it.id}" }) { upcoming ->
                val isManual = runtime.upNextQueue.any { it.id == upcoming.id }
                TrackListRow(
                    track = upcoming,
                    isActive = false,
                    trailingLabel = if (isManual) "插播" else "待播",
                    onPlay = { runtime.playFromUpcomingQueue(upcoming) },
                    onPlayNext = if (isManual) ({ runtime.removeFromQueue(upcoming.id) }) else null,
                    playNextActionTitle = if (isManual) "移出" else null
                )
            }
        }
    }
}

@Composable
private fun MusicLibraryContent(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    var pendingTrack by remember { mutableStateOf<TrackSummary?>(null) }

    val safLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val queued = pendingTrack
        pendingTrack = null
        if (uri != null) {
            runtime.onSafTreeSelected(context, uri) { savedTreeUri ->
                if (queued != null) {
                    runtime.enqueueDownload(context, queued, treeUriString = savedTreeUri)
                }
            }
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(runtime.settingsValidationError ?: runtime.busyLabel ?: runtime.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(runtime) }
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = runtime.searchQuery,
                    onValueChange = { runtime.searchQuery = it },
                    leadingIcon = { Icon(AppIcons.Search, contentDescription = null, tint = colors.inkTertiary) },
                    placeholder = { Text("搜索曲目或专辑目录", fontSize = 13.sp) },
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f)
                )
                NeutralOutlineButton(
                    text = "扫描曲库",
                    onClick = { runtime.scanMusicLibrary() }
                )
            }
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                NeutralOutlineButton(
                    text = "随机播放",
                    isActive = runtime.shuffle,
                    onClick = { runtime.toggleShuffle() }
                )
                val loopTitle = when (runtime.loopMode) {
                    LoopMode.OFF -> "不循环"
                    LoopMode.ALL -> "列表循环"
                    LoopMode.ONE -> "单曲循环"
                }
                NeutralOutlineButton(
                    text = loopTitle,
                    isActive = runtime.loopMode != LoopMode.OFF,
                    onClick = { runtime.cycleLoopMode() }
                )
                Spacer(Modifier.weight(1f))
                NeutralOutlineButton(
                    text = "选择目录",
                    onClick = { runtime.activeModule = ModuleTab.CLOUD }
                )
            }
        }

        if (runtime.visibleTracks.isEmpty()) {
            item {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    color = colors.surface,
                    border = BorderStroke(1.dp, colors.separator)
                ) {
                    Column(
                        modifier = Modifier.padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text("当前曲库为空", color = colors.inkPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        Text("前往「云盘」浏览您的音乐目录并点击「设为音乐库」即可自动扫描。", color = colors.inkSecondary, fontSize = 13.sp)
                    }
                }
            }
        } else {
            items(runtime.visibleTracks, key = { it.id }) { track ->
                TrackListRow(
                    track = track,
                    isActive = track.id == runtime.currentTrackId,
                    trailingLabel = if (runtime.loadingTrackId == track.id) "加载中" else null,
                    onPlay = { runtime.playTrack(track) },
                    onPlayNext = { runtime.playNext(track) },
                    playNextActionTitle = "下一首",
                    onDownload = {
                        if (runtime.committedSettings.exportTreeUri.isNullOrBlank()) {
                            pendingTrack = track
                            safLauncher.launch(null)
                        } else {
                            runtime.enqueueDownload(context, track)
                        }
                    }
                )
            }
        }
    }
}

@Composable
private fun CloudBrowserContent(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    val pane = runtime.cloudBrowser
    val payload = pane.payload
    var backProgress by remember { mutableFloatStateOf(0f) }
    var pendingFile by remember { mutableStateOf<TrackSummary?>(null) }
    var pendingFolderPane by remember { mutableStateOf<BrowserPaneState?>(null) }

    PredictiveBackHandler(
        enabled = pane.breadcrumbs.size > 1 && runtime.activeVideoUrl == null && !runtime.isShowingNowPlayingSheet
    ) { progress ->
        try {
            progress.collect { event ->
                backProgress = event.progress
            }
            backProgress = 0f
            runtime.navigateBackInBrowser(BrowserScope.CLOUD)
        } catch (_: CancellationException) {
            backProgress = 0f
        }
    }

    val safLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val fileTarget = pendingFile
        val folderPaneTarget = pendingFolderPane
        pendingFile = null
        pendingFolderPane = null
        if (uri != null) {
            runtime.onSafTreeSelected(context, uri) { savedTreeUri ->
                if (fileTarget != null) {
                    runtime.enqueueDownload(context, fileTarget, treeUriString = savedTreeUri)
                } else if (folderPaneTarget != null) {
                    runtime.enqueueCurrentFolderDownload(context, folderPaneTarget, treeUriString = savedTreeUri)
                }
            }
        }
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer {
                translationX = backProgress * 28.dp.toPx()
                alpha = 1f - backProgress * 0.08f
            },
        contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(runtime.settingsValidationError ?: runtime.busyLabel ?: runtime.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(runtime) }
        }

        item {
            BreadcrumbAndFolderActionsBar(
                breadcrumbs = pane.breadcrumbs,
                onNavigateCrumb = { idx, crumb ->
                    runtime.browseTo(BrowserScope.CLOUD, crumb.id, pane.breadcrumbs.subList(0, idx + 1))
                },
                onResetRoot = {
                    runtime.browseTo(BrowserScope.CLOUD, null, listOf(BreadcrumbItem.ROOT))
                },
                primaryActionLabel = "设为音乐库",
                onPrimaryAction = { runtime.setCurrentFolderAsMusicLibrary(pane) },
                secondaryActionLabel = "下载此目录",
                onSecondaryAction = {
                    if (runtime.committedSettings.exportTreeUri.isNullOrBlank()) {
                        pendingFile = null
                        pendingFolderPane = pane
                        safLauncher.launch(null)
                    } else {
                        runtime.enqueueCurrentFolderDownload(context, pane)
                    }
                }
            )
        }

        val folders = payload?.folders.orEmpty()
        if (folders.isNotEmpty()) {
            items(folders, key = { "cloud-dir-${it.id}" }) { folder ->
                FolderListRow(
                    name = folder.name,
                    onClick = {
                        runtime.browseTo(
                            BrowserScope.CLOUD,
                            folder.id,
                            pane.breadcrumbs + BreadcrumbItem(folder.id, folder.name)
                        )
                    }
                )
            }
        }

        val audioFiles = payload?.audioFiles.orEmpty()
        if (audioFiles.isNotEmpty()) {
            item {
                Text(
                    "目录音频 (${audioFiles.size})",
                    style = TabularNumStyle,
                    color = colors.inkSecondary,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }
            items(audioFiles, key = { "cloud-aud-${it.id}" }) { track ->
                TrackListRow(
                    track = track,
                    isActive = track.id == runtime.currentTrackId,
                    trailingLabel = "试听",
                    onPlay = { runtime.playTrack(track) },
                    onPlayNext = { runtime.playNext(track) },
                    playNextActionTitle = "下一首",
                    onDownload = {
                        if (runtime.committedSettings.exportTreeUri.isNullOrBlank()) {
                            pendingFolderPane = null
                            pendingFile = track
                            safLauncher.launch(null)
                        } else {
                            runtime.enqueueDownload(context, track)
                        }
                    }
                )
            }
        }

        val nonAudio = payload?.let { it.videoFiles + it.otherFiles }.orEmpty()
        if (nonAudio.isNotEmpty()) {
            item {
                Text(
                    "视频与附件 (${nonAudio.size})",
                    style = TabularNumStyle,
                    color = colors.inkSecondary,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }
            items(nonAudio, key = { "cloud-other-${it.id}" }) { file ->
                TrackListRow(
                    track = file,
                    isActive = false,
                    trailingLabel = "导出",
                    onPlay = {
                        if (runtime.committedSettings.exportTreeUri.isNullOrBlank()) {
                            pendingFolderPane = null
                            pendingFile = file
                            safLauncher.launch(null)
                        } else {
                            runtime.enqueueDownload(context, file)
                        }
                    }
                )
            }
        }
    }
}

@Composable
private fun VideoWorkspaceContent(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    val pane = runtime.videoBrowser
    val folders = pane.payload?.folders.orEmpty()
    val videos = pane.payload?.videoFiles.orEmpty()
    var backProgress by remember { mutableFloatStateOf(0f) }

    PredictiveBackHandler(
        enabled = pane.breadcrumbs.size > 1 && runtime.activeVideoUrl == null && !runtime.isShowingNowPlayingSheet
    ) { progress ->
        try {
            progress.collect { event ->
                backProgress = event.progress
            }
            backProgress = 0f
            runtime.navigateBackInBrowser(BrowserScope.VIDEO)
        } catch (_: CancellationException) {
            backProgress = 0f
        }
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer {
                translationX = backProgress * 28.dp.toPx()
                alpha = 1f - backProgress * 0.08f
            },
        contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(runtime.settingsValidationError ?: runtime.busyLabel ?: runtime.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(runtime) }
        }

        item {
            BreadcrumbAndFolderActionsBar(
                breadcrumbs = pane.breadcrumbs,
                onNavigateCrumb = { idx, crumb ->
                    runtime.browseTo(BrowserScope.VIDEO, crumb.id, pane.breadcrumbs.subList(0, idx + 1))
                },
                onResetRoot = {
                    runtime.browseTo(BrowserScope.VIDEO, null, listOf(BreadcrumbItem.ROOT))
                }
            )
        }

        items(folders, key = { "vid-dir-${it.id}" }) { folder ->
            FolderListRow(
                name = folder.name,
                onClick = {
                    runtime.browseTo(
                        BrowserScope.VIDEO,
                        folder.id,
                        pane.breadcrumbs + BreadcrumbItem(folder.id, folder.name)
                    )
                }
            )
        }

        item {
            Text(
                "当前目录视频 (${videos.size})",
                style = TabularNumStyle,
                color = colors.inkSecondary,
                fontSize = 12.5.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 4.dp)
            )
        }

        if (videos.isEmpty()) {
            item {
                Text(
                    "当前目录暂无视频文件，可进入子文件夹查找。",
                    color = colors.inkTertiary,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(vertical = 8.dp)
                )
            }
        } else {
            items(videos, key = { "vid-item-${it.id}" }) { video ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    color = colors.surface,
                    border = BorderStroke(1.dp, colors.separator)
                ) {
                    Column(
                        modifier = Modifier.padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = video.name,
                            color = colors.inkPrimary,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = "${video.folderPath} · ${CloudTuneFormatters.formatBytes(video.sizeBytes)}",
                            style = TabularNumStyle,
                            color = colors.inkTertiary,
                            fontSize = 12.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            PineActionButton(
                                text = "应用内播放",
                                modifier = Modifier.weight(1f),
                                onClick = { runtime.openVideoInApp(video) }
                            )
                            NeutralOutlineButton(
                                text = "外部播放器",
                                modifier = Modifier.weight(1f),
                                onClick = { runtime.openVideoExternally(context, video) }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TransfersWorkspaceContent(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current

    val safLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            runtime.onSafTreeSelected(context, uri)
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(runtime.settingsValidationError ?: runtime.busyLabel ?: runtime.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(runtime) }
        }

        item {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                color = colors.surface,
                border = BorderStroke(1.dp, colors.separator)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "总速率 ${CloudTuneFormatters.formatBytes(runtime.transferSnapshot.totalSpeedBytesPerSecond)}/s",
                            style = TabularNumStyle,
                            color = colors.inkPrimary,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            "导出目录：${runtime.committedSettings.exportFolderDisplayName ?: "尚未授权"}",
                            color = colors.inkSecondary,
                            fontSize = 12.5.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    NeutralOutlineButton(
                        text = "选择导出目录",
                        onClick = { safLauncher.launch(null) }
                    )
                }
            }
        }

        val allItems = runtime.transferSnapshot.items
        if (allItems.isEmpty()) {
            item {
                Text(
                    "暂无传输任务。可在「曲库」或「云盘」中将文件加入导出队列。",
                    color = colors.inkTertiary,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(vertical = 12.dp)
                )
            }
        } else {
            items(allItems, key = { it.id }) { item ->
                val pct = CloudTuneFormatters.formatPercent(item.transferredBytes, item.totalBytes)
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    color = colors.surface,
                    border = BorderStroke(1.dp, colors.separator)
                ) {
                    Column(
                        modifier = Modifier.padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text(
                                text = item.label,
                                color = colors.inkPrimary,
                                fontSize = 13.5.sp,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            Text(
                                text = "${CloudTuneFormatters.formatBytes(item.bytesPerSecond)}/s",
                                style = TabularNumStyle,
                                color = colors.inkSecondary,
                                fontSize = 12.sp
                            )
                        }

                        if (pct != null) {
                            LinearProgressIndicator(
                                progress = { (pct / 100.0).toFloat() },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(5.dp)
                                    .clip(CircleShape),
                                color = colors.accent,
                                trackColor = colors.inkPrimary.copy(alpha = 0.10f)
                            )
                        }

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            val kindTag = when (item.kind) {
                                "stream" -> "流式缓存"
                                "prefetch" -> "预取"
                                "playback" -> "播放缓存"
                                else -> "导出下载"
                            }
                            val pathSuffix = item.path?.takeIf { it.isNotBlank() }?.let { " · $it" }.orEmpty()
                            val baseMeta = "$kindTag · ${item.localizedStateLabel}$pathSuffix"
                            Text(
                                text = pct?.let { "$baseMeta · ${String.format(Locale.US, "%.1f%%", it)}" } ?: baseMeta,
                                style = TabularNumStyle,
                                color = colors.inkTertiary,
                                fontSize = 12.sp,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (item.canPause) {
                                NeutralOutlineButton("暂停") { runtime.pauseTransfer(item.id) }
                            }
                            if (item.canResume) {
                                NeutralOutlineButton("继续") { runtime.resumeTransfer(context, item.id) }
                            }
                            if (item.canDelete) {
                                NeutralOutlineButton("移除") { runtime.deleteTransfer(item.id) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsWorkspaceContent(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (!(runtime.settingsValidationError ?: runtime.busyLabel ?: runtime.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(runtime) }
        }

        item {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                color = colors.surface,
                border = BorderStroke(1.dp, colors.separator)
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text("外观与主题", color = colors.inkPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        AppearanceMode.entries.forEach { mode ->
                            NeutralOutlineButton(
                                text = mode.title,
                                isActive = runtime.themeMode == mode,
                                modifier = Modifier.weight(1f),
                                onClick = { runtime.updateAppearanceMode(mode) }
                            )
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Material You 壁纸动态取色", color = colors.inkPrimary, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold)
                            Text("开启后跟随 Android 12+ 系统壁纸色盘", color = colors.inkTertiary, fontSize = 12.sp)
                        }
                        Switch(
                            checked = runtime.dynamicColorEnabled,
                            onCheckedChange = { runtime.updateDynamicColorEnabled(it) }
                        )
                    }
                }
            }
        }

        item {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                color = colors.surface,
                border = BorderStroke(1.dp, colors.separator)
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text("播放与缓存配额", color = colors.inkPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    Text(
                        "当前缓存占用：${CloudTuneFormatters.formatBytes(runtime.cacheUsageBytes)} / ${runtime.committedSettings.cacheLimitMb} MB",
                        style = TabularNumStyle,
                        color = colors.inkSecondary,
                        fontSize = 13.sp
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        NeutralOutlineButton(
                            text = "优先缓存",
                            isActive = runtime.committedSettings.playbackMode == PlaybackMode.DOWNLOAD_FIRST,
                            modifier = Modifier.weight(1f),
                            onClick = { runtime.updatePlaybackMode(PlaybackMode.DOWNLOAD_FIRST) }
                        )
                        NeutralOutlineButton(
                            text = "边播边缓存",
                            isActive = runtime.committedSettings.playbackMode == PlaybackMode.STREAM_CACHE,
                            modifier = Modifier.weight(1f),
                            onClick = { runtime.updatePlaybackMode(PlaybackMode.STREAM_CACHE) }
                        )
                    }
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        OutlinedTextField(
                            value = runtime.cacheLimitDraft,
                            onValueChange = { runtime.cacheLimitDraft = it; runtime.noteDraftEdited() },
                            label = { Text("缓存上限 (MB)") },
                            singleLine = true,
                            textStyle = TabularNumStyle,
                            modifier = Modifier.weight(1f)
                        )
                        NeutralOutlineButton("应用") { runtime.commitCacheLimitDraft() }
                    }
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        OutlinedTextField(
                            value = runtime.downloadThreadsDraft,
                            onValueChange = { runtime.downloadThreadsDraft = it; runtime.noteDraftEdited() },
                            label = { Text("下载分片") },
                            singleLine = true,
                            textStyle = TabularNumStyle,
                            modifier = Modifier.weight(1f)
                        )
                        OutlinedTextField(
                            value = runtime.cacheThreadsDraft,
                            onValueChange = { runtime.cacheThreadsDraft = it; runtime.noteDraftEdited() },
                            label = { Text("预取分片") },
                            singleLine = true,
                            textStyle = TabularNumStyle,
                            modifier = Modifier.weight(1f)
                        )
                        NeutralOutlineButton("应用") { runtime.commitTransferThreadsDraft() }
                    }
                }
            }
        }

        item {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                color = colors.surface,
                border = BorderStroke(1.dp, colors.separator)
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("账号会话", color = colors.inkPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    Text("已登录：${runtime.accountName ?: "未登录"}", color = colors.inkSecondary, fontSize = 13.sp)
                    Text("音乐库目录：${runtime.committedSettings.musicFolder?.name ?: "尚未设置"}", color = colors.inkSecondary, fontSize = 13.sp)
                    NeutralOutlineButton(
                        text = "退出登录",
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { runtime.logout() }
                    )
                }
            }
        }
    }
}

@Composable
private fun BreadcrumbAndFolderActionsBar(
    breadcrumbs: List<BreadcrumbItem>,
    onNavigateCrumb: (Int, BreadcrumbItem) -> Unit,
    onResetRoot: () -> Unit,
    primaryActionLabel: String? = null,
    onPrimaryAction: (() -> Unit)? = null,
    secondaryActionLabel: String? = null,
    onSecondaryAction: (() -> Unit)? = null
) {
    val colors = LocalCloudTuneColors.current
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = colors.surface,
        border = BorderStroke(1.dp, colors.separator)
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                itemsIndexed(breadcrumbs) { idx, crumb ->
                    val isCurrent = idx == breadcrumbs.lastIndex
                    Box(
                        modifier = Modifier
                            .sizeIn(minHeight = 36.dp)
                            .clip(CircleShape)
                            .background(if (isCurrent) colors.accentSoft else colors.surfaceSecondary)
                            .clickable(enabled = !isCurrent) { onNavigateCrumb(idx, crumb) }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = crumb.name,
                            color = if (isCurrent) colors.accent else colors.inkPrimary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1
                        )
                    }
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                NeutralOutlineButton("根目录", onClick = onResetRoot)
                if (secondaryActionLabel != null && onSecondaryAction != null) {
                    NeutralOutlineButton(secondaryActionLabel, onClick = onSecondaryAction)
                }
                if (primaryActionLabel != null && onPrimaryAction != null) {
                    PineActionButton(primaryActionLabel, onClick = onPrimaryAction)
                }
            }
        }
    }
}

@Composable
private fun FolderListRow(name: String, onClick: () -> Unit) {
    val colors = LocalCloudTuneColors.current
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .sizeIn(minHeight = 52.dp)
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        color = colors.surface,
        border = BorderStroke(1.dp, colors.separator)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(AppIcons.Folder, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
            Text(
                text = name,
                color = colors.inkPrimary,
                fontSize = 13.5.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Text("打开", color = colors.inkTertiary, fontSize = 12.sp)
        }
    }
}

@Composable
private fun TrackListRow(
    track: TrackSummary,
    isActive: Boolean,
    trailingLabel: String? = null,
    onPlay: () -> Unit,
    onPlayNext: (() -> Unit)? = null,
    playNextActionTitle: String? = null,
    onDownload: (() -> Unit)? = null
) {
    val colors = LocalCloudTuneColors.current
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .sizeIn(minHeight = 56.dp)
            .clickable(onClick = onPlay),
        shape = RoundedCornerShape(12.dp),
        color = if (isActive) colors.rowActiveSurface else colors.surface,
        border = BorderStroke(1.dp, if (isActive) colors.rowActiveBorder else colors.separator)
    ) {
        Row(
            modifier = Modifier.padding(start = 12.dp, end = 6.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            MineralArtworkCover(
                bitmap = null,
                seedText = track.name,
                size = 38.dp,
                cornerRadius = 8.dp
            )
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = track.name,
                        color = if (isActive) colors.accent else colors.inkPrimary,
                        fontSize = 13.5.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    LosslessTag(track)
                }
                Text(
                    text = "${track.folderPath} · ${CloudTuneFormatters.formatBytes(track.sizeBytes)}",
                    style = TabularNumStyle,
                    color = colors.inkTertiary,
                    fontSize = 11.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            if (!trailingLabel.isNullOrBlank()) {
                Text(
                    text = trailingLabel,
                    color = if (isActive) colors.accent else colors.inkSecondary,
                    fontSize = 11.5.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }

            if (onPlayNext != null && !playNextActionTitle.isNullOrBlank()) {
                TextButton(
                    onClick = onPlayNext,
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Text(playNextActionTitle, color = colors.inkSecondary, fontSize = 11.5.sp)
                }
            }

            if (onDownload != null) {
                IconButton(
                    onClick = onDownload,
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                ) {
                    Icon(AppIcons.Transfers, contentDescription = "下载导出", tint = colors.inkSecondary, modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun TianyiOfficialWebLoginDialog(runtime: CloudTuneAppRuntime) {
    val colors = LocalCloudTuneColors.current
    var readyToLoad by remember { mutableStateOf(false) }
    LaunchedEffect(runtime) {
        runtime.cookieCleanupDeferred?.await()
        readyToLoad = true
    }

    Dialog(
        onDismissRequest = { runtime.isShowingWebLoginDialog = false },
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.systemBars),
            color = colors.surface
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "天翼云盘官方登录",
                        color = colors.inkPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f)
                    )
                    NeutralOutlineButton("扫码登录") {
                        runtime.isShowingWebLoginDialog = false
                        runtime.beginQrLogin()
                    }
                    Spacer(Modifier.width(8.dp))
                    NeutralOutlineButton("关闭") { runtime.isShowingWebLoginDialog = false }
                }
                HorizontalDivider(color = colors.separator)
                if (readyToLoad) {
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { ctx ->
                            val cookieMgr = CookieManager.getInstance()
                            WebView(ctx).apply {
                                settings.javaScriptEnabled = true
                                settings.domStorageEnabled = true
                                webViewClient = object : WebViewClient() {
                                    private var intercepted = false
                                    override fun shouldOverrideUrlLoading(
                                        view: WebView?,
                                        request: WebResourceRequest?
                                    ): Boolean {
                                        val url = request?.url?.toString() ?: return false
                                        if (request.isForMainFrame && !intercepted && Cloud189Protocol.isInterceptableWebLoginCallback(url)) {
                                            intercepted = true
                                            runCatching { cookieMgr.flush() }
                                            val cookiesByOrigin = mapOf(
                                                "https://open.e.189.cn" to cookieMgr.getCookie("https://open.e.189.cn"),
                                                "https://cloud.189.cn" to cookieMgr.getCookie("https://cloud.189.cn"),
                                                "https://api.cloud.189.cn" to cookieMgr.getCookie("https://api.cloud.189.cn"),
                                                "https://m.cloud.189.cn" to cookieMgr.getCookie("https://m.cloud.189.cn")
                                            )
                                            runtime.completeEmbeddedWebLogin(url, cookiesByOrigin)
                                            return true
                                        }
                                        return false
                                    }
                                }
                                loadUrl(
                                    Cloud189Protocol.webLoginEntryUrl(),
                                    mapOf("Referer" to Cloud189Constants.REFERER)
                                )
                            }
                        },
                        onRelease = { webView ->
                            runCatching {
                                webView.stopLoading()
                                webView.destroy()
                            }
                        }
                    )
                }
            }
        }
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun InAppVideoOverlay(
    runtime: CloudTuneAppRuntime,
    isInPipMode: Boolean,
    onRequestPip: () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    BackHandler(enabled = !isInPipMode) {
        runtime.closeVideoPlayer()
    }

    Surface(modifier = Modifier.fillMaxSize(), color = Color.Black) {
        Column(modifier = Modifier.fillMaxSize()) {
            if (!isInPipMode) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colors.surface)
                        .windowInsetsPadding(WindowInsets.statusBars.union(WindowInsets.displayCutout))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        text = runtime.activeVideoTitle ?: "视频播放",
                        color = colors.inkPrimary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(
                        onClick = onRequestPip,
                        modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                    ) {
                        Icon(AppIcons.Pip, contentDescription = "画中画", tint = colors.inkPrimary)
                    }
                    NeutralOutlineButton("关闭") { runtime.closeVideoPlayer() }
                }
            }
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        player = runtime.videoPlayer
                        useController = !isInPipMode
                    }
                },
                update = { view ->
                    if (view.player !== runtime.videoPlayer) {
                        view.player = runtime.videoPlayer
                    }
                    view.useController = !isInPipMode
                }
            )
        }
    }
}
