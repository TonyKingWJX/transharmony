import { Context, common } from '@kit.AbilityKit';
import pluginHost from 'libpluginhost.so';
import { EngineRegistry } from './EngineRegistry';
import { BaiduAdapter } from './BaiduAdapter';
import { TencentAdapter } from './TencentAdapter';
import { AzureAdapter } from './AzureAdapter';
import { AliyunAdapter } from './AliyunAdapter';
import { YoudaoZhiyunAdapter } from './YoudaoZhiyunAdapter';
import { CaiyunAdapter } from './CaiyunAdapter';
import { NiutransAdapter } from './NiutransAdapter';
import { OpenAICompatAdapter } from './OpenAICompatAdapter';
import { AnthropicAdapter } from './AnthropicAdapter';
import { OfflineAdapter } from './OfflineAdapter';
import { OfflineTranslator, OFFLINE_ENGINE_ID } from './OfflineTranslator';
import { SpeechService } from './SpeechService';
import { bobPluginEngine } from './plugin/BobPluginEngine';
import { PLUGIN_DEF_PREFIX } from './plugin/BobPluginEngine';
import { HttpBridge } from './plugin/HttpBridge';
import { WsBridge } from './plugin/WsBridge';
import { settingsStore, ServiceItem } from './SettingsStore';
import { historyStore, HistoryItem, NewHistoryItem } from './HistoryStore';
import { sensitiveFilter } from './SensitiveFilter';
import { TransImageStore } from '../utils/TransImageStore';
import {
  AUTO_DETECT,
  AggregateItem,
  TranslationRequest,
  TranslationResult,
  TranslateStyle,
  langLabel
} from '../models/TranslationTypes';

/**
 * 翻译用例编排：从服务列表读取凭证注入引擎 → 敏感词检测 → 调用 → 写历史。
 * UI 只调这一个入口，不直接接触 Adapter。
 * 聚合模式：并发调用所有「已启用且已配置」的引擎，逐个回调，失败不影响其他引擎。
 */

/** 连通测试结果（配置页「测试连通」用） */
export interface TestResult {
  ok: boolean;
  message: string;
}

/** 历史附加字段（图片翻译等非默认记录用；不传 = 文本记录） */
export interface TranslateExtra {
  /** 记录类型：0=文本（默认），1=图片翻译 */
  recordType?: number;
  /** 扩展信息 JSON（图片翻译存缩略图 base64 等） */
  meta?: string;
}

export class TranslateUseCase {
  /** 应用上下文：bootstrap 时保存，供敏感词词库懒加载取 resourceManager */
  private static appCtx: Context | null = null;

  /** 应用启动时调用一次 */
  static async bootstrap(context: Context): Promise<void> {
    TranslateUseCase.appCtx = context;
    OfflineTranslator.init(context);
    SpeechService.init(context as common.UIAbilityContext);
    HttpBridge.register();
    WsBridge.register();
    // 插件流式输出路由：onStream → 对应插件的监听者（BobPluginAdapter.translateStream 注册）
    pluginHost.registerStreamHandler((streamJson: string): void => {
      try {
        const evt = JSON.parse(streamJson) as Record<string, string>;
        bobPluginEngine.dispatchStream(evt['pluginId'] ?? '', evt['text'] ?? '');
      } catch (e) {
        // 流式增量解析失败忽略
      }
    });
    await settingsStore.init(context);
    // 引擎表紧随设置存储建立（UI 首帧可能早于 bootstrap 完成，
    // 引擎行以 EngineRegistry.isReady() 门控，未就绪时留白而非显示错误状态）
    EngineRegistry.init();
    TranslateUseCase.applyCredentials();
    await historyStore.init(context);
    // 通知 UI：引擎表已就绪（修复冷启动首帧 chip 显示原始 id/服务缺失的竞态）
    AppStorage.setOrCreate('ux_pill_version', Date.now());
    // 插件清单预载：完成后重建引擎并广播（插件 chip 无感补上）
    bobPluginEngine.preload(context as common.UIAbilityContext).then((): void => {
      TranslateUseCase.refreshServices();
      AppStorage.setOrCreate('ux_pill_version', Date.now());
    }).catch((e: Object): void => {
      // 插件清单读取失败不阻断启动，仅插件引擎不可用
    });
    // 后台清理无记录引用的图片翻译原图（彻底删除/超期清理后的残留）
    TransImageStore.cleanOrphans(context);
  }

