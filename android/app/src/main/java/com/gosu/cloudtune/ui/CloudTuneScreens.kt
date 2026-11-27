package com.gosu.cloudtune.ui

import android.annotation.SuppressLint
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import java.util.Locale
import com.gosu.cloudtune.core.AppThemeMode
import com.gosu.cloudtune.core.BreadcrumbItem
import com.gosu.cloudtune.core.Cloud189Constants
import com.gosu.cloudtune.core.Cloud189Protocol
import com.gosu.cloudtune.core.CloudTuneFormatters
import com.gosu.cloudtune.core.LoopMode
import com.gosu.cloudtune.core.ModuleTab
import com.gosu.cloudtune.core.PlaybackMode
import com.gosu.cloudtune.core.TrackSummary
import com.gosu.cloudtune.media.QrCodeHelper

private val TabularNumStyle = TextStyle(fontFeatureSettings = "tnum")

@Composable
fun CloudTuneRootApp(viewModel: CloudTuneViewModel) {
    val systemDark = isSystemInDarkTheme()
    val useDark = when (viewModel.themeMode) {
        AppThemeMode.LIGHT -> false
        AppThemeMode.DARK -> true
        AppThemeMode.SYSTEM -> systemDark
    }
    val config = LocalConfiguration.current
    val isTablet = config.screenWidthDp >= 600

    CloudTuneTheme(darkTheme = useDark) {
        val colors = LocalCloudTuneColors.current
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(listOf(colors.bgTop, colors.bgBottom)))
        ) {
            if (!viewModel.isAuthenticated) {
                LoginStageScreen(viewModel)
            } else if (isTablet) {
                TabletWorkspaceScaffold(viewModel)
            } else {
                PhoneWorkspaceScaffold(viewModel)
            }

            if (viewModel.isShowingWebLoginDialog) {
                TianyiOfficialWebLoginDialog(viewModel)
            }
            if (viewModel.activeVideoUrl != null) {
                InAppVideoPlayerDialog(
                    title = viewModel.activeVideoTitle ?: "视频播放",
                    videoUrl = viewModel.activeVideoUrl!!,
                    onDismiss = {
                        viewModel.activeVideoUrl = null
                        viewModel.activeVideoTitle = null
                    }
                )
            }
        }
    }
}

@Composable
private fun GlassCardBox(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, colors.cardBorder, RoundedCornerShape(18.dp)),
        shape = RoundedCornerShape(18.dp),
        color = colors.cardSurface
    ) {
        Box(modifier = Modifier.padding(14.dp)) {
            content()
        }
    }
}

@Composable
private fun PinePrimaryButton(
    text: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Brush.linearGradient(listOf(colors.primaryStart, colors.primaryEnd)))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, color = colors.primaryForeground, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

