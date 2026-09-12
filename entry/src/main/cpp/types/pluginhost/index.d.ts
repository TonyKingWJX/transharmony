/**
 * JS 插件宿主 native 模块
 * - runTest/esmProbe：spike 探针（回归基线）
 * - initRuntime/loadPlugin/callPluginFn：常驻 JSVM 运行时
 *   callPluginFn 的 mode：'sync'（同步返回）| 'promise'（返回 Promise，Manggo 风格）
 *   | 'callback'（末参 completion 回调，Bob 风格）；结果统一为 JSON 字符串
 * - registerHttpHandler/resolveHttp：HTTP 桥（插件侧 nativeHttp 的真实网络执行在 ArkTS）
 *   插件沙盒内可用全局：nativeEcho(text)、nativeHttp(requestJson)→Promise<responseJson>
 */
export const runTest: (script?: string, timeoutMs?: number) => Promise<string>;
export const esmProbe: () => Promise<string>;

export const initRuntime: () => Promise<string>;
export const loadPlugin: (pluginId: string, code: string, configJson?: string, modulesJson?: string, pluginDir?: string, sandboxDir?: string, bundleName?: string) => Promise<string>;
export const callPluginFn: (pluginId: string, fnName: string, argsJson: string, mode: string, timeoutMs: number) => Promise<string>;

export const registerHttpHandler: (handler: (httpId: number, requestJson: string) => void) => void;
export const resolveHttp: (httpId: number, ok: number, payload: string) => void;
export const registerLogHandler: (handler: (logJson: string) => void) => void;
export const registerStreamHandler: (handler: (streamJson: string) => void) => void;
export const deliverStream: (pluginId: string, text: string) => void;
export const registerWsHandler: (handler: (reqJson: string) => void) => void;
export const deliverWsEvent: (pid: string, wsId: number, type: string, dataJson: string) => void;
