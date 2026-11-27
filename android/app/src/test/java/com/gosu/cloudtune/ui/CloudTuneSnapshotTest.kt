package com.gosu.cloudtune.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.gosu.cloudtune.core.AppThemeMode
import com.gosu.cloudtune.core.RepresentativeFixture
import com.gosu.cloudtune.core.SnapshotScene
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.sqrt
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class CloudTuneSnapshotTest {
    private fun locateFixture(): RepresentativeFixture {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").canonicalFile
        while (dir != null) {
            val f = File(dir, "contracts/representative-state.json")
            if (f.isFile) return RepresentativeFixture.fromJsonString(f.readText(Charsets.UTF_8))
            dir = dir.parentFile
        }
        error("Could not locate contracts/representative-state.json")
    }

    private fun renderAndAssertAllScenes(formFactor: String, widthPx: Int, heightPx: Int) {
        assumeTrue(System.getenv("CLOUDTUNE_RENDER_SNAPSHOTS") == "1")
        val fixture = locateFixture()
        val outBase = File("build/outputs/snapshots/$formFactor")

        for ((themeFolder, themeMode, expectDark) in listOf(
            Triple("light", AppThemeMode.LIGHT, false),
            Triple("dark", AppThemeMode.DARK, true)
        )) {
            val targetDir = File(outBase, themeFolder).apply { mkdirs() }
            for (scene in SnapshotScene.entries) {
                val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
                val activity = controller.get()
                val vm = CloudTuneViewModel.fixture(scene, fixture).apply {
                    this.themeMode = themeMode
                }
                activity.setContent {
                    CloudTuneRootApp(viewModel = vm)
                }

                val decor = activity.window.decorView
                repeat(3) {
                    Shadows.shadowOf(Looper.getMainLooper()).idle()
                    decor.measure(
                        View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
                        View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY)
                    )
                    decor.layout(0, 0, widthPx, heightPx)
                }
                Shadows.shadowOf(Looper.getMainLooper()).idle()

                val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
                decor.draw(Canvas(bitmap))

                val outFile = File(targetDir, "${scene.fileStem}.png")
                FileOutputStream(outFile).use { out ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
                assertTrue("PNG file must exist and be non-trivial", outFile.length() > 4096L)

                // Analyze luminance & glyph contrast edges
                val pixels = IntArray(widthPx * heightPx)
                bitmap.getPixels(pixels, 0, widthPx, 0, 0, widthPx, heightPx)
                var count = 0
                var sum = 0.0
                var sumSq = 0.0
                var edges = 0
                for (y in 0 until heightPx step 2) {
                    val row = y * widthPx
                    var prev: Double? = null
                    for (x in 0 until widthPx step 2) {
                        val c = pixels[row + x]
                        val r = ((c shr 16) and 0xFF) / 255.0
                        val g = ((c shr 8) and 0xFF) / 255.0
                        val b = (c and 0xFF) / 255.0
                        val lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        count += 1
                        sum += lum
                        sumSq += lum * lum
                        if (prev != null && abs(lum - prev) >= 0.20) edges += 1
                        prev = lum
                    }
                }
                val mean = sum / count
                val stdDev = sqrt((sumSq / count - mean * mean).coerceAtLeast(0.0))
                assertTrue("$formFactor $themeFolder ${scene.fileStem} stdDev=$stdDev too flat", stdDev > 0.03)
                assertTrue("$formFactor $themeFolder ${scene.fileStem} edges=$edges too low", edges > 250)
                if (expectDark) {
                    assertTrue("$formFactor dark ${scene.fileStem} mean=$mean too bright", mean < 0.40)
                } else {
                    assertTrue("$formFactor light ${scene.fileStem} mean=$mean too dark", mean > 0.55)
                }

                controller.pause().stop().destroy()
            }
        }
    }

    @Test
    @Config(qualifiers = "w412dp-h915dp-xxhdpi")
    fun renderPhoneLightAndDarkSnapshots() {
        renderAndAssertAllScenes(formFactor = "phone", widthPx = 1080, heightPx = 2400)
    }

    @Test
    @Config(qualifiers = "w1024dp-h768dp-mdpi")
    fun renderTabletLightAndDarkSnapshots() {
        renderAndAssertAllScenes(formFactor = "tablet", widthPx = 1024, heightPx = 768)
    }
}
