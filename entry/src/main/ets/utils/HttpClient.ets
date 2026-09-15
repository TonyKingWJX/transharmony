import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 网络层：对 @ohos.net.http 的极简封装。
 * 只做一件事：把「发请求、拿 body」收拢到一处，引擎层不直接碰 http API。
 * 流式：postStream 以 SSE/分块方式读取，每收到一段文本即回调 onChunk。
 */

export interface RawResponse {
  /** HTTP 状态码 */
  status: number;
  /** 响应体原始文本 */
  body: string;
  /** 响应头（小写键名），用于读取 Date 等元信息 */
  headers: Record<string, string>;
}

export interface PostOptions {
  url: string;
  headers: Record<string, string>;
  body: string;
  /** 二进制请求体（base64）：存在时优先于 body，解码为 ArrayBuffer 原样发送（插件二进制上传） */
  bodyB64?: string;
  /** 超时毫秒数，默认 15s */
  timeoutMs?: number;
  /** 强制 HTTP/1.1。默认协议协商可能走 h2，部分老服务端（Bing/Akamai）对
   * 无 Content-Length 的 POST 回 411；h1.1 + 字符串 body 必带长度头。 */
  forceHttp1?: boolean;
  /** 非 2xx 不抛 NetworkError，原样返回 envelope（status/body/headers）。
   * 插件桥接用：Bob 语义是任何 HTTP 响应都交给插件自行判断。 */
  allowHttpError?: boolean;
}

export class NetworkError extends Error {
  readonly code: number;
  /** 失败响应的头（如可得），用于服务器时间校准 */
  readonly headers: Record<string, string>;
  constructor(code: number, message: string, headers: Record<string, string> = {}) {
    super(message);
    this.code = code;
    this.headers = headers;
  }
}

/** @ohos.net.http 的 HttpHeaders → 小写键名普通对象 */
function normalizeHeaders(raw: Object | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === undefined || raw === null) {
    return out;
  }
  // header 实际是 Record<string, string>（ArrStr 场景此处不涉及）
  const rec = raw as Record<string, string>;
  for (const k of Object.keys(rec)) {
    const v = rec[k];
    if (typeof v === 'string') {
      out[k.toLowerCase()] = v;
    }
  }
  return out;
}

export async function postJson(options: PostOptions): Promise<RawResponse> {
  const client = http.createHttp();
  try {
    // 二进制请求体：base64 解码为 ArrayBuffer 原样发送（插件图片/音频上传）
    let extra: string | ArrayBuffer = options.body;
    if (options.bodyB64 !== undefined && options.bodyB64.length > 0) {
      const u8 = new util.Base64Helper().decodeSync(options.bodyB64);
      extra = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
    }
    const reqOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: options.headers,
      extraData: extra,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: options.timeoutMs ?? 15000,
      readTimeout: options.timeoutMs ?? 15000
    };
    if (options.forceHttp1) {
      reqOptions.usingProtocol = http.HttpProtocol.HTTP1_1;
    }
    const resp = await client.request(options.url, reqOptions);
    const body = resp.result as string;
    const headers = normalizeHeaders(resp.header);
    if (!options.allowHttpError && (resp.responseCode < 200 || resp.responseCode >= 300)) {
      throw new NetworkError(resp.responseCode, `HTTP ${resp.responseCode}: ${truncate(body, 300)}`, headers);
    }
    return { status: resp.responseCode, body: body, headers: headers };
  } finally {
    client.destroy();
  }
}

export async function getJson(options: PostOptions): Promise<RawResponse> {
  const client = http.createHttp();
  try {
    const resp = await client.request(options.url, {
      method: http.RequestMethod.GET,
      header: options.headers,
      extraData: options.body.length > 0 ? options.body : undefined,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: options.timeoutMs ?? 15000,
      readTimeout: options.timeoutMs ?? 15000
    });
    const body = resp.result as string;
    const headers = normalizeHeaders(resp.header);
    if (!options.allowHttpError && (resp.responseCode < 200 || resp.responseCode >= 300)) {
      throw new NetworkError(resp.responseCode, `HTTP ${resp.responseCode}: ${truncate(body, 300)}`, headers);
    }
    return { status: resp.responseCode, body: body, headers: headers };
  } finally {
    client.destroy();
  }
}

export interface BinaryResponse {
  /** HTTP 状态码 */
  status: number;
  /** 响应体原始字节（音频等二进制内容） */
  bytes: Uint8Array;
  /** 响应头（小写键名） */
  headers: Record<string, string>;
}

/**
 * 二进制响应 POST（云端 TTS 音频下载等）：expectDataType 设为 ARRAY_BUFFER，
 * 响应体按字节返回；非 2xx 时错误体按文本尽力转可读信息抛 NetworkError。
 */
