import { TranslatorAdapter } from './TranslatorAdapter';
import { EdgeTranslatorAdapter } from './EdgeTranslatorAdapter';
import { YoudaoAdapter } from './YoudaoAdapter';
import { AliyunAdapter } from './AliyunAdapter';
import { TencentAdapter } from './TencentAdapter';
import { AzureAdapter } from './AzureAdapter';
import { BaiduAdapter } from './BaiduAdapter';
import { YoudaoZhiyunAdapter } from './YoudaoZhiyunAdapter';
import { CaiyunAdapter } from './CaiyunAdapter';
import { NiutransAdapter } from './NiutransAdapter';
import { OpenAICompatAdapter } from './OpenAICompatAdapter';
import { AnthropicAdapter } from './AnthropicAdapter';
import { OfflineAdapter } from './OfflineAdapter';
import { OFFLINE_FEATURE_ENABLED } from './OfflineTranslator';
import { ServiceItem, settingsStore } from './SettingsStore';
import { findDef } from './ProviderCatalog';
import { BobPluginAdapter } from './plugin/BobPluginAdapter';
import { PLUGIN_DEF_PREFIX, identifierOfDef, pluginIdOfService, bobPluginEngine } from './plugin/BobPluginEngine';

/**
 * 引擎注册表：按「免费通道 + 用户服务列表」动态构建。
 * - 免费通道（edge/youdao）常驻排最前，开箱即翻；
 * - 用户在「内置翻译服务」页添加的每个服务实例（ServiceItem）对应一个引擎，
 *   顺序 = 服务列表顺序；switch 开关只影响「是否参与聚合/是否出现在选择面板」，
 *   引擎实例本身仍保留（用户手动选择时给「已停用」提示由上层过滤）。
 * - rebuild(services) 在启动与服务列表变更时调用。
 */

/** 内置免费通道 id：开关/删除状态存 settingsStore，可在「添加服务商」面板重新开启 */
export const BUILTIN_ENGINE_IDS: string[] = ['edge', 'youdao'];

export class EngineRegistry {
  private static adapters: TranslatorAdapter[] = [];
  /** 引擎表是否已建立（bootstrap 完成前 UI 引擎行留白，避免显示原始 id 等错误状态） */
  private static readyFlag: boolean = false;

  static isReady(): boolean {
    return EngineRegistry.readyFlag;
  }

  /** 是否内置免费通道（区别于用户添加的服务实例） */
  static isBuiltin(id: string): boolean {
    return BUILTIN_ENGINE_IDS.includes(id);
  }

  /** 从持久化服务列表重建（应用启动时） */
  static init(): void {
    EngineRegistry.rebuild(settingsStore.getServices());
  }

  /** 按服务列表重建全部引擎（免费通道顺序按内置通道排序存储，离线引擎紧随其后） */
  static rebuild(services: ServiceItem[]): void {
    const list: TranslatorAdapter[] = [];
    for (const id of settingsStore.getBuiltinOrder()) {
      if (id === 'edge') {
        list.push(new EdgeTranslatorAdapter());
      } else if (id === 'youdao') {
        list.push(new YoudaoAdapter());
      }
    }
    // 离线翻译（端侧内置模型）：总闸开启且总开关+语言包均开启才参与；独立于免费通道开关体系
    if (OFFLINE_FEATURE_ENABLED && settingsStore.isOfflineActive()) {
      list.push(new OfflineAdapter());
    }
    for (const s of services) {
      const adapter = EngineRegistry.createFor(s);
      if (adapter !== null) {
        list.push(adapter);
      }
    }
    EngineRegistry.adapters = list;
    EngineRegistry.readyFlag = true;
  }

  /** 为单个服务实例创建引擎（凭证由 TranslateUseCase 注入） */
  static createFor(s: ServiceItem): TranslatorAdapter | null {
    // Bob 插件引擎（defId = 'plugin:<identifier>'）：仅翻译类进引擎行，
    // TTS/OCR 插件由偏好设置中的服务选择调度（执行接入在后续版本）
    if (s.defId.startsWith(PLUGIN_DEF_PREFIX)) {
      const pluginId = identifierOfDef(s.defId);
      const rec = bobPluginEngine.record(pluginId);
      if (rec === undefined || rec.category !== 'translate') {
        return null;
      }
      const label = s.name.length > 0 ? s.name : rec.name;
      return new BobPluginAdapter(s.id, pluginId, label);
    }
    const def = findDef(s.defId);
    if (def === undefined) {
      return null;
    }
    const cfg = s.config;
    const name = s.name.length > 0 ? s.name : def.label;
    if (def.kind === 'ai') {
      const baseUrl = (cfg['baseUrl'] !== undefined && cfg['baseUrl'].length > 0)
        ? cfg['baseUrl'] : def.baseUrl;
      const model = (cfg['model'] !== undefined && cfg['model'].length > 0)
        ? cfg['model'] : def.defaultModel;
      if (def.aiFormat === 'anthropic') {
        return new AnthropicAdapter(s.id, name, baseUrl, model);
      }
      return new OpenAICompatAdapter(s.id, name, baseUrl, model);
    }
    switch (s.defId) {
      case 'tencent': {
        const a = new TencentAdapter();
        a.id = s.id;
        a.label = name;
        return a;
      }
      case 'aliyun': {
        const a = new AliyunAdapter();
        a.id = s.id;
        a.label = name;
        return a;
      }
      case 'baidu': {
        const a = new BaiduAdapter();
        a.id = s.id;
        a.label = name;
        return a;
      }
      case 'youdao-zhiyun':
        return new YoudaoZhiyunAdapter(s.id, name);
      case 'caiyun':
        return new CaiyunAdapter(s.id, name);
      case 'niutrans':
        return new NiutransAdapter(s.id, name);
      case 'azure': {
        const a = new AzureAdapter();
        a.id = s.id;
        a.label = name;
        return a;
      }
      default:
        return null;
    }
  }

  static all(): TranslatorAdapter[] {
    return EngineRegistry.adapters;
  }

  static byId(id: string): TranslatorAdapter | undefined {
    return EngineRegistry.adapters.find((a: TranslatorAdapter) => a.id === id);
  }

  /** 引擎显示名：注册表 label 优先；插件引擎已卸载/未注册时从服务表与安装记录兜底（历史记录回溯场景） */
  static displayNameOf(id: string): string {
    const hit = EngineRegistry.byId(id);
    if (hit !== undefined) {
      return hit.label;
    }
    if (id.startsWith('plugin-')) {
      const svc = settingsStore.getService(id);
      if (svc !== undefined && svc.name.length > 0 && svc.name !== id) {
        return svc.name;
      }
      const rec = bobPluginEngine.record(pluginIdOfService(id));
      if (rec !== undefined) {
        return rec.name;
      }
    }
    return id;
  }

  /** 服务列表（含开关），与引擎一一对应（免费通道除外） */
  static serviceOf(id: string): ServiceItem | undefined {
    return settingsStore.getServices().find((s: ServiceItem): boolean => s.id === id);
  }
}
