#!/usr/bin/env python
"""生成 Service Worker（sw.js）：把构建指纹（pck/wasm 字节数）写进缓存版本号。

背景：WorkBuddy 静态托管不返回 Cache-Control 头，浏览器对 100MB 级资源的
HTTP 缓存不可靠（移动端驱逐快、每次部署 Last-Modified 变化即失效）。
用 Service Worker + Cache API 由前端接管：首次访问下载并缓存，之后秒开；
游戏更新后重跑本脚本，sw.js 内容变化 → 浏览器自动替换 SW → 清旧缓存换新版。

用法：python tools/gen_sw.py   （每次 --export-release 之后、部署之前跑一次）
"""
import os
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # game/
build = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'build', 'web')


def size(name: str) -> int:
    return os.path.getsize(os.path.join(build, name))


pck = size('index.pck')
wasm = size('index.wasm')
html = size('index.html')
# 指纹必须含 index.html：改 shell 模板重导出后 pck/wasm 字节不变，
# 若只看它们会导致用户浏览器永远拿旧外壳（缓存不失效）。
cache_name = f'fdds-cache-{html}-{pck}-{wasm}'
assets = [
    'index.html',
    'index.js',
    'index.wasm',
    'index.pck',
    'index.audio.worklet.js',
    'index.audio.position.worklet.js',
    'index.icon.png',
    'index.png',
    'index.apple-touch-icon.png',
]
assets_js = ',\n  '.join(f"'./{a}'" for a in assets)
sw = f"""// 自动生成：game/tools/gen_sw.py —— 手改无效，重新导出后重跑本脚本再部署。
// 缓存版本含构建指纹（html={html} / pck={pck} / wasm={wasm} 字节）：更新游戏并重跑脚本后，
// sw.js 内容变化 → 浏览器自动替换 SW → activate 清掉旧缓存 → 首次访问重新拉新版。
const CACHE_NAME = '{cache_name}';
const ASSETS = [
  {assets_js},
];

self.addEventListener('install', (e) => {{
  // 不在 install 阶段预缓存（100MB 会拖慢首开且易失败），运行时按需缓存。
  self.skipWaiting();
}});

self.addEventListener('activate', (e) => {{
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
}});

self.addEventListener('fetch', (e) => {{
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  // 只接管游戏本体文件（pathname 以文件名结尾，容忍查询参数差异）
  if (!ASSETS.some((a) => url.pathname.endsWith(a.slice(2)))) return;
  e.respondWith(
    caches.open(CACHE_NAME).then(async (cache) => {{
      const cached = await cache.match(req, {{ ignoreSearch: true }});
      if (cached) return cached;
      const resp = await fetch(req);
      // 只缓存完整 200 响应（206 部分响应不能当整体缓存）
      if (resp && resp.status === 200 && resp.type === 'basic') {{
        cache.put(req, resp.clone()).catch(() => {{}});
      }}
      return resp;
    }})
  );
}});
"""

out = os.path.join(build, 'sw.js')
with open(out, 'w', encoding='utf-8', newline='\n') as f:
    f.write(sw)
print('已生成', out, ' CACHE_NAME =', cache_name)

wp = os.path.join(root, 'web_player')
if os.path.isdir(wp):
    with open(os.path.join(wp, 'sw.js'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(sw)
    print('已同步', os.path.join(wp, 'sw.js'))
