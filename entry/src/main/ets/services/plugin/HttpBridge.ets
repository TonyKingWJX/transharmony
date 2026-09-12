import pluginHost from 'libpluginhost.so';
import { getJson, postJson, postStream, RawResponse } from '../../utils/HttpClient';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * HTTP 桥：替插件沙盒里的 nativeHttp 原语执行真实网络请求。
 *
 * 数据流：插件 JS 调 nativeHttp(requestJson) → worker 经 TSFN 转交主线程 →
 * 本类（ArkTS，注册的 handler）执行 @ohos.net.http → resolveHttp 回投应答 →
 * worker 兑现插件的 Promise。
 *
 * 原语约定（nativeHttp 层；Bob 的 $http shim 在其上做 Bob 语义编码）：
 *   请求  requestJson: {"url","method","header","body","timeout"(秒)}
 *   成功  resolve: {"status", "headers", "body"}
 *   失败  reject:  {"message"}
 * 注：multipart/files 与流式不在本期范围。
 */
export class HttpBridge {
  private static registered = false;

  static register(): void {
    if (HttpBridge.registered) {
      return;
    }
    HttpBridge.registered = true;
    pluginHost.registerHttpHandler((httpId: number, requestJson: string): void => {
      HttpBridge.execute(httpId, requestJson);
    });
  }

  private static async execute(httpId: number, requestJson: string): Promise<void> {
    let method = 'GET';
    let url = '';
    try {
      const req = JSON.parse(requestJson) as Record<string, Object>;
      const rawUrl = req['url'];
      url = typeof rawUrl === 'string' ? rawUrl : '';
      if (url === '') {
        pluginHost.resolveHttp(httpId, 0, JSON.stringify({ message: 'empty url' }));
        return;
      }
      const rawMethod = req['method'];
      method = (typeof rawMethod === 'string' ? rawMethod : 'GET').toUpperCase();
      const header = (req['header'] ?? {}) as Record<string, string>;
      const rawBody = req['body'];
      const body = typeof rawBody === 'string' ? rawBody : '';
      const rawTimeout = req['timeout'];
      const timeoutSec = typeof rawTimeout === 'number' ? rawTimeout : 60;
      const timeoutMs = Math.max(1000, Math.min(300000, timeoutSec * 1000));
      const rawStream = req['stream'];
      const isStream = typeof rawStream === 'boolean' ? rawStream as boolean : false;
      const rawPid = req['__pid'];
      const pid = typeof rawPid === 'string' ? rawPid as string : '';

      // 流式请求（$http.streamRequest / streamHandler）：SSE 增量经 deliverStream 回放沙盒，
      // 结束时 resolve 不含 data 的 envelope（Bob 1.8.0 语义）
      if (isStream && pid.length > 0) {
        hilog.info(0x0001, 'HttpBridge', 'STREAM %{public}s %{public}s', method, url);
        await postStream({
          url: url,
          headers: header,
          body: body,
          timeoutMs: timeoutMs,
          onChunk: (chunk: string): void => {
            pluginHost.deliverStream(pid, chunk);
          }
        });
        const endHeaders: Record<string, string> = {};
        const endEnv: Record<string, Object> = {
          'status': 200, 'headers': endHeaders, 'body': ''
        };
        pluginHost.resolveHttp(httpId, 1, JSON.stringify(endEnv));
        return;
      }

      // Bob 语义：任何 HTTP 响应（含 4xx/5xx）都回 envelope，由插件自行判断数据；
      // 仅传输层失败（DNS/超时/连接拒绝）才 reject。
      let resp: RawResponse;
      if (method === 'GET' || method === 'HEAD' || method === 'DELETE') {
        resp = await getJson({
          url: url, headers: header, body: '', timeoutMs: timeoutMs, allowHttpError: true
        });
      } else {
        resp = await postJson({
          url: url, headers: header, body: body, timeoutMs: timeoutMs, allowHttpError: true
        });
      }
      hilog.info(0x0001, 'HttpBridge', '%{public}s %{public}s -> %{public}d len=%{public}d',
        method, url, resp.status, resp.body.length);
      pluginHost.resolveHttp(httpId, 1, JSON.stringify({
        status: resp.status,
        headers: resp.headers,
        body: resp.body
      }));
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      hilog.error(0x0001, 'HttpBridge', '%{public}s %{public}s -> transport error: %{public}s',
        method, url, msg);
      pluginHost.resolveHttp(httpId, 0, JSON.stringify({ message: msg }));
    }
  }
}