export async function postBinary(options: PostOptions): Promise<BinaryResponse> {
  const client = http.createHttp();
  try {
    const resp = await client.request(options.url, {
      method: http.RequestMethod.POST,
      header: options.headers,
      extraData: options.body,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: options.timeoutMs ?? 60000,
      readTimeout: options.timeoutMs ?? 60000
    });
    const headers = normalizeHeaders(resp.header);
    const bytes = new Uint8Array(resp.result as ArrayBuffer);
    if (!options.allowHttpError && (resp.responseCode < 200 || resp.responseCode >= 300)) {
      let msg = 'HTTP ' + resp.responseCode;
      try {
        msg += ': ' + decoder.decodeToString(bytes);
      } catch (e) {
        // 二进制体转文本失败时只报状态码
      }
      throw new NetworkError(resp.responseCode, truncate(msg, 300), headers);
    }
    return { status: resp.responseCode, bytes: bytes, headers: headers };
  } finally {
    client.destroy();
  }
}

export function truncate(s: string, max: number): string {
  return s.length > max ? s.substring(0, max) + '...' : s;
}

export interface StreamOptions {
  url: string;
  headers: Record<string, string>;
  body: string;
  /** 每收到一段增量文本回调一次（SSE data: 行的载荷） */
  onChunk: (chunk: string) => void;
  /** 整体超时毫秒数，默认 60s */
  timeoutMs?: number;
}

const decoder = util.TextDecoder.create('utf-8');

/**
 * 流式 POST（SSE）：真实增量回调。
 * - requestInStream 建立请求（Promise 在响应头到达时兑现）；
 *   正文分块经 client.on('dataReceive') 到达，每块解码后按 SSE 语义拆行，
 *   data: 行载荷立即回调 onChunk，data: [DONE] 结束；
 * - 跨块的不完整行留在缓冲区，下一块续上；
 * - 非 2xx 抛 NetworkError（与 postJson 一致）；
 * - resolve 值为完整拼接正文（除 [DONE] 外的全部 data 载荷）。
 */
export async function postStream(options: StreamOptions): Promise<string> {
  const client = http.createHttp();
  const chunks: string[] = [];
  let buffer = '';
  let finished = false;

  const handleData = (arr: ArrayBuffer): void => {
    const text = decoder.decodeToString(new Uint8Array(arr));
    buffer += text;
    // 按 \n 拆行，最后一段可能是跨块不完整行，留待续传
    const lines = buffer.split('\n');
    buffer = lines.pop() ?? '';
    for (const raw of lines) {
      const line = raw.replace(/\r$/, '');
      if (line === 'data: [DONE]' || line === 'data:[DONE]') {
        finished = true;
        continue;
      }
      if (!line.startsWith('data:')) {
        continue; // 注释/事件/空行
      }
      const payload = line.substring(5).replace(/^ /, '');
      if (payload.length === 0) {
        continue;
      }
      chunks.push(payload);
      options.onChunk(payload);
    }
  };

  return new Promise<string>((resolve, reject): void => {
    const timer = setTimeout((): void => {
      reject(new NetworkError(0, 'stream timeout'));
      try {
        client.off('dataReceive');
        client.off('dataEnd');
        client.off('headersReceive');
        client.destroy();
      } catch (e) {
        // 忽略
      }
    }, options.timeoutMs ?? 60000);
    client.on('headersReceive', (headers: Object): void => {
      // 头部到达即检查状态码（真实头结构为 Record<string, string | Array<string>>）
      const rec = headers as Record<string, Object>;
      let status = 0;
      for (const k of Object.keys(rec)) {
        if (k.toLowerCase() === 'httpstatusline' || k.toLowerCase() === ':status') {
          const v = String(rec[k]);
          const m = v.match(/\s(\d{3})\s/);
          status = m !== null ? parseInt(m[1]) : 0;
        }
      }
      if (status >= 400) {
        clearTimeout(timer);
        finished = true;
        reject(new NetworkError(status, `HTTP ${status}`));
      }
    });
    client.on('dataReceive', (arr: ArrayBuffer): void => {
      if (finished) {
        return;
      }
      try {
        handleData(arr);
      } catch (e) {
        clearTimeout(timer);
        finished = true;
        reject(new Error('stream decode failed'));
      }
    });
    client.on('dataEnd', (): void => {
      clearTimeout(timer);
      finished = true;
      resolve(chunks.join(''));
      client.destroy();
    });
    client.requestInStream(options.url, {
      method: http.RequestMethod.POST,
      header: options.headers,
      extraData: options.body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: options.timeoutMs ?? 60000,
      readTimeout: options.timeoutMs ?? 60000
    }).catch((e: BusinessError): void => {
      if (finished) {
        return;
      }
      clearTimeout(timer);
      finished = true;
      reject(new NetworkError(0, 'stream request failed: ' + e.message));
      client.destroy();
    });
  });
}