  /** 翻译前敏感词硬拦截：命中直接抛错（不发请求、不写历史），词库懒加载 */
  private static async guardSensitive(text: string): Promise<void> {
    const ctx = TranslateUseCase.appCtx;
    await sensitiveFilter.guard(text, ctx !== null ? ctx : undefined);
  }

  /** 服务列表变更（增删改/排序/开关）后重建引擎并注入凭证 */
  static refreshServices(): void {
    EngineRegistry.rebuild(settingsStore.getServices());
    TranslateUseCase.applyCredentials();
  }

  /** 把服务列表里的凭证注入对应引擎（每次翻译前刷新，改配置即生效） */
  private static applyCredentials(): void {
    const services = settingsStore.getServices();
    for (const s of services) {
      const adapter = EngineRegistry.byId(s.id);
      if (adapter === undefined) {
        continue;
      }
      TranslateUseCase.inject(adapter, s);
    }
  }

  private static inject(adapter: object, s: ServiceItem): void {
    const cfg = s.config;
    switch (s.defId) {
      case 'tencent': {
        const a = adapter as TencentAdapter;
        a.setCredentials(cfg['secretId'] ?? '', cfg['secretKey'] ?? '');
        break;
      }
      case 'azure': {
        const a = adapter as AzureAdapter;
        a.setCredentials(cfg['apiKey'] ?? '', cfg['region'] ?? '', cfg['endpoint'] ?? '');
        break;
      }
      case 'aliyun': {
        const a = adapter as AliyunAdapter;
        a.setCredentials(cfg['accessKeyId'] ?? '', cfg['accessKeySecret'] ?? '');
        break;
      }
      case 'baidu': {
        const a = adapter as BaiduAdapter;
        a.setCredentials(cfg['appId'] ?? '', cfg['secret'] ?? '');
        break;
      }
      case 'youdao-zhiyun': {
        const a = adapter as YoudaoZhiyunAdapter;
        a.setCredentials(cfg['appKey'] ?? '', cfg['appSecret'] ?? '');
        break;
      }
      case 'caiyun': {
        const a = adapter as CaiyunAdapter;
        a.setCredentials(cfg['token'] ?? '');
        break;
      }
      case 'niutrans': {
        const a = adapter as NiutransAdapter;
        a.setCredentials(cfg['apiKey'] ?? '');
        break;
      }
      default: {
        // AI 引擎（OpenAI / Anthropic 协议）
        if (adapter instanceof OpenAICompatAdapter) {
          const a = adapter as OpenAICompatAdapter;
          a.setApiKey(cfg['apiKey'] ?? '');
          const base = cfg['baseUrl'] ?? '';
          if (base.length > 0) {
            a.setBaseUrl(base);
          }
          const model = cfg['model'] ?? '';
          if (model.length > 0) {
            a.setModel(model);
          }
          a.setCustomPrompt(cfg['prompt'] ?? '');
        } else if (adapter instanceof AnthropicAdapter) {
          const a = adapter as AnthropicAdapter;
          a.setApiKey(cfg['apiKey'] ?? '');
          const base = cfg['baseUrl'] ?? '';
          if (base.length > 0) {
            a.setBaseUrl(base);
          }
          const model = cfg['model'] ?? '';
          if (model.length > 0) {
            a.setModel(model);
          }
          a.setCustomPrompt(cfg['prompt'] ?? '');
        }
        break;
      }
    }
  }

  /** 配置页保存后立即重新注入凭证（无需等下一次翻译） */
  static refreshCredentials(): void {
    TranslateUseCase.applyCredentials();
  }