@Composable
private fun PineSecondaryButton(
    text: String,
    modifier: Modifier = Modifier,
    isActive: Boolean = false,
    onClick: () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    val bg = if (isActive) colors.rowActiveSurface else colors.rowSurface
    val border = if (isActive) colors.rowActiveBorder else colors.accentBorder
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(bg)
            .border(1.dp, border, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, color = colors.inkPrimary, fontSize = 12.5.sp, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

@Composable
private fun LoginStageScreen(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            GlassCardBox {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("CLOUDTUNE", color = colors.inkTertiary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    Text("天翼云盘音乐播放器", color = colors.inkPrimary, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
                    Text("支持天翼官方网页一键回调登录，或保存二维码到相册扫码", color = colors.inkTertiary, fontSize = 13.sp)
                }
            }
        }

        viewModel.statusMessage?.takeIf { it.isNotBlank() }?.let { msg ->
            item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(colors.noticeBackground)
                        .padding(12.dp)
                ) {
                    Text(msg, color = colors.inkPrimary, fontSize = 13.sp)
                }
            }
        }

        item {
            GlassCardBox {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    // Fixed warm-light #F6F1E8 QR substrate across light & dark themes
                    Box(
                        modifier = Modifier
                            .size(216.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(colors.qrSubstrate)
                            .border(1.dp, colors.accentBorder, RoundedCornerShape(16.dp))
                            .padding(10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        val bmp = viewModel.qrBitmap
                        if (bmp != null) {
                            Image(
                                bitmap = bmp.asImageBitmap(),
                                contentDescription = "天翼云盘二维码",
                                modifier = Modifier.fillMaxSize()
                            )
                        } else {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Icon(AppIcons.QrCode, contentDescription = null, tint = colors.qrForeground, modifier = Modifier.size(52.dp))
                                Spacer(Modifier.height(6.dp))
                                Text("二维码会显示在这里", color = colors.qrForeground, fontSize = 12.sp)
                            }
                        }
                    }

                    viewModel.qrHint?.let {
                        Text(it, color = colors.inkSecondary, fontSize = 13.sp)
                    }

                    PinePrimaryButton(
                        text = "天翼官方网页一键登录",
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { viewModel.isShowingWebLoginDialog = true }
                    )

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PineSecondaryButton(
                            text = if (viewModel.qrBitmap != null) "重新生成二维码" else "生成扫码二维码",
                            modifier = Modifier.weight(1f),
                            onClick = { viewModel.beginQrLogin() }
                        )
                        if (viewModel.qrBitmap != null) {
                            PineSecondaryButton(
                                text = "保存二维码到相册",
                                modifier = Modifier.weight(1f),
                                onClick = { viewModel.saveQrToGallery(context) }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PhoneWorkspaceScaffold(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    Scaffold(
        containerColor = Color.Transparent,
        bottomBar = {
            Column {
                MiniPlayerBar(viewModel, Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
                NavigationBar(containerColor = colors.cardStrong) {
                    ModuleTab.entries.forEach { tab ->
                        val icon = when (tab) {
                            ModuleTab.MUSIC -> AppIcons.Music
                            ModuleTab.VIDEO -> AppIcons.Video
                            ModuleTab.CLOUD -> AppIcons.Folder
                            ModuleTab.TRANSFERS -> AppIcons.Download
                            ModuleTab.SETTINGS -> AppIcons.Settings
                        }
                        NavigationBarItem(
                            selected = viewModel.activeModule == tab,
                            onClick = { viewModel.activeModule = tab },
                            icon = { Icon(icon, contentDescription = tab.title) },
                            label = { Text(tab.title, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                        )
                    }
                }
            }
        }
    ) { innerPadding ->
        Box(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            ActiveModuleContent(viewModel)
        }
    }
}

@Composable
private fun TabletWorkspaceScaffold(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    Row(modifier = Modifier.fillMaxSize()) {
        NavigationRail(containerColor = colors.cardStrong) {
            Spacer(Modifier.height(12.dp))
            ModuleTab.entries.forEach { tab ->
                val icon = when (tab) {
                    ModuleTab.MUSIC -> AppIcons.Music
                    ModuleTab.VIDEO -> AppIcons.Video
                    ModuleTab.CLOUD -> AppIcons.Folder
                    ModuleTab.TRANSFERS -> AppIcons.Download
                    ModuleTab.SETTINGS -> AppIcons.Settings
                }
                NavigationRailItem(
                    selected = viewModel.activeModule == tab,
                    onClick = { viewModel.activeModule = tab },
                    icon = { Icon(icon, contentDescription = tab.title) },
                    label = { Text(tab.title, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                )
            }
        }
        Column(modifier = Modifier.weight(1f).fillMaxHeight()) {
            Box(modifier = Modifier.weight(1f)) {
                ActiveModuleContent(viewModel)
            }
            MiniPlayerBar(viewModel, Modifier.padding(12.dp))
        }
    }
}

@Composable
private fun ActiveModuleContent(viewModel: CloudTuneViewModel) {
    when (viewModel.activeModule) {
        ModuleTab.MUSIC, ModuleTab.CLOUD -> MusicWorkspaceContent(viewModel)
        ModuleTab.VIDEO -> VideoWorkspaceContent(viewModel)
        ModuleTab.TRANSFERS -> DownloadWorkspaceContent(viewModel)
        ModuleTab.SETTINGS -> SettingsWorkspaceContent(viewModel)
    }
}

@Composable
private fun MiniPlayerBar(viewModel: CloudTuneViewModel, modifier: Modifier = Modifier) {
    val colors = LocalCloudTuneColors.current
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = colors.cardStrong,
        border = BorderStroke(1.dp, colors.accentBorder)
    ) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        viewModel.nowPlayingTitle ?: viewModel.currentTrack?.name ?: "点击曲目或随机播放",
                        color = colors.inkPrimary,
                        fontSize = 13.5.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        "${CloudTuneFormatters.formatClock(viewModel.currentTime)} / ${CloudTuneFormatters.formatClock(viewModel.duration)}",
                        style = TabularNumStyle,
                        color = colors.inkTertiary,
                        fontSize = 11.5.sp
                    )
                }
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(CircleShape)
                        .clickable { viewModel.playAdjacent(-1) },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(AppIcons.SkipPrevious, contentDescription = "上一首", tint = colors.inkPrimary, modifier = Modifier.size(18.dp))
                }
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(Brush.linearGradient(listOf(colors.primaryStart, colors.primaryEnd)))
                        .clickable { viewModel.togglePlayback() },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        if (viewModel.isPlaying) AppIcons.Pause else AppIcons.Play,
                        contentDescription = "播放暂停",
                        tint = colors.primaryForeground,
                        modifier = Modifier.size(18.dp)
                    )
                }
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(CircleShape)
                        .clickable { viewModel.playAdjacent(1) },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(AppIcons.SkipNext, contentDescription = "下一首", tint = colors.inkPrimary, modifier = Modifier.size(18.dp))
                }
            }
            if (viewModel.duration > 0.0) {
                Slider(
                    value = viewModel.currentTime.toFloat().coerceIn(0f, viewModel.duration.toFloat()),
                    onValueChange = { viewModel.seekTo(it.toDouble()) },
                    valueRange = 0f..viewModel.duration.toFloat(),
                    modifier = Modifier.height(22.dp),
                    colors = SliderDefaults.colors(
                        thumbColor = colors.warmGold,
                        activeTrackColor = colors.warmGold,
                        inactiveTrackColor = colors.inkPrimary.copy(alpha = 0.12f)
                    )
                )
            }
        }
    }
}

@Composable
private fun StatusNoticeBanner(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    val msg = (viewModel.settingsValidationError ?: viewModel.statusMessage)?.takeIf { it.isNotBlank() } ?: return
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.noticeBackground)
            .padding(10.dp)
    ) {
        Text(msg, color = colors.inkPrimary, fontSize = 12.5.sp)
    }
}

