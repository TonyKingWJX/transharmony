import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import pluginHost from 'libpluginhost.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * WebSocket 桥：替插件沙盒里的 $websocket 执行真实连接（@ohos.net.websocket）。
 *
 * 数据流：插件 nativeWsNew/nativeWsOp(op JSON) → TSFN 转交主线程 → 本类执行
 * connect/send/close → 事件（open/message/close/error）经 deliverWsEvent 回沙盒回放监听。
 *
 * 操作 JSON：{op: 'new'|'open'|'send'|'sendb'|'close', id, url?, header?, text?, b64?, code?, __pid}
 * 事件 JSON：message → {"text"} 或 {"b64"}；close → {"code","reason"}；error → {"message"}
 */
export class WsBridge {
  private static registered = false;
  private static sockets: Map<number, webSocket.WebSocket> = new Map();
  private static urls: Map<number, string> = new Map();
  private static pids: Map<number, string> = new Map();

  static register(): void {
    if (WsBridge.registered) {
      return;
    }
    WsBridge.registered = true;
    pluginHost.registerWsHandler((reqJson: string): void => {
      WsBridge.execute(reqJson);
    });
  }

  private static async execute(reqJson: string): Promise<void> {
    try {
      const req = JSON.parse(reqJson) as Record<string, Object>;
      const op = typeof req['op'] === 'string' ? req['op'] as string : '';
      const id = typeof req['id'] === 'number' ? req['id'] as number
        : (typeof req['__wsid'] === 'number' ? req['__wsid'] as number : 0);
      const pid = typeof req['__pid'] === 'string' ? req['__pid'] as string : '';
      if (op === 'new') {
        WsBridge.handleNew(id, pid, req);
        return;
      }
      const ws = WsBridge.sockets.get(id);
      if (ws === undefined) {
        return;
      }
      if (op === 'open') {
        const url = WsBridge.urls.get(id) ?? '';
        const header = (req['header'] ?? {}) as Record<string, string>;
        ws.connect(url, { header: header })
          .then((): void => {
            hilog.info(0x0001, 'WsBridge', 'connect ok id=%{public}d %{public}s', id, url);
          })
          .catch((e: BusinessError): void => {
            hilog.error(0x0001, 'WsBridge', 'connect fail id=%{public}d %{public}s', id, e.message);
            const data: Record<string, string> = { 'message': e.message };
            pluginHost.deliverWsEvent(pid, id, 'error', JSON.stringify(data));
          });
      } else if (op === 'send') {
        const text = typeof req['text'] === 'string' ? req['text'] as string : '';
        ws.send(text).catch((e: BusinessError): void => {
          hilog.error(0x0001, 'WsBridge', 'send fail id=%{public}d %{public}s', id, e.message);
        });
      } else if (op === 'sendb') {
        const b64 = typeof req['b64'] === 'string' ? req['b64'] as string : '';
        const helper = new util.Base64Helper();
        const bytes = helper.decodeSync(b64);
        ws.send(bytes.buffer as ArrayBuffer).catch((e: BusinessError): void => {
          hilog.error(0x0001, 'WsBridge', 'sendb fail id=%{public}d %{public}s', id, e.message);
        });
      } else if (op === 'close') {
        const code = typeof req['code'] === 'number' ? req['code'] as number : 1000;
        ws.close({ code: code }).catch((e: BusinessError): void => {
          hilog.error(0x0001, 'WsBridge', 'close fail id=%{public}d %{public}s', id, e.message);
        });
      }
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      hilog.error(0x0001, 'WsBridge', 'op failed: %{public}s', msg);
    }
  }

  /** 创建真实 WebSocket 并挂事件（connect 延迟到 open 操作，对齐 Bob 的 new/open 两段式） */
  private static handleNew(id: number, pid: string, req: Record<string, Object>): void {
    const ws = webSocket.createWebSocket();
    const url = typeof req['url'] === 'string' ? req['url'] as string : '';
    WsBridge.sockets.set(id, ws);
    WsBridge.urls.set(id, url);
    WsBridge.pids.set(id, pid);

    ws.on('open', (): void => {
      pluginHost.deliverWsEvent(pid, id, 'open', '');
    });
    ws.on('message', (err: BusinessError, value: string | ArrayBuffer): void => {
      if (err !== undefined && err !== null) {
        return;
      }
      if (typeof value === 'string') {
        const data: Record<string, string> = { 'text': value };
        pluginHost.deliverWsEvent(pid, id, 'message', JSON.stringify(data));
      } else {
        const helper = new util.Base64Helper();
        const b64 = helper.encodeToStringSync(new Uint8Array(value));
        const data: Record<string, string> = { 'b64': b64 };
        pluginHost.deliverWsEvent(pid, id, 'message', JSON.stringify(data));
      }
    });
    ws.on('close', (err: BusinessError, value: webSocket.CloseResult): void => {
      const data: Record<string, Object> = {
        'code': typeof value.code === 'number' ? value.code : 1000,
        'reason': typeof value.reason === 'string' ? value.reason : ''
      };
      pluginHost.deliverWsEvent(pid, id, 'close', JSON.stringify(data));
      WsBridge.sockets.delete(id);
      WsBridge.urls.delete(id);
      WsBridge.pids.delete(id);
    });
    ws.on('error', (err: BusinessError): void => {
      const data: Record<string, string> = { 'message': err.message ?? 'websocket error' };
      pluginHost.deliverWsEvent(pid, id, 'error', JSON.stringify(data));
    });
  }
}
