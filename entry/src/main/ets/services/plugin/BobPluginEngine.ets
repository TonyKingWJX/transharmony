import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import pluginHost from 'libpluginhost.so';
import { PluginInstaller, InstalledPlugin } from './PluginInstaller';
import { settingsStore } from '../SettingsStore';
import { LANGUAGE_LIST, LangCode } from '../../models/TranslationTypes';

/**
 * Bob 翻译插件的运行时管理器：
 *  - 启动时预载已安装插件清单（同步可用，供 EngineRegistry 建引擎）；
 *  - 首次翻译时懒加载进 JSVM 运行时（配置 = ServiceItem.config 覆盖 + info.json defaultValue）；
 *  - 语言码映射：Bob（zh-Hans 等）↔ 内部（zh 等），插件支持集与应用 10 语言取交集。
 */

/** services_list 中的插件 defId 前缀（ServiceItem: id='plugin-<identifier>'，defId='plugin:<identifier>'） */
export const PLUGIN_DEF_PREFIX = 'plugin:';

const PLUGIN_SERVICE_PREFIX = 'plugin-';

export function pluginServiceId(identifier: string): string {
  return PLUGIN_SERVICE_PREFIX + identifier;
}

/** ServiceItem id → 插件 identifier（非 'plugin-' 前缀的 id 返回空串） */
export function pluginIdOfService(serviceId: string): string {
  return serviceId.startsWith(PLUGIN_SERVICE_PREFIX)
    ? serviceId.substring(PLUGIN_SERVICE_PREFIX.length) : '';
}

export function identifierOfDef(defId: string): string {
  return defId.substring(PLUGIN_DEF_PREFIX.length);
}

/** 内部语言码 → Bob 语言码（其余同形直通） */
export function toBobLang(code: LangCode): string {
  return code === 'zh' ? 'zh-Hans' : code;
}

/** Bob 语言码 → 内部语言码（yue/wyw/wyw 等应用不支持的语言由调用方交集过滤） */
export function fromBobLang(code: string): LangCode {
  return code === 'zh-Hans' ? 'zh' : code;
}

/** 插件声明语言（Bob 码）→ 应用支持语言交集（保序） */
export function mapBobLangs(bobCodes: string[]): LangCode[] {
  const appCodes = LANGUAGE_LIST.map((it): LangCode => it.code);
  const out: LangCode[] = [];
  for (const raw of bobCodes) {
    const c = fromBobLang(raw);
    if (appCodes.includes(c) && !out.includes(c)) {
      out.push(c);
    }
  }
  return out;
}

class BobPluginEngine {
  private ctx: common.UIAbilityContext | null = null;
  private records: Map<string, InstalledPlugin> = new Map();
  private loaded: Set<string> = new Set();
  private langs: Map<string, LangCode[]> = new Map();
  /** 插件流式输出监听（translateStream 期间注册；text 为插件 onStream 的 result JSON） */
  private streamListeners: Map<string, (resultJson: string) => void> = new Map();

  /** TranslateUseCase.bootstrap 注册一次：路由插件 onStream 到对应监听者 */
  dispatchStream(pluginId: string, resultJson: string): void {
    const cb = this.streamListeners.get(pluginId);
    if (cb !== undefined) {
      try {
        cb(resultJson);
      } catch (e) {
        // 监听者异常不影响运行时
      }
    }
  }

  setStreamListener(pluginId: string, cb: (resultJson: string) => void): void {
    this.streamListeners.set(pluginId, cb);
  }

  clearStreamListener(pluginId: string): void {
    this.streamListeners.delete(pluginId);
  }

  /** 启动时调用：预载已安装插件清单（EngineRegistry 建引擎前必须完成） */
  async preload(ctx: common.UIAbilityContext): Promise<void> {
    this.ctx = ctx;
    const list = await PluginInstaller.list(ctx);
    for (const rec of list) {
      this.records.set(rec.pluginId, rec);
    }
  }

  has(pluginId: string): boolean {
    return this.records.has(pluginId);
  }

  /** 安装完成后同步登记（否则下次 rebuild 前引擎建不出来，chip 不出现） */
  registerRecord(rec: InstalledPlugin): void {
    this.records.set(rec.pluginId, rec);
  }

  record(pluginId: string): InstalledPlugin | undefined {
    return this.records.get(pluginId);
  }

  /** 插件支持的应用语言（未知的返回全集；supportLanguages 刷新后为交集） */
  langsOf(pluginId: string): LangCode[] {
    const hit = this.langs.get(pluginId);
    if (hit !== undefined) {
      return hit;
    }
    return LANGUAGE_LIST.map((it): LangCode => it.code);
  }

  /** 加载超时（毫秒）：加载不结算时快速失败，避免 UI 永久转圈 */
  private static readonly LOAD_TIMEOUT_MS: number = 20000;

  /** 确保插件已加载进 JSVM 运行时（幂等；带超时兜底） */
  async ensureLoaded(pluginId: string): Promise<void> {
    if (this.loaded.has(pluginId)) {
      return;
    }
    if (this.ctx === null) {
      throw new Error('插件引擎尚未初始化');
    }
    const rec = this.records.get(pluginId);
    if (rec === undefined) {
      throw new Error('插件未安装: ' + pluginId);
    }
    const svc = settingsStore.getService(pluginServiceId(pluginId));
    const values: Record<string, string> = svc !== undefined ? svc.config : {};
    hilog.info(0x0001, 'BobPluginEngine', 'ensureLoaded begin %{public}s', pluginId);
    const load = PluginInstaller.loadInstalled(this.ctx, rec, values);
    const timeout = new Promise<string>((_resolve: (v: string) => void,
      reject: (e: Error) => void): void => {
      setTimeout((): void => {
        reject(new Error('插件加载超时，请重试或重启应用'));
      }, BobPluginEngine.LOAD_TIMEOUT_MS);
    });
    await Promise.race([load, timeout]);
    this.loaded.add(pluginId);
    hilog.info(0x0001, 'BobPluginEngine', 'ensureLoaded done %{public}s', pluginId);
    // 语言支持表刷新（尽力而为：失败不影响翻译，仅影响交集过滤精度）
    try {
      const raw = await pluginHost.callPluginFn(pluginId, 'supportLanguages', '[]', 'sync', 3000);
      const codes = JSON.parse(raw) as string[];
      if (Array.isArray(codes)) {
        this.langs.set(pluginId, mapBobLangs(codes));
      }
    } catch (e) {
      // 保留全集兜底
    }
  }

  /** 卸载/删除后清理内存态 */
  invalidate(pluginId: string): void {
    this.loaded.delete(pluginId);
    this.records.delete(pluginId);
    this.langs.delete(pluginId);
  }

  /** 配置变更后强制下次重新加载（预留：插件配置页保存后调用） */
  invalidateLoaded(pluginId: string): void {
    this.loaded.delete(pluginId);
  }
}

export const bobPluginEngine = new BobPluginEngine();
