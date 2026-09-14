import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import pluginHost from 'libpluginhost.so';
import { PluginInstaller, InstalledPlugin } from './PluginInstaller';
import { settingsStore, ServiceItem } from '../SettingsStore';
import { LANGUAGE_LIST, LangCode } from '../../models/TranslationTypes';
import { langCatalog } from '../LangCatalog';
import { parseManggoServices, isSupportedManggoService, splitServiceRef } from './ManggoTypes';

/**
 * Bob 翻译插件的运行时管理器：
 *  - 启动时预载已安装插件清单（同步可用，供 EngineRegistry 建引擎）；
 *  - 首次翻译时懒加载进 JSVM 运行时（配置 = ServiceItem.config 覆盖 + info.json defaultValue）；
 *  - 语言码映射：Bob（zh-Hans 等）↔ 内部（zh 等），未内置语言经 LangCatalog 进选择器。
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

/** 插件声明语言（Bob 码）→ 内部语言码（保序去重；未内置语言原样保留，经 LangCatalog 展示） */
export function mapBobLangs(bobCodes: string[]): LangCode[] {
  const out: LangCode[] = [];
  for (const raw of bobCodes) {
    const c = fromBobLang(raw);
    if (!out.includes(c)) {
      out.push(c);
    }
  }
  return out;
}

class BobPluginEngine {
  private ctx: common.UIAbilityContext | null = null;
  private records: Map<string, InstalledPlugin> = new Map();
  private loaded: Set<string> = new Set();
  /** 本会话加载过的插件（Env 可能存在；重载前需销毁旧 Env。重启后为空=无 Env 可销毁） */
  private everLoaded: Set<string> = new Set();
  /** 加载中的插件（并发去重：聚合/多 chip 场景同一插件的并行 ensureLoaded 复用同一 Promise，
   *  防止同一段代码重复 eval 进同一 Env 触发 "Identifier has already been declared"） */
  private loading: Map<string, Promise<void>> = new Map();
  private langs: Map<string, LangCode[]> = new Map();
  /** 插件流式输出监听（按插件多播：同插件多个服务的适配器可同时挂监听，各自过滤服务 id） */
  private streamListeners: Map<string, Array<(resultJson: string) => void>> = new Map();

  /** TranslateUseCase.bootstrap 注册一次：路由插件 onStream/setResult 到对应监听者 */
  dispatchStream(pluginId: string, resultJson: string): void {
    const list = this.streamListeners.get(pluginId);
    if (list !== undefined) {
      for (const cb of list) {
        try {
          cb(resultJson);
        } catch (e) {
          // 监听者异常不影响运行时
        }
      }
    }
  }

  setStreamListener(pluginId: string, cb: (resultJson: string) => void): void {
    let list = this.streamListeners.get(pluginId);
    if (list === undefined) {
      list = [];
      this.streamListeners.set(pluginId, list);
    }
    if (!list.includes(cb)) {
      list.push(cb);
    }
  }

