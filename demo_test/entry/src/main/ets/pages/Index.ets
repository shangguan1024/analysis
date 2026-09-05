import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';

const TAG = 'AppWeb';
const DOMAIN = 0x0000;
const WEB_ROOT = 'dist';
const ENTRY_PAGE = 'index.html';
const VIRTUAL_ORIGIN = 'https://app.local';
// ★ 根路径而非 /index.html：BrowserRouter 按 pathname 匹配路由，
// '/index.html' 不匹配任何 Route → Routes 渲染 null → 白屏；'/' 匹配首页。
// （HashRouter 产物无此约束；scheme handler 已将 '/' 回落到 index.html 资产）
const ENTRY_URL = VIRTUAL_ORIGIN + '/';

const MIME: Record<string, string> = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.webp': 'image/webp', '.gif': 'image/gif', '.ico': 'image/x-icon',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
  '.map': 'application/json', '.txt': 'text/plain',
};

/** 内存资产：启动时从 rawfile 预载，scheme handler 命中即应答（对齐 AgenticDesktopDemo 模式） */
interface WebAsset {
  mime: string;
  data: ArrayBuffer;
}

class WebAssets {
  private cache: Map<string, WebAsset> = new Map();

  loadAll(resMgr: resourceManager.ResourceManager): void {
    this.cache.clear();
    this.loadDir(resMgr, WEB_ROOT);
    hilog.info(DOMAIN, TAG, 'assets loaded: %{public}d', this.cache.size);
  }

  private loadDir(resMgr: resourceManager.ResourceManager, rawDir: string): void {
    for (const name of resMgr.getRawFileListSync(rawDir)) {
      const rawPath = rawDir + '/' + name;
      let bytes: Uint8Array | null = null;
      try {
        bytes = resMgr.getRawFileContentSync(rawPath);
      } catch (e) {
        bytes = null;
      }
      if (bytes !== null) {
        const ext = rawPath.slice(rawPath.lastIndexOf('.')).toLowerCase();
        const buf = new ArrayBuffer(bytes.byteLength);
        new Uint8Array(buf).set(bytes);
        const asset: WebAsset = { mime: MIME[ext] ?? 'application/octet-stream', data: buf };
        this.cache.set(this.toRequestPath(rawPath), asset);
      } else {
        this.loadDir(resMgr, rawPath);
      }
    }
  }

  private toRequestPath(rawPath: string): string {
    return '/' + rawPath.substring(WEB_ROOT.length + 1);
  }

