import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'

const decoder = new TextDecoder('utf-8', { fatal: true })
const workspaceRoot = process.cwd()
const scanRoots = ['src', 'src-tauri', '.github', 'scripts']
const textExtensions = new Set([
  '.css',
  '.html',
  '.js',
  '.json',
  '.jsx',
  '.md',
  '.mjs',
  '.ps1',
  '.rs',
  '.sh',
  '.toml',
  '.ts',
  '.tsx',
  '.yaml',
  '.yml',
])
const failures = []

async function walk(relativeDir) {
  const absoluteDir = path.join(workspaceRoot, relativeDir)
  let entries = []
  try {
    entries = await readdir(absoluteDir, { withFileTypes: true })
  } catch {
    return
  }

  for (const entry of entries) {
    if (entry.name === 'node_modules' || entry.name === 'target' || entry.name === 'dist') {
      continue
    }

    const nextRelativePath = path.join(relativeDir, entry.name)
    if (entry.isDirectory()) {
      await walk(nextRelativePath)
      continue
    }

    if (!textExtensions.has(path.extname(entry.name).toLowerCase())) {
      continue
    }

    const absolutePath = path.join(workspaceRoot, nextRelativePath)
    const fileStats = await stat(absolutePath)
    if (!fileStats.isFile()) {
      continue
    }

    const buffer = await readFile(absolutePath)
    let content
    try {
      content = decoder.decode(buffer)
    } catch (error) {
      failures.push(`${nextRelativePath}: 不是有效的 UTF-8 文本 (${error.message})`)
      continue
    }

    if (content.includes('\uFFFD')) {
      failures.push(`${nextRelativePath}: 包含 Unicode 替换字符 U+FFFD，疑似文本损坏`)
    }
  }
}

for (const scanRoot of scanRoots) {
  await walk(scanRoot)
}

if (failures.length > 0) {
  console.error('检测到文本编码问题：')
  for (const failure of failures) {
    console.error(`- ${failure}`)
  }
  process.exit(1)
}

console.log('文本编码检查通过。')