  clearStreamListener(pluginId: string, cb: (resultJson: string) => void): void {
    const list = this.streamListeners.get(pluginId);
    if (list === undefined) {
      return;
    }
    const idx = list.indexOf(cb);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
    if (list.length === 0) {
      this.streamListeners.delete(pluginId);
    }
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

  /** 确保插件已加载进 JSVM 运行时（幂等 + 并发去重 + 超时兜底） */
  async ensureLoaded(pluginId: string): Promise<void> {
    if (this.loaded.has(pluginId)) {
      return;
    }
    const inFlight = this.loading.get(pluginId);
    if (inFlight !== undefined) {
      return inFlight;
    }
    const task = this.doLoad(pluginId).finally((): void => {
      this.loading.delete(pluginId);
    });
    this.loading.set(pluginId, task);
    return task;
  }

  private async doLoad(pluginId: string): Promise<void> {
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
    hilog.info(0x0001, 'BobPluginEngine', 'ensureLoaded begin %{public}s', pluginId);
    let lastErr: Error = new Error('插件加载失败');
    // 两次机会：失败/超时后强制卸载 Env 重试一次（对齐"重进页面再试就好"的现象）
    for (let attempt = 0; attempt < 2; attempt++) {
      // 仅销毁本会话加载过的 Env：全新首载必须先走 initRuntime+Load，
      // 且绝不能在运行时启动前投递 unload（会插队到 Start 之前，导致 initRuntime 永不结算）
      if (this.everLoaded.has(pluginId)) {
        await BobPluginEngine.drainEnv(pluginId);
      }
      const load = PluginInstaller.loadInstalled(this.ctx, rec,
        rec.source === 'manggo' ? undefined : this.bobConfigOverride(pluginId));
      const timeout = new Promise<string>((_resolve: (v: string) => void,
        reject: (e: Error) => void): void => {
        setTimeout((): void => {
          reject(new Error('插件加载超时，请重试或重启应用'));
        }, BobPluginEngine.LOAD_TIMEOUT_MS);
      });
      try {
        await Promise.race([load, timeout]);
      } catch (e) {
        lastErr = e instanceof Error ? e : new Error(String(e));
        hilog.error(0x0001, 'BobPluginEngine', 'load attempt %{public}d failed: %{public}s',
          attempt + 1, lastErr.message);
        continue;
      }
      this.loaded.add(pluginId);
      this.everLoaded.add(pluginId);
      hilog.info(0x0001, 'BobPluginEngine', 'ensureLoaded done %{public}s', pluginId);
      if (rec.source !== 'manggo') {
        await this.refreshBobLangs(pluginId);
      }
      return;
    }
    throw lastErr;
  }

  /** Bob 加载后的语言支持表刷新（尽力而为：失败仅影响语言支持集精度） */
  private async refreshBobLangs(pluginId: string): Promise<void> {
    try {
      const raw = await pluginHost.callPluginFn(pluginId, 'supportLanguages', '[]', 'sync', 3000);
      const codes = JSON.parse(raw) as string[];
      if (Array.isArray(codes)) {
        const mapped = mapBobLangs(codes);
        this.langs.set(pluginId, mapped);
        // 未内置语言登记为扩展语言（选择器动态出现；识别不了的由 LangCatalog 过滤）
        const appCodes = LANGUAGE_LIST.map((it): LangCode => it.code);
        langCatalog.registerSource('bob:' + pluginId,
          mapped.filter((c: LangCode): boolean => !appCodes.includes(c)));
      }
    } catch (e) {
      // 保留全集兜底
    }
  }

  private bobConfigOverride(pluginId: string): Record<string, string> {
    const svc = settingsStore.getService(pluginServiceId(pluginId));
    return svc !== undefined ? svc.config : {};
  }

  /** 加载前销毁旧 Env（仅对本会话加载过的插件调用）：先确保运行时已启动
   *  （unloadPlugin 依赖 worker 消费队列），Env 忙时每 200ms 重试，最多 ~2s 后放行。 */
  private static async drainEnv(pluginId: string): Promise<void> {
    try {
      await pluginHost.initRuntime();
    } catch (e) {
      return; // 运行时不可用：由后续 loadPlugin 的报错兜底
    }
    for (let i = 0; i < 8; i++) {
      let res = '';
      try {
        res = await pluginHost.unloadPlugin(pluginId);
      } catch (e) {
        return;
      }
      if (!res.startsWith('plugin busy')) {
        return; // unloaded / not loaded
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 200);
      });
    }
  }

  /** 卸载/删除后清理内存态 */
  invalidate(pluginId: string): void {
    this.loaded.delete(pluginId);
    this.everLoaded.delete(pluginId);
    this.records.delete(pluginId);
    this.langs.delete(pluginId);
    langCatalog.unregisterSource('bob:' + pluginId);
    langCatalog.unregisterSource('manggo:' + pluginId);
  }

  /** 配置变更/重装后标记重载：下次 ensureLoaded 时先销毁旧 Env 再全新加载
   *  （转换后的插件代码含顶层 const/class，向同一 Env 重复 eval 会报 already declared）。
   *  注意：这里绝不直接投递 unload——运行时未启动时该命令会插队到 Start 之前，
   *  导致 worker 启动逻辑取不到 Start、initRuntime 永不结算。真正的卸载在 drainEnv 中完成。 */
  invalidateLoaded(pluginId: string): void {
    this.loaded.delete(pluginId);
  }

  /** 存量迁移：manggo 翻译服务的引擎行勾选（selected）归一化——旧版本安装的记录没有该字段：
   *  插件仅一个翻译服务 → 勾选；多个 → 全不勾选（用户在插件配置页「引擎行显示」勾选）。 */
  async normalizeManggoSelection(): Promise<void> {
    const services = settingsStore.getServices();
    const transByPlugin: Map<string, ServiceItem[]> = new Map();
    for (const s of services) {
      if (!s.defId.startsWith(PLUGIN_DEF_PREFIX) || !s.defId.includes('#') || s.selected !== undefined) {
        continue;
      }
      const parts = splitServiceRef(identifierOfDef(s.defId));
      const rec = this.records.get(parts.pluginId);
      if (rec === undefined || rec.source !== 'manggo') {
        continue;
      }
      const svcDef = parseManggoServices(rec.infoJson).find((m): boolean => m.id === parts.serviceId);
      if (svcDef === undefined || svcDef.kind !== 'translation') {
        continue;
      }
      const group = transByPlugin.get(parts.pluginId);
      if (group === undefined) {
        transByPlugin.set(parts.pluginId, [s]);
      } else {
        group.push(s);
      }
    }
    if (transByPlugin.size === 0) {
      return;
    }
    let changed = false;
    transByPlugin.forEach((items: ServiceItem[], pid: string): void => {
      const def = items.length > 1;
      for (const item of items) {
        item.selected = def;
        changed = true;
      }
      hilog.info(0x0001, 'BobPluginEngine', 'normalize selection %{public}s -> %{public}s', pid, String(def));
    });
    if (changed) {
      await settingsStore.setServices(services);
    }
  }
}

export const bobPluginEngine = new BobPluginEngine();