  /**
   * 按请求路径解析资产。
   * SPA fallback 仅对「无扩展名的导航路径」回落 index.html；
   * 带扩展名的资源请求（字体/图片等）未命中即 404——回落会让浏览器把 HTML 当资源解码
   * （OTS parsing error / 图片裂图），掩盖真实路径错误。
   */
  resolve(path: string): WebAsset | null {
    const hit = this.cache.get(path);
    if (hit !== undefined) {
      return hit;
    }
    const last = path.lastIndexOf('.');
    const hasExt = last > path.lastIndexOf('/');
    if (!hasExt) {
      return this.cache.get('/' + ENTRY_PAGE) ?? null;
    }
    return null;
  }
}

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private assets: WebAssets = new WebAssets();
  private isControllerAttached: boolean = false;
  private isInitialBlankEnded: boolean = false;
  // 屏上诊断条：真机验证通过后可整体删除（连同 build 里的 Text 叠加）
  @State status: string = 'starting...';

  aboutToAppear(): void {
    // 对齐参考实现：开远程调试端口，桌面 Chrome chrome://inspect 可连
    try {
      webview.WebviewController.setWebDebuggingAccess(true, 7355);
      hilog.info(DOMAIN, TAG, 'web debugging enabled on 7355');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setWebDebuggingAccess failed: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Web({ src: 'about:blank', controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        // ★ localStorage/sessionStorage 总开关——不开则生成应用的数据层（@data-source）直接崩
        .domStorageAccess(true)
        // 页面 console 转发到 hilog + 诊断条：白屏排查关键信号
        .onConsole((event) => {
          const msg: string = event?.message?.getMessage() ?? '';
          this.status = 'JS: ' + msg.slice(0, 90);
          hilog.info(DOMAIN, TAG, '[web] %{public}s', msg);
          return false;
        })
        .onErrorReceive((event) => {
          const url: string = event?.request?.getRequestUrl() ?? '';
          this.status = 'LOAD ERR: ' + url.slice(0, 60);
          hilog.error(DOMAIN, TAG, 'load error: %{public}s %{public}s', url, JSON.stringify(event?.error));
        })
        .onControllerAttached(() => {
          this.isControllerAttached = true;
          this.status = 'controller attached';
          this.installSchemeHandler();
          try {
            const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
            this.assets.loadAll(context.resourceManager);
            this.status = 'assets loaded';
          } catch (e) {
            this.status = 'FAIL assets: ' + JSON.stringify(e).slice(0, 100);
            return;
          }
          this.tryLoadPage();
        })
        .onPageEnd((event) => {
          const url = event.url;
          this.status = 'page end: ' + (url ?? '').slice(0, 40);
          if (!url || url.startsWith('about:')) {
            // 初始 about:blank 结束后才能发起真正的页面加载（对齐参考实现的时序守卫）
            this.isInitialBlankEnded = true;
            this.tryLoadPage();
            return;
          }
          this.status = 'LOADED ' + url.slice(0, 50);
          hilog.info(DOMAIN, TAG, 'page loaded: %{public}s', url);
          // 读回 DOM 实况：app 挂载点的内容/子节点数 + 完整 title
          try {
            this.controller.runJavaScript(
              'JSON.stringify({title: document.title, appChildren: (document.getElementById("app")||{childNodes:{length:-1}}).childNodes.length, appHtml: ((document.getElementById("app")||{}).innerHTML||"").slice(0,80), bodyChildren: document.body.childNodes.length})',
              (err, result) => {
                if (err) {
                  this.status = 'dom read ERR';
                } else {
                  this.status = 'DOM: ' + (result ?? 'null');
                }
              },
            );
          } catch (e) {
            this.status = 'dom read THROW';
          }
        })

      // 屏上诊断条：半透明底、置底叠加，验证期间保留
      Text(this.status)
        .fontSize(14)
        .fontColor('#ffffff')
        .backgroundColor('#cc000000')
        .padding(8)
        .margin(12)
        .maxLines(4)
        .constraintSize({ maxWidth: '90%' })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * controller 级 scheme handler：接管 http/https 全部请求（含主文档）。
   * 组件级 onInterceptRequest 在此引擎上不被调用——这是参考实现（AgenticDesktopDemo）
   * 验证过的正确机制。
   */
  private installSchemeHandler(): void {
    const handler = new webview.WebSchemeHandler();
    handler.onRequestStart((request: webview.WebSchemeHandlerRequest, responseHandler: webview.WebResourceHandler): boolean => {
      const url = request.getRequestUrl();
      const path = this.requestPath(url);
      const asset = this.assets.resolve(path);
      // 每个请求打日志：scheme handler 是否被调用、是否命中的直接证据
      hilog.info(DOMAIN, TAG, 'scheme hit url=%{public}s path=%{public}s found=%{public}s',
        url, path, asset !== null ? 'yes' : 'no');
      if (asset === null) {
        this.status = 'MISS: ' + path;
        return true;
      }
      const response = new webview.WebSchemeHandlerResponse();
      response.setStatus(200);
      response.setStatusText('OK');
      response.setMimeType(asset.mime);
      response.setEncoding('utf-8');
      // 对齐标准 HTTP 响应语义（python -m http.server 对照）：
      // 模块脚本/CSS 带 crossorigin 按 CORS 模式校验，必须有 CORS 头；
      // Content-Length 缺失时 Chromium 网络栈可能将响应当作截断流静默丢弃（零报错白屏）
      response.setHeaderByName('Access-Control-Allow-Origin', '*', true);
      response.setHeaderByName('Cache-Control', 'no-store', true);
      response.setHeaderByName('Content-Length', asset.data.byteLength.toString(), true);
      responseHandler.didReceiveResponse(response);
      responseHandler.didReceiveResponseBody(asset.data);
      responseHandler.didFinish();
      return true;
    });
    this.controller.setWebSchemeHandler('http', handler);
    this.controller.setWebSchemeHandler('https', handler);
  }

  private requestPath(url: string): string {
    const withoutOrigin = url.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#]+/, '');
    let path = withoutOrigin.split(/[?#]/)[0] ?? '/';
    if (path.length === 0 || path === '/') {
      path = '/' + ENTRY_PAGE;
    }
    try {
      return decodeURIComponent(path);
    } catch (e) {
      return path;
    }
  }

  private tryLoadPage(): void {
    if (!this.isControllerAttached || !this.isInitialBlankEnded) {
      this.status = 'waiting blank end...';
      return;
    }
    try {
      this.status = 'loading ' + ENTRY_URL.slice(0, 40);
      this.controller.loadUrl(ENTRY_URL);
    } catch (e) {
      this.status = 'FAIL load: ' + JSON.stringify(e).slice(0, 100);
    }
  }
}
