# Web 版托管说明（肥嘟嘟幸存者）

本目录是 Godot 的 **Web 导出预设与自定义外壳**。生成的网页版产物在 `build/web/`。

## 1. 导出

双击 `tools/export_web.cmd`（或跑下面的命令），**然后跑 `tools/gen_sw.py` 生成 sw.js**：

```bat
Godot_v4.7.2-stable_win64_console.exe --headless --path <项目根> ^
  --export-release "Web (Mobile)" "build/web/index.html"
python tools\gen_sw.py
```

> gen_sw.py 会把 pck/wasm 字节数写进 sw.js 的缓存版本号。**每次重新导出后必须重跑**，
> 否则玩家浏览器里的 Service Worker 不会感知资源更新。sw.js 与资源文件要一起部署。

导出后 `build/web/` 里会有：

| 文件 | 说明 |
| --- | --- |
| `index.html` | 入口页（自定义外壳，手机适配） |
| `index.wasm` | 游戏引擎（约 25MB，首次加载会 gzip/brotli 压缩传输） |
| `index.pck` | 游戏资源包（美术/脚本/音频，约 40MB） |
| `index.js` / `index.worker.js` | 加载器 |
| `index.icon.*` | 图标 |

## 2. 本地测试

**必须用 http 打开，不能直接双击 `index.html`（`file://` 会被浏览器 CORS 拦掉）。**

```bat
cd build\web
python -m http.server 8060
rem 然后浏览器打开 http://localhost:8060/
```

## 3. 公网分享（让别人点链接就能玩）

### ✅ 当前正式链接（已部署，永久有效）

**https://feidudu-survivors.app.workbuddy.host/**

- 发布目录：`game/web_player/`（= `build/web/` 的干净副本 + `.nojekyll`，共 93MB）
- 更新版本时：重新导出 → 同步 `build/web/*` 到 `web_player/` → 重新发布同一目录即可覆盖，链接不变。
- 线上已验证：首页/JS/PCK/WASM 全部 200，WASM 支持 Range 且走 CDN 缓存；无头浏览器实测
  `startGame()` 成功、真实渲染出游戏画面。

### 备选托管方案（如需换地方）

把 `build/web/` 整个目录上传到任意**静态托管**即可，无需后端：

- **GitHub Pages**：仓库 → Settings → Pages → 选分支/目录 → 得到 `https://<user>.github.io/<repo>/`
- **Cloudflare Pages / Vercel / Netlify**：拖拽整个目录上传，几十秒出链接
- **国内**：腾讯云 COS / 阿里云 OSS（开静态网站托管）——**国内访问速度最好**

### 关于压缩（重要）

`.wasm` 有 25MB 原始体积，**务必开启 gzip/brotli 预压缩**，否则手机上首次加载会很慢：

- 多数托管（GitHub Pages / Cloudflare / Vercel）**自动**对 `.wasm` 做 brotli/gzip，无需配置；
- 自建 Nginx 时确认 `gzip_types application/wasm;`（或 brotli 模块），
  并给 `.wasm` 加 `Content-Type: application/wasm`。

## 4. 线程模式（可选，默认关闭）

当前预设是**单线程**（`variant/thread_support=false`），好处是：

- **不需要** COOP/COEP 响应头 → 任何静态托管、iOS Safari 都能直接跑。

代价：单线程 wasm 性能略低。若你的机器/玩家都在桌面且追求帧率，可在
Godot 编辑器 → 项目 → 导出 → `Web (Mobile)` → 勾选 **Thread Support**，
但托管端**必须**返回以下两个头（否则白屏）：

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

GitHub Pages 无法自定义响应头（除非用 `coi-serviceworker` 之类的 hack），
Cloudflare Pages 可用 `_headers` 文件配置。**面向手机玩家，建议保持单线程。**

## 5. 手机操作

### 资源缓存（Service Worker，2026-09-24 起生效）

托管响应头没有 Cache-Control，浏览器对 100MB 级资源的 HTTP 缓存不可靠（移动端驱逐快）。
现在由 **Service Worker + Cache API** 接管：

- **首次打开**：正常下载（约 100MB），同时写入浏览器持久缓存（Cache API，比 HTTP 缓存稳定得多）；
- **之后每次打开**：引擎与资源直接从本地缓存读取，**秒开**（实测线上二次加载 49s → 1.6s）；
- **游戏更新**：重新导出 + 重跑 `tools/gen_sw.py` + 部署后，sw.js 内容变化 → 浏览器自动
  更新 SW 并清掉旧缓存 → 用户下次打开重新下载新版（预期行为，仅此一次）。

> 缓存版本号指纹 = `index.html + index.pck + index.wasm` 三者字节数。**含 html 是关键**：
> 只改外壳模板重导出时 pck/wasm 字节不变，若指纹只看它们，玩家会永远拿到旧外壳。

注意：部署完成后有几分钟 CDN 同步窗口，期间部分用户可能短暂拿到旧版页面（重新打开即新）。

### 「开始游戏」按钮与声音解锁（2026-09-24 音频根治）

打开页面后的流程：**自动预载（进度条）→ 出现「▶ 开始游戏」按钮 → 点击进入**。

- **为什么要点按钮**：浏览器规定 AudioContext 只在「用户手势激活期」内创建/恢复才出声。
  旧版页面加载完自动启动引擎，AudioContext 在无手势时创建（suspended），suspended 期间
  开播的 BGM 音源在 resume 后**不输出**（引擎 Web 端已知坑）→ 全程无声。
  新版预载完成后由用户点击启动，引擎 AudioContext 创建即 running，无头探针实测
  `ctxStates: ["running"]`、BGM 数据 RMS 0.14~0.19（有声）。
- **预载与启动的衔接**：预载把 wasm/pck 真实下载进 SW 缓存；点击后 `startGame` 内部的
  下载被 SW cache-first 秒回 → 引擎瞬间启动，赶在手势激活窗口（约 5 秒）内创建音频。
- **预载失败不挡路**：按钮照常出现，`startGame` 走网络慢路径兜底（只是无预载进度）。

### 触屏

游戏内已内置**左侧浮动虚拟摇杆**（`scripts/ui/TouchControls.gd`）：真机有触摸屏时
自动显示，手指按在屏幕左半边拖动即可走位。本外壳额外做了：

- 锁定视口、禁止缩放/滚动/长按菜单，避免误触；
- **横屏竖屏都能玩**（2026-09-23 起去掉强制横屏遮罩）：stretch 为 `canvas_items+expand`，
  竖屏下画面等比缩放不变形、垂直视野自动扩展。注意纵向 UI（血条/升级卡/结算面板）
  按 720 高常量布局，竖屏下会悬在屏幕上部（见台账风险 #17，待实机评估）；
- 首屏加载进度条 + 桌面端（无触摸设备）自动显示键盘操作提示。

## 6. 电脑端操作（2026-09-23 起官方支持）

直接用电脑浏览器打开链接即可玩，键盘输入映射 `project.godot` 原生支持：

- **WASD / 方向键**：移动
- **空格**：使用道具
- **ESC**：暂停
- **鼠标**：点击所有界面按钮（升级三选一 / 商店 / 标题菜单等）

游戏启动后会自动聚焦画布，无需先点击页面。