@Composable
private fun CloudFolderBrowserCard(
    title: String,
    subtitle: String? = null,
    viewModel: CloudTuneViewModel,
    showMusicActions: Boolean = false,
    onDownloadFolder: (() -> Unit)? = null
) {
    val colors = LocalCloudTuneColors.current
    val isCompactPhone = LocalConfiguration.current.screenWidthDp < 600 && (showMusicActions || onDownloadFolder != null)
    GlassCardBox {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (isCompactPhone) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(title, color = colors.inkPrimary, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (subtitle != null) {
                        Text(subtitle, style = TabularNumStyle, color = colors.inkTertiary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    PineSecondaryButton("根目录") {
                        viewModel.browseTo(null, listOf(BreadcrumbItem.ROOT))
                    }
                    if (showMusicActions) {
                        PineSecondaryButton("扫描曲库") { viewModel.scanMusicLibrary() }
                        PinePrimaryButton("设为音乐库") { viewModel.setCurrentFolderAsMusicLibrary() }
                    }
                    if (onDownloadFolder != null) {
                        PineSecondaryButton("下载文件夹", onClick = onDownloadFolder)
                    }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(title, color = colors.inkPrimary, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (subtitle != null) {
                            Text(subtitle, style = TabularNumStyle, color = colors.inkTertiary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    PineSecondaryButton("根目录") {
                        viewModel.browseTo(null, listOf(BreadcrumbItem.ROOT))
                    }
                    if (showMusicActions) {
                        PineSecondaryButton("扫描曲库") { viewModel.scanMusicLibrary() }
                        PinePrimaryButton("设为音乐库") { viewModel.setCurrentFolderAsMusicLibrary() }
                    }
                    if (onDownloadFolder != null) {
                        PineSecondaryButton("下载文件夹", onClick = onDownloadFolder)
                    }
                }
            }

            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(viewModel.breadcrumbs) { idx, crumb ->
                    val isCurrent = idx == viewModel.breadcrumbs.lastIndex
                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(colors.noticeBackground)
                            .clickable(enabled = !isCurrent) {
                                viewModel.browseTo(crumb.id, viewModel.breadcrumbs.subList(0, idx + 1))
                            }
                            .padding(horizontal = 10.dp, vertical = 5.dp)
                    ) {
                        Text(
                            crumb.name,
                            color = if (isCurrent) colors.inkSecondary else colors.inkPrimary,
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1
                        )
                    }
                }
            }

            viewModel.browser?.folders?.forEach { folder ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(11.dp))
                        .background(colors.rowSurface)
                        .clickable {
                            viewModel.browseTo(folder.id, viewModel.breadcrumbs + BreadcrumbItem(folder.id, folder.name))
                        }
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(AppIcons.Folder, contentDescription = null, tint = colors.warmGold, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(folder.name, color = colors.inkPrimary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("打开", color = colors.inkTertiary, fontSize = 11.5.sp)
                }
            }
        }
    }
}

@Composable
private fun MusicWorkspaceContent(viewModel: CloudTuneViewModel) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(viewModel.settingsValidationError ?: viewModel.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(viewModel) }
        }

        item {
            CloudFolderBrowserCard(
                title = "音乐目录 · ${viewModel.committedSettings.musicFolder?.name ?: "未设置"}",
                subtitle = "${viewModel.accountName ?: ""} · 缓存 ${CloudTuneFormatters.formatBytes(viewModel.cacheUsageBytes)}",
                viewModel = viewModel,
                showMusicActions = true
            )
        }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                PineSecondaryButton(
                    text = "随机播放",
                    isActive = viewModel.shuffle,
                    onClick = { viewModel.shuffle = !viewModel.shuffle }
                )
                val loopLabel = when (viewModel.loopMode) {
                    LoopMode.OFF -> "不循环"
                    LoopMode.ALL -> "列表循环"
                    LoopMode.ONE -> "单曲循环"
                }
                PineSecondaryButton(
                    text = loopLabel,
                    isActive = viewModel.loopMode != LoopMode.OFF,
                    onClick = {
                        viewModel.loopMode = when (viewModel.loopMode) {
                            LoopMode.OFF -> LoopMode.ALL
                            LoopMode.ALL -> LoopMode.ONE
                            LoopMode.ONE -> LoopMode.OFF
                        }
                    }
                )
            }
        }

        item {
            OutlinedTextField(
                value = viewModel.searchQuery,
                onValueChange = { viewModel.searchQuery = it },
                placeholder = { Text("搜索文件名或目录", fontSize = 13.sp) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }

        items(viewModel.visibleTracks, key = { it.id }) { track ->
            TrackRowItem(
                track = track,
                isActive = track.id == viewModel.currentTrackId,
                actionLabel = if (viewModel.loadingTrackId == track.id) "缓存中..." else "播放",
                onClick = { viewModel.playTrack(track) }
            )
        }
    }
}

