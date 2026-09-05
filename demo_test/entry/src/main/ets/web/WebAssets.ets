import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';

/** 虚拟 origin：ArkWeb 按此地址加载，onInterceptRequest 拦截全部请求并从 rawfile 应答 */
export const VIRTUAL_ORIGIN = 'https://app.local/';
/** rawfile 内 web 产物根目录 */
const WEB_ROOT = 'dist/';

const MIME: Record<string, string> = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.map': 'application/json',
};

export interface WebAsset {
  readonly mime: string;
  /** Uint8Array 的底层 ArrayBuffer 切片（setResponseData 只接受 ArrayBuffer） */
  readonly data: ArrayBuffer;
}

/**
 * 按虚拟 origin 的请求路径解析 rawfile 资产。
 * 目录/未命中路径回落 index.html（SPA fallback）；路径穿越与根外访问返回 null（404）。
 */
export function resolveWebAsset(resMgr: resourceManager.ResourceManager, requestUrl: string): WebAsset | null {
  // requestUrl 形如 https://app.local/assets/x.js?v=1#/route —— ArkTS 无 URL 全局，手动剥离 origin 与 query/hash
  const withoutOrigin: string = requestUrl.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#]+/, '');
  const rawPath: string = withoutOrigin.split(/[?#]/)[0] ?? '/';
  let pathname: string;
  try {
    pathname = decodeURIComponent(rawPath);
  } catch (e) {
    return null;
  }
  if (pathname.includes('..')) {
    return null;
  }
  if (pathname === '/' || pathname.endsWith('/')) {
    pathname += 'index.html';
  }
  const rel = pathname.replace(/^\//, '');
  const ext = pathname.slice(pathname.lastIndexOf('.')).toLowerCase();
  const mime = MIME[ext] ?? 'application/octet-stream';

  const readAs = (rawPath: string, mimeFor: string): WebAsset | null => {
    try {
      const bytes = resMgr.getRawFileContentSync(rawPath);
      return { mime: mimeFor, data: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) };
    } catch (e) {
      return null;
    }
  };

  // SPA fallback：未命中的路径一律回 index.html（固定 text/html，不可沿用原扩展名的 MIME）
  return readAs(WEB_ROOT + rel, mime) ?? readAs(WEB_ROOT + 'index.html', 'text/html');
}

/**
 * 读取主文档（dist/index.html）并解码为 UTF-8 字符串。
 * 主文档经 loadData + baseUrl 注入（onInterceptRequest 在部分版本不拦主页面请求），
 * 子资源（JS/CSS/字体/图片）由 onInterceptRequest 拦截应答。
 */
export function readIndexHtml(resMgr: resourceManager.ResourceManager): string | null {
  try {
    const bytes = resMgr.getRawFileContentSync(WEB_ROOT + 'index.html');
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  } catch (e) {
    return null;
  }
}