  /** 连通测试结果 */
  static async testService(engineId: string): Promise<TestResult> {
    const adapter = EngineRegistry.byId(engineId);
    if (adapter === undefined) {
      const miss: TestResult = { ok: false, message: '未找到该服务实例' };
      return miss;
    }
    TranslateUseCase.applyCredentials();
    const start = Date.now();
    try {
      const req: TranslationRequest = { text: '你好，世界。', from: 'zh', to: 'en' };
      const result = await adapter.translate(req);
      const ms = Date.now() - start;
      if (result.text.trim().length === 0) {
        const empty: TestResult = { ok: false, message: '服务返回了空译文（' + ms + 'ms）' };
        return empty;
      }
      const ok: TestResult = { ok: true, message: '连通正常 · ' + ms + 'ms · 译文: ' + result.text.trim() };
      return ok;
    } catch (e) {
      const msg = e instanceof Error ? e.message : '测试失败，请检查网络与凭证';
      const fail: TestResult = { ok: false, message: msg };
      return fail;
    }
  }

  /** 引擎是否已填好必需凭证（免费通道恒真） */
  static isConfigured(adapterId: string): boolean {
    const adapter = EngineRegistry.byId(adapterId);
    if (adapter === undefined) {
      return false;
    }
    if (!adapter.needsConfig) {
      return true;
    }
    const s = settingsStore.getService(adapterId);
    if (s === undefined) {
      return false;
    }
    const required = TranslateUseCase.requiredKeys(s.defId);
    for (const key of required) {
      if ((s.config[key] ?? '').length === 0) {
        return false;
      }
    }
    return true;
  }

  /** 各服务商的必填凭证键（与 ProviderCatalog.fields 对应） */
  private static requiredKeys(defId: string): string[] {
    // Bob 插件：装好即可用（选项值由加载时的 configJson 注入，缺省走 defaultValue）
    if (defId.startsWith(PLUGIN_DEF_PREFIX)) {
      return [];
    }
    switch (defId) {
      case 'tencent':
        return ['secretId', 'secretKey'];
      case 'azure':
        return ['apiKey'];
      case 'aliyun':
        return ['accessKeyId', 'accessKeySecret'];
      case 'baidu':
        return ['appId', 'secret'];
      case 'youdao-zhiyun':
        return ['appKey', 'appSecret'];
      case 'caiyun':
        return ['token'];
      case 'niutrans':
        return ['apiKey'];
      case 'ai-openai-compat':
        return ['baseUrl'];
      case 'ai-anthropic-compat':
        return ['apiKey'];
      default:
        // AI 预置：Key 必填
        return ['apiKey'];
    }
  }

  /**
   * 单引擎翻译（含历史写入；图片翻译通过 extra 声明 recordType/meta）。
   * onDelta 可选：引擎支持流式（AI/插件）时逐段回传累积文本，非流式引擎忽略。
   */
  static async translate(text: string, from: string, to: string, engineId: string,
    style: TranslateStyle = 'plain', extra?: TranslateExtra,
    onDelta?: (fullText: string) => void): Promise<TranslationResult> {
    await TranslateUseCase.guardSensitive(text);
    const adapter = EngineRegistry.byId(engineId);
    if (adapter === undefined) {
      return Promise.reject(new Error('未知翻译服务: ' + engineId));
    }
    TranslateUseCase.applyCredentials();
    const req: TranslationRequest = { text: text, from: from, to: to, style: style };
    let result: TranslationResult;
    if (onDelta !== undefined && adapter.translateStream !== undefined) {
      result = await adapter.translateStream(req, onDelta);
    } else {
      result = await adapter.translate(req);
    }
    await TranslateUseCase.saveHistory(text, result, adapter.id, from, to, extra);
    return result;
  }

  /** 引擎是否覆盖当前语言对（离线引擎仅中英；其他引擎不做对级过滤，保持既有行为） */
  static supportsPair(adapterId: string, from: string, to: string): boolean {
    if (adapterId !== OFFLINE_ENGINE_ID) {
      return true;
    }
    const adapter = EngineRegistry.byId(adapterId);
    if (adapter === undefined) {
      return false;
    }
    const langs = adapter.supportedLangs();
    if (!langs.includes(to)) {
      return false;
    }
    // from=auto 时由内核判向（中/英启发式），恒可尝试
    return from === AUTO_DETECT || langs.includes(from);
  }