@Composable
private fun VideoWorkspaceContent(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    val videos = viewModel.browser?.videoFiles ?: emptyList()
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(viewModel.settingsValidationError ?: viewModel.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(viewModel) }
        }
        item {
            CloudFolderBrowserCard(
                title = "视频目录 · ${viewModel.browser?.currentFolderName ?: "我的云盘"}",
                viewModel = viewModel
            )
        }
        item {
            Text("云盘视频 (${videos.size})", style = TabularNumStyle, color = colors.inkPrimary, fontSize = 16.sp, fontWeight = FontWeight.ExtraBold)
        }
        items(videos, key = { it.id }) { video ->
            GlassCardBox {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(video.name, color = colors.inkPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${video.folderPath} · ${CloudTuneFormatters.formatBytes(video.sizeBytes)}", style = TabularNumStyle, color = colors.inkTertiary, fontSize = 12.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PinePrimaryButton("应用内播放", Modifier.weight(1f)) { viewModel.openVideoInApp(video) }
                        PineSecondaryButton("外部播放器", Modifier.weight(1f)) { viewModel.openVideoExternally(context, video) }
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadWorkspaceContent(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    val context = LocalContext.current
    var pendingTrack by remember { mutableStateOf<TrackSummary?>(null) }
    var pendingFolder by remember { mutableStateOf(false) }

    val safLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val queuedTrack = pendingTrack
        val queuedFolder = pendingFolder
        pendingTrack = null
        pendingFolder = false
        if (uri != null) {
            viewModel.onSafTreeSelected(context, uri)
            if (queuedTrack != null) {
                viewModel.enqueueDownload(context, queuedTrack)
            } else if (queuedFolder) {
                viewModel.enqueueCurrentFolderDownload(context)
            }
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(viewModel.settingsValidationError ?: viewModel.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(viewModel) }
        }

        item {
            GlassCardBox {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("传输队列 (${CloudTuneFormatters.formatBytes(viewModel.transferSnapshot.totalSpeedBytesPerSecond)}/s)", style = TabularNumStyle, color = colors.inkPrimary, fontSize = 14.5.sp, fontWeight = FontWeight.ExtraBold)
                            Text("导出目录：${viewModel.committedSettings.exportFolderDisplayName ?: "未授权"}", color = colors.inkTertiary, fontSize = 12.sp)
                        }
                        PineSecondaryButton("授权导出目录") { safLauncher.launch(null) }
                    }

                    viewModel.downloadTransfers.forEach { item ->
                        val pct = CloudTuneFormatters.formatPercent(item.transferredBytes, item.totalBytes)
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(colors.rowSurface)
                                .padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Text(item.label, color = colors.inkPrimary, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(item.state, color = colors.inkTertiary, fontSize = 11.5.sp, modifier = Modifier.weight(1f))
                                Text("${CloudTuneFormatters.formatBytes(item.bytesPerSecond)}/s", style = TabularNumStyle, color = colors.inkSecondary, fontSize = 11.5.sp)
                                pct?.let {
                                    Text(String.format(Locale.US, "%.1f%%", it), style = TabularNumStyle, color = colors.inkPrimary, fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
                                }
                                if (item.canPause) PineSecondaryButton("暂停") { viewModel.pauseTransfer(item.id) }
                                if (item.canResume) PineSecondaryButton("继续") { viewModel.resumeTransfer(context, item.id) }
                                if (item.canDelete) PineSecondaryButton("删除") { viewModel.deleteTransfer(item.id) }
                            }
                            if (pct != null) {
                                LinearProgressIndicator(
                                    progress = { (pct / 100.0).toFloat() },
                                    modifier = Modifier.fillMaxWidth().height(5.dp).clip(CircleShape),
                                    color = colors.warmGold,
                                    trackColor = colors.inkPrimary.copy(alpha = 0.1f)
                                )
                            }
                        }
                    }
                }
            }
        }

        item {
            CloudFolderBrowserCard(
                title = "下载目录 · ${viewModel.browser?.currentFolderName ?: "我的云盘"}",
                viewModel = viewModel,
                onDownloadFolder = {
                    if (viewModel.committedSettings.exportTreeUri.isNullOrBlank()) {
                        pendingFolder = true
                        safLauncher.launch(null)
                    } else {
                        viewModel.enqueueCurrentFolderDownload(context)
                    }
                }
            )
        }

        items(viewModel.downloadableFiles, key = { it.id }) { file ->
            TrackRowItem(
                track = file,
                isActive = false,
                actionLabel = "下载",
                onClick = {
                    if (viewModel.committedSettings.exportTreeUri.isNullOrBlank()) {
                        pendingTrack = file
                        safLauncher.launch(null)
                    } else {
                        viewModel.enqueueDownload(context, file)
                    }
                }
            )
        }
    }
}

@Composable
private fun SettingsWorkspaceContent(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (!(viewModel.settingsValidationError ?: viewModel.statusMessage).isNullOrBlank()) {
            item { StatusNoticeBanner(viewModel) }
        }
        item {
            GlassCardBox {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("账号与传输设置", color = colors.inkPrimary, fontSize = 16.sp, fontWeight = FontWeight.ExtraBold)
                    Text("当前账号：${viewModel.accountName ?: "未登录"}", color = colors.inkSecondary, fontSize = 13.sp)
                    Text("缓存占用：${CloudTuneFormatters.formatBytes(viewModel.cacheUsageBytes)} / ${viewModel.committedSettings.cacheLimitMb} MB", style = TabularNumStyle, color = colors.inkSecondary, fontSize = 13.sp)

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = viewModel.cacheLimitDraft,
                            onValueChange = { viewModel.cacheLimitDraft = it; viewModel.noteDraftEdited() },
                            label = { Text("缓存上限 (MB)") },
                            singleLine = true,
                            modifier = Modifier.weight(1f)
                        )
                        PineSecondaryButton("保存上限") { viewModel.commitCacheLimitDraft() }
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = viewModel.downloadThreadsDraft,
                            onValueChange = { viewModel.downloadThreadsDraft = it; viewModel.noteDraftEdited() },
                            label = { Text("下载线程") },
                            singleLine = true,
                            modifier = Modifier.weight(1f)
                        )
                        OutlinedTextField(
                            value = viewModel.cacheThreadsDraft,
                            onValueChange = { viewModel.cacheThreadsDraft = it; viewModel.noteDraftEdited() },
                            label = { Text("缓存线程") },
                            singleLine = true,
                            modifier = Modifier.weight(1f)
                        )
                        PineSecondaryButton("保存") { viewModel.commitTransferThreadsDraft() }
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PineSecondaryButton(
                            text = "优先缓存",
                            isActive = viewModel.committedSettings.playbackMode == PlaybackMode.DOWNLOAD_FIRST,
                            modifier = Modifier.weight(1f)
                        ) { viewModel.updatePlaybackMode(PlaybackMode.DOWNLOAD_FIRST) }
                        PineSecondaryButton(
                            text = "边播边缓存",
                            isActive = viewModel.committedSettings.playbackMode == PlaybackMode.STREAM_CACHE,
                            modifier = Modifier.weight(1f)
                        ) { viewModel.updatePlaybackMode(PlaybackMode.STREAM_CACHE) }
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        AppThemeMode.entries.forEach { mode ->
                            PineSecondaryButton(
                                text = mode.title,
                                isActive = viewModel.themeMode == mode,
                                modifier = Modifier.weight(1f)
                            ) { viewModel.themeMode = mode }
                        }
                    }

                    PineSecondaryButton("退出登录", Modifier.fillMaxWidth()) { viewModel.logout() }
                }
            }
        }
    }
}