  /**
   * 聚合翻译：并发请求多个引擎，不写历史（由用户「采用」后再写）。
   * 每个引擎返回（或失败）时通过 onUpdate 回调整份列表，UI 直接替换渲染。
   */
  static async aggregate(text: string, from: string, to: string, engineIds: string[],
    style: TranslateStyle, onUpdate: (items: AggregateItem[]) => void): Promise<void> {
    await TranslateUseCase.guardSensitive(text);
    TranslateUseCase.applyCredentials();
    // 不覆盖当前语言对的引擎不进并发名单（离线引擎非中英对时静默跳过）
    const runnable = engineIds.filter((id: string): boolean =>
      TranslateUseCase.supportsPair(id, from, to));
    const items: AggregateItem[] = [];
    for (const id of runnable) {
      const adapter = EngineRegistry.byId(id);
      items.push({
        engineId: id,
        label: adapter !== undefined ? adapter.label : id,
        isAI: adapter !== undefined ? adapter.isAI : false,
        status: 'loading',
        text: '',
        elapsedMs: 0,
        error: ''
      });
    }
    onUpdate(items.slice());

    const tasks: Promise<void>[] = runnable.map(async (id: string, idx: number): Promise<void> => {
      const start = Date.now();
      const adapter = EngineRegistry.byId(id);
      try {
        if (adapter === undefined) {
          throw new Error('未知翻译服务');
        }
        const req: TranslationRequest = { text: text, from: from, to: to, style: style };
        const result = await adapter.translate(req);
        items[idx] = {
          engineId: id,
          label: adapter.label,
          isAI: adapter.isAI,
          status: 'done',
          text: result.text,
          elapsedMs: Date.now() - start,
          error: ''
        };
      } catch (e) {
        const msg = e instanceof Error ? e.message : '翻译失败，请检查网络后重试';
        items[idx] = {
          engineId: id,
          label: adapter !== undefined ? adapter.label : id,
          isAI: adapter !== undefined ? adapter.isAI : false,
          status: 'error',
          text: '',
          elapsedMs: Date.now() - start,
          error: msg
        };
      }
      onUpdate(items.slice());
    });
    await Promise.all(tasks);
  }

  /** 可用引擎（供选择面板）：免费通道 + 离线引擎 + 已启用且已配置的服务实例（聚合模式并发名单同此） */
  static usableEngineIds(): string[] {
    const ids: string[] = [];
    for (const a of EngineRegistry.all()) {
      // 离线翻译：独立开关体系（总开关+语言包），不走免费通道的 added/enabled 数组
      if (a.id === OFFLINE_ENGINE_ID) {
        if (settingsStore.isOfflineActive()) {
          ids.push(a.id);
        }
        continue;
      }
      if (!a.needsConfig) {
        // 免费服务商默认未添加未启用，生效中（已添加且已启用）才进入可用名单（聚合/回退同此）
        if (EngineRegistry.isBuiltin(a.id) && !settingsStore.isBuiltinActive(a.id)) {
          continue;
        }
        ids.push(a.id);
        continue;
      }
      const s = settingsStore.getService(a.id);
      if (s === undefined || !s.enabled) {
        continue;
      }
      if (TranslateUseCase.isConfigured(a.id)) {
        ids.push(a.id);
      }
    }
    return ids;
  }

  /** 聚合名单（历史兼容入口）：即 usableEngineIds */
  static configuredEngineIds(): string[] {
    return TranslateUseCase.usableEngineIds();
  }

  /** 聚合模式「采用」某条结果后写入历史 */
  static async saveAdopted(source: string, result: TranslationResult,
    engineId: string, from: string, to: string): Promise<void> {
    await TranslateUseCase.saveHistory(source, result, engineId, from, to);
  }

  private static async saveHistory(source: string, result: TranslationResult,
    engineId: string, from: string, to: string, extra?: TranslateExtra): Promise<void> {
    const item: NewHistoryItem = {
      source: source,
      result: result.text,
      engineId: engineId,
      fromLang: result.detectedFrom ?? from,
      toLang: to,
      createdAt: Date.now(),
      recordType: extra?.recordType ?? 0,
      meta: extra?.meta ?? ''
    };
    try {
      await historyStore.add(item);
    } catch (e) {
      // 历史写入失败不阻断翻译主流程
    }
  }

  /** 生成「原文 → 目标语言」等场景用的简述 */
  static describePair(from: string, to: string): string {
    const f = from === AUTO_DETECT ? '自动' : langLabel(from);
    return f + ' → ' + langLabel(to);
  }
}