@Composable
private fun TrackRowItem(
    track: TrackSummary,
    isActive: Boolean,
    actionLabel: String,
    onClick: () -> Unit
) {
    val colors = LocalCloudTuneColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(13.dp))
            .background(if (isActive) colors.rowActiveSurface else colors.rowSurface)
            .border(1.dp, if (isActive) colors.rowActiveBorder else Color.Transparent, RoundedCornerShape(13.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 13.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(track.name, color = colors.inkPrimary, fontSize = 13.5.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(track.folderPath, color = colors.inkTertiary, fontSize = 11.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(CloudTuneFormatters.formatBytes(track.sizeBytes), style = TabularNumStyle, color = colors.inkTertiary, fontSize = 11.5.sp)
            Text(actionLabel, color = if (isActive) colors.primaryEnd else colors.inkSecondary, fontSize = 11.5.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun TianyiOfficialWebLoginDialog(viewModel: CloudTuneViewModel) {
    val colors = LocalCloudTuneColors.current
    Dialog(
        onDismissRequest = { viewModel.isShowingWebLoginDialog = false },
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = colors.cardStrong) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("天翼云盘官方登录", color = colors.inkPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    PineSecondaryButton("切回二维码") {
                        viewModel.isShowingWebLoginDialog = false
                        viewModel.beginQrLogin()
                    }
                    Spacer(Modifier.width(6.dp))
                    PineSecondaryButton("关闭") { viewModel.isShowingWebLoginDialog = false }
                }
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        val cookieMgr = CookieManager.getInstance()
                        cookieMgr.removeAllCookies(null)
                        WebView(ctx).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            webViewClient = object : WebViewClient() {
                                private var intercepted = false
                                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
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
                                        viewModel.completeEmbeddedWebLogin(url, cookiesByOrigin)
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
                    }
                )
            }
        }
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun InAppVideoPlayerDialog(
    title: String,
    videoUrl: String,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val colors = LocalCloudTuneColors.current
    val exoPlayer = remember(videoUrl) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(videoUrl))
            prepare()
            playWhenReady = true
        }
    }
    DisposableEffect(exoPlayer) {
        onDispose { exoPlayer.release() }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = Color.Black) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().background(colors.cardStrong).padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(title, color = colors.inkPrimary, fontSize = 14.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f), maxLines = 1)
                    PineSecondaryButton("关闭", onClick = onDismiss)
                }
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx -> PlayerView(ctx).apply { player = exoPlayer } }
                )
            }
        }
    }
}
