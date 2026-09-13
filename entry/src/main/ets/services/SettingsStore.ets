import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { safeParseArray, getStr } from '../utils/JsonUtil';
import { findDef, ConfigField } from './ProviderCatalog';
import { AssetVault } from './AssetVault';

/**
 * 用户添加的服务实例（一个 ProviderDef 可添加多个实例，如两个不同的 OpenAI 兼容服务）。
 * config 为「字段key → 值」的扁平表，字段清单由 ProviderCatalog.ProviderDef.fields 定义；
 * 键名沿用旧版 Preferences 键名（见 migrate），保证老用户配置无缝迁入。
 */
export interface ServiceItem {
  /** 实例 id：官方预置服务 = ProviderDef.id；重复添加时加序号后缀 */
  id: string;
  /** 目录 id（ProviderDef.id），指向静态定义 */
  defId: string;
  /** 用户可编辑的显示名 */
  name: string;
  /** 是否启用 */
  enabled: boolean;
  /** 凭证配置（字段key → 值） */
  config: Record<string, string>;
  /** 是否显示在主页引擎行（仅 manggo 翻译服务参与勾选；undefined = 未参与选择，按显示处理） */
  selected?: boolean;
}

interface SerializedService {
  id: string;
  defId: string;
  name: string;
  enabled: string;
  config: Record<string, string>;
  selected?: string;
}

/**
 * 设置存储：Preferences（键值对）。
 * v0.3 起翻译服务改为「服务列表」模型：services_list JSON 数组存实例（顺序即列表顺序，
 * 落盘时统一按「传统翻译在前、AI 翻译在后」归并），每个实例含 enabled 开关与 config 凭证表。
 * v1.0.0 起 secret 字段（ConfigField.secret = true，即 API Key/Secret 类密钥）改存
 * Asset Store Kit（见 AssetVault）：services_list JSON 只落非敏感字段，密钥明文不落盘；
 * 内存态 getServices() 由 ASSET 缓存补值，对外接口签名不变（应用内备份/恢复兼容）。
 */

const PREF_NAME = 'transharmony_settings';

export class SettingsStore {
  private pref: preferences.Preferences | null = null;
  /** 内存密钥缓存（ASSET 别名 → 密钥值）：init 时从 ASSET 加载，供 getServices 同步补值 */
  private vault: Map<string, string> = new Map();

  async init(context: Context): Promise<void> {
    if (this.pref !== null) {
      return;
    }
    this.pref = await preferences.getPreferences(context, PREF_NAME);
    this.migrateLegacy();
    await this.loadVault();
  }

  private async put(key: string, value: preferences.ValueType): Promise<void> {
    if (this.pref === null) {
      return;
    }
    await this.pref.put(key, value);
    await this.pref.flush();
  }

  /** ASSET 资产别名：th_cred_<serviceId>_<fieldKey> */
  private credAlias(serviceId: string, fieldKey: string): string {
    return serviceId + '_' + fieldKey;
  }

  // ---- 服务列表（v0.3 核心模型）----

  getServices(): ServiceItem[] {
    return this.parseList(this.pref?.getSync('services_list', '') as string);
  }

  /** services_list JSON 解析：非敏感字段直接读，secret 字段从 ASSET 缓存补值（JSON 中不含明文） */
  private parseList(raw: string): ServiceItem[] {
    if (raw === undefined || raw.length === 0) {
      return [];
    }
    const items = safeParseArray(raw);
    const out: ServiceItem[] = [];
    for (const it of items) {
      const id = getStr(it, 'id');
      const defId = getStr(it, 'defId');
      const name = getStr(it, 'name');
      if (id.length === 0 || defId.length === 0) {
        continue;
      }
      const def = findDef(defId);
      const config: Record<string, string> = {};
      const cfgObj = it['config'];
      if (typeof cfgObj === 'object' && cfgObj !== null && !Array.isArray(cfgObj)) {
        const cfg = cfgObj as Record<string, Object | null>;
        for (const k of Object.keys(cfg)) {
          const v = cfg[k];
          if (typeof v === 'string') {
            config[k] = v;
          }
        }
      }
      // secret 字段（API Key/Secret 类）明文只在 ASSET：从内存缓存补值
      if (def !== undefined) {
        for (const f of def.fields) {
          if (!f.secret) {
            continue;
          }
          const v = this.vault.get(this.credAlias(id, f.key));
          if (v !== undefined && v.length > 0) {
            config[f.key] = v;
          }
        }
      }
      out.push({
        id: id,
        defId: defId,
        name: name.length > 0 ? name : defId,
        enabled: getStr(it, 'enabled') !== '0',
        config: config,
        selected: getStr(it, 'selected').length > 0 ? getStr(it, 'selected') === '1' : undefined
      });
    }
    return out;
  }

  async setServices(list: ServiceItem[]): Promise<void> {
    const arr = await this.serializeList(list);
    await this.put('services_list', JSON.stringify(arr));
  }

  /**
   * 序列化服务列表：secret 字段（ConfigField.secret = true）写 ASSET 并从 JSON 剥离，
   * 非敏感字段（baseUrl/model/region 等）落 Preferences；值清空时删除对应资产；
   * 已删除实例的孤儿资产一并清理。
   */
  private async serializeList(list: ServiceItem[]): Promise<SerializedService[]> {
    const arr: SerializedService[] = [];
    const alive = new Set<string>();
    for (const s of this.grouped(list)) {
      // Bob 插件实例（无 ProviderDef）：secret 字段由插件配置页直存 ASSET（别名前缀=实例id）。
      // 全部标记存活，避免孤儿清理误删；插件卸载时由插件服务页显式清理。
      if (s.defId.startsWith('plugin:')) {
        const prefix = s.id + '_';
        for (const alias of Array.from(this.vault.keys())) {
          if (alias.startsWith(prefix)) {
            alive.add(alias);
          }
        }
      }
      const def = findDef(s.defId);
      const out: Record<string, string> = {};
      for (const k of Object.keys(s.config)) {
        const v = s.config[k];
        const f = def !== undefined
          ? def.fields.find((it: ConfigField): boolean => it.key === k)
          : undefined;
        if (f !== undefined && f.secret) {
          const alias = this.credAlias(s.id, k);
          alive.add(alias);
          if (v.length > 0) {
            await AssetVault.write(alias, v);
            this.vault.set(alias, v);
          } else {
            AssetVault.remove(alias);
            this.vault.delete(alias);
          }
        } else {
          out[k] = v;
        }
      }
      const rec: SerializedService = {
        id: s.id,
        defId: s.defId,
        name: s.name,
        enabled: s.enabled ? '1' : '0',
        config: out
      };
      if (s.selected !== undefined) {
        rec.selected = s.selected ? '1' : '0';
      }
      arr.push(rec);
    }
    // 已删除实例的孤儿资产清理
    for (const alias of Array.from(this.vault.keys())) {
      if (!alive.has(alias)) {
        AssetVault.remove(alias);
        this.vault.delete(alias);
      }
    }
    return arr;
  }

  /**
   * 密钥上 ASSET（启动时一次性）：
   * services_list JSON 中仍含明文的 secret 字段（升级/恢复场景）搬入 ASSET 并从 JSON 剥离；
   * JSON 中无明文的（新装机/已迁移）从 ASSET 回填内存缓存。
   */
  private async loadVault(): Promise<void> {
    const raw = this.pref?.getSync('services_list', '') as string;
    if (raw === undefined || raw.length === 0) {
      return;
    }
    const items = safeParseArray(raw);
    let dirty = false;
    for (const it of items) {
      const id = getStr(it, 'id');
      const defId = getStr(it, 'defId');
      const def = findDef(defId);
      if (id.length === 0 || def === undefined) {
        continue;
      }
      const cfgObj = it['config'];
      if (typeof cfgObj !== 'object' || cfgObj === null || Array.isArray(cfgObj)) {
        continue;
      }
      const cfg = cfgObj as Record<string, Object | null>;
      let moved = false;
      const newCfg: Record<string, string> = {};
      for (const f of def.fields) {
        if (!f.secret) {
          continue;
        }
        const alias = this.credAlias(id, f.key);
        const v = cfg[f.key];
        if (typeof v === 'string' && v.length > 0) {
          // 明文仍在 Preferences：搬入 ASSET（幂等）并从 JSON 剥离
          try {
            await AssetVault.write(alias, v);
            this.vault.set(alias, v);
            moved = true;
            dirty = true;
          } catch (e) {
            // ASSET 写失败保留明文原样，下次启动重试
            newCfg[f.key] = v;
          }
        } else {
          const secret = AssetVault.read(alias);
          if (secret.length > 0) {
            this.vault.set(alias, secret);
          }
        }
      }
      if (moved) {
        // 重建该实例的 config（只保留非敏感字段）
        for (const k of Object.keys(cfg)) {
          const isSecretField = def.fields.some((sf: ConfigField): boolean => sf.key === k && sf.secret);
          if (!isSecretField && typeof cfg[k] === 'string') {
            newCfg[k] = cfg[k] as string;
          }
        }
        it['config'] = newCfg;
      }
    }
    if (dirty && this.pref !== null) {
      this.pref.putSync('services_list', JSON.stringify(items));
      this.pref.flush();
    }
  }

  /** 传统翻译在前、AI 翻译在后的稳定归并（组内保持原相对顺序），
   *  使扁平列表顺序与列表页分组展示、引擎 chip 行、聚合返回顺序一致 */
  private grouped(list: ServiceItem[]): ServiceItem[] {
    const trad: ServiceItem[] = [];
    const ai: ServiceItem[] = [];
    for (const s of list) {
      const def = findDef(s.defId);
      if (def !== undefined && def.kind === 'trad') {
        trad.push(s);
      } else {
        ai.push(s);
      }
    }
    return trad.concat(ai);
  }

  getService(id: string): ServiceItem | undefined {
    return this.getServices().find((s: ServiceItem): boolean => s.id === id);
  }

  /** 更新单个实例的凭证（config 表整体替换） */
  async updateServiceConfig(id: string, config: Record<string, string>): Promise<void> {
    const list = this.getServices();
    const hit = list.find((s: ServiceItem): boolean => s.id === id);
    if (hit === undefined) {
      return;
    }
    hit.config = config;
    await this.setServices(list);
  }

  async setServiceEnabled(id: string, enabled: boolean): Promise<void> {
    const list = this.getServices();
    const hit = list.find((s: ServiceItem): boolean => s.id === id);
    if (hit === undefined) {
      return;
    }
    hit.enabled = enabled;
    await this.setServices(list);
  }

  async removeService(id: string): Promise<void> {
    const list = this.getServices().filter((s: ServiceItem): boolean => s.id !== id);
    await this.setServices(list);
  }

  /** 上移/下移（交换列表顺序） */
  async moveService(id: string, up: boolean): Promise<void> {
    const list = this.getServices();
    const idx = list.findIndex((s: ServiceItem): boolean => s.id === id);
    if (idx < 0) {
      return;
    }
    const target = up ? idx - 1 : idx + 1;
    if (target < 0 || target >= list.length) {
      return;
    }
    const tmp = list[idx];
    list[idx] = list[target];
    list[target] = tmp;
    await this.setServices(list);
  }

  /** 拖拽排序：把 fromId 的实例移动到 toId 所在位置 */
  async reorderService(fromId: string, toId: string): Promise<void> {
    const list = this.getServices();
    const from = list.findIndex((s: ServiceItem): boolean => s.id === fromId);
    const to = list.findIndex((s: ServiceItem): boolean => s.id === toId);
    if (from < 0 || to < 0 || from === to) {
      return;
    }
    const moved = list[from];
    list.splice(from, 1);
    list.splice(to, 0, moved);
    await this.setServices(list);
  }

  // ---- 引擎行顺序（翻译页 chip 行，含免费通道）----

  /** 翻译页引擎行 chip 顺序（edge/youdao/服务实例 id），空数组 = 未自定义（按默认顺序展示） */
  getEngineChipOrder(): string[] {
    const raw = this.pref?.getSync('engine_chip_order', '') as string;
    if (raw === undefined || raw.length === 0) {
      return [];
    }
    try {
      const v: Object = JSON.parse(raw);
      if (!Array.isArray(v)) {
        return [];
      }
      const out: string[] = [];
      for (let i = 0; i < v.length; i++) {
        const it: Object = v[i];
        if (typeof it === 'string') {
          out.push(it);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  async setEngineChipOrder(ids: string[]): Promise<void> {
    await this.put('engine_chip_order', JSON.stringify(ids));
  }

  // ---- 免费服务商（单实例双状态：added=已添加（管理页可见）；enabled=启用（进引擎行/聚合）。
  //      全新安装两个列表都为空 = 默认未添加、未启用，需在「添加服务商」面板手动添加）----

  private static readonly BUILTIN_IDS: string[] = ['edge', 'youdao'];

  /** 解析字符串数组（容错） */
  private parseStringArray(raw: string): string[] {
    const out: string[] = [];
    if (raw === undefined || raw.length === 0) {
      return out;
    }
    try {
      const v: Object = JSON.parse(raw);
      if (!Array.isArray(v)) {
        return out;
      }
      for (let i = 0; i < v.length; i++) {
        const it: Object = v[i];
        if (typeof it === 'string' && !out.includes(it)) {
          out.push(it);
        }
      }
    } catch (e) {
      // 解析失败按空处理
    }
    return out;
  }

  /** 一次性迁移（v2）：全新安装默认未添加、未启用；
   *  仅当存在旧版本数据时继承——黑名单时期（免费通道常驻启用）未拉黑的全部继承为已添加+启用；
   *  上一轮白名单版本的原样继承 */
  private ensureBuiltinMigrated(): void {
    if (this.pref === null) {
      return;
    }
    const done = this.pref.getSync('builtin_v2_migrated', false) as boolean;
    if (done === true) {
      return;
    }
    let added: string[] = [];
    let enabled: string[] = [];
    const legacy = this.pref.getSync('builtin_disabled', '') as string;
    if (legacy !== undefined && legacy.length > 0) {
      added = SettingsStore.BUILTIN_IDS;
      const disabled = this.parseStringArray(legacy);
      enabled = SettingsStore.BUILTIN_IDS.filter((id: string): boolean => !disabled.includes(id));
    } else if (this.pref.getSync('builtin_migrated', false) as boolean === true) {
      const prev = this.parseStringArray(this.pref.getSync('builtin_enabled', '[]') as string)
        .filter((id: string): boolean => SettingsStore.BUILTIN_IDS.includes(id));
      added = prev;
      enabled = prev;
    }
    this.pref.putSync('builtin_added', JSON.stringify(added));
    this.pref.putSync('builtin_enabled', JSON.stringify(enabled));
    if ((this.pref.getSync('builtin_order', '') as string).length === 0) {
      this.pref.putSync('builtin_order', JSON.stringify(SettingsStore.BUILTIN_IDS));
    }
    this.pref.putSync('builtin_v2_migrated', true);
    this.pref.flush();
  }

  /** 已添加的免费服务商 id（管理页可见；默认空） */
  getBuiltinAdded(): string[] {
    this.ensureBuiltinMigrated();
    return this.parseStringArray(this.pref?.getSync('builtin_added', '[]') as string)
      .filter((id: string): boolean => SettingsStore.BUILTIN_IDS.includes(id));
  }

  isBuiltinAdded(id: string): boolean {
    return this.getBuiltinAdded().includes(id);
  }

  async setBuiltinAdded(ids: string[]): Promise<void> {
    await this.put('builtin_added', JSON.stringify(ids));
  }

  /** 已启用的免费服务商 id（added 的子集；启用才进引擎行/聚合） */
  getBuiltinEnabled(): string[] {
    this.ensureBuiltinMigrated();
    return this.parseStringArray(this.pref?.getSync('builtin_enabled', '[]') as string)
      .filter((id: string): boolean => SettingsStore.BUILTIN_IDS.includes(id));
  }

  isBuiltinEnabled(id: string): boolean {
    return this.getBuiltinEnabled().includes(id);
  }

  /** 是否生效中（已添加且已启用） */
  isBuiltinActive(id: string): boolean {
    return this.isBuiltinAdded(id) && this.isBuiltinEnabled(id);
  }

  async setBuiltinEnabled(ids: string[]): Promise<void> {
    await this.put('builtin_enabled', JSON.stringify(ids));
  }

  /** 免费服务商顺序（管理页组内拖拽落盘；传导到聚合顺序与引擎 chip 默认顺序） */
  getBuiltinOrder(): string[] {
    this.ensureBuiltinMigrated();
    const out = this.parseStringArray(this.pref?.getSync('builtin_order', '') as string)
      .filter((id: string): boolean => SettingsStore.BUILTIN_IDS.includes(id));
    // 兜底补全：顺序表缺失的内置通道按默认顺序追加
    for (const id of SettingsStore.BUILTIN_IDS) {
      if (!out.includes(id)) {
        out.push(id);
      }
    }
    return out;
  }

  async setBuiltinOrder(ids: string[]): Promise<void> {
    await this.put('builtin_order', JSON.stringify(ids));
  }

  // ---- 离线翻译（内置端侧引擎，独立管理页，不进免费通道/服务列表体系）----
  // added=已在添加面板/管理页开启过（仅控制添加面板是否还显示「离线翻译」条目）；
  // enabled=总开关；pack_enabled=「中英离线包」开关（内置包不可删除，只能停用）。

  getOfflineAdded(): boolean {
    return this.pref !== null ? this.pref.getSync('offline_added', false) === true : false;
  }

  async setOfflineAdded(v: boolean): Promise<void> {
    await this.put('offline_added', v);
  }

  /** 总开关：关闭后离线引擎不进引擎行/聚合（即使语言包在已下载列表中启用） */
  getOfflineEnabled(): boolean {
    return this.pref !== null ? this.pref.getSync('offline_enabled', false) === true : false;
  }

  async setOfflineEnabled(v: boolean): Promise<void> {
    await this.put('offline_enabled', v);
  }

  /** 「中英离线包」开关（默认启用：包随应用内置，未动过开关即视为启用） */
  getOfflinePackEnabled(): boolean {
    return this.pref !== null ? this.pref.getSync('offline_pack_enabled', true) !== false : true;
  }

  async setOfflinePackEnabled(v: boolean): Promise<void> {
    await this.put('offline_pack_enabled', v);
  }

  /** 离线引擎是否生效中（总开关 + 语言包均开启；added 只影响添加面板展示） */
  isOfflineActive(): boolean {
    return this.getOfflineEnabled() && this.getOfflinePackEnabled();
  }

  // ---- 语音服务 TTS / 文字识别 OCR 服务选择 ----
  // 'system' = 系统服务（默认）；'plugin-<identifier>' = 指定插件
  getTtsEngineId(): string {
    const v = this.pref?.getSync('tts_engine_id', 'system') as string;
    return v !== undefined && v.length > 0 ? v : 'system';
  }

  setTtsEngineId(id: string): Promise<void> {
    return this.put('tts_engine_id', id);
  }

  getOcrEngineId(): string {
    const v = this.pref?.getSync('ocr_engine_id', 'system') as string;
    return v !== undefined && v.length > 0 ? v : 'system';
  }

  setOcrEngineId(id: string): Promise<void> {
    return this.put('ocr_engine_id', id);
  }

  /**
   * 旧版数据迁移（一次性）：
   * v0.2 及以前凭证存独立键（tencent_id / baidu_appid / aikey_xxx…），
   * v0.3 首次启动时聚合为服务列表；迁移成功后写迁移标记。
   */
  private migrateLegacy(): void {
    const done = this.pref?.getSync('services_migrated', false) as boolean;
    if (done === true || this.pref === null) {
      return;
    }
    const get = (k: string): string => this.pref?.getSync(k, '') as string;
    const list: ServiceItem[] = [];
    let changed = false;

    const tId = get('tencent_id');
    const tKey = get('tencent_key');
    if (tId.length > 0 && tKey.length > 0) {
      const tCfg: Record<string, string> = { 'secretId': tId, 'secretKey': tKey };
      list.push({ id: 'tencent', defId: 'tencent', name: '腾讯翻译', enabled: true, config: tCfg });
      changed = true;
    }
    const azKey = get('azure_key');
    if (azKey.length > 0) {
      const azCfg: Record<string, string> = { 'apiKey': azKey, 'region': get('azure_region') };
      const azEndpoint = get('azure_endpoint');
      if (azEndpoint.length > 0) {
        azCfg['endpoint'] = azEndpoint;
      }
      list.push({ id: 'azure', defId: 'azure', name: 'Azure 翻译', enabled: true, config: azCfg });
      changed = true;
    }
    const alId = get('aliyun_ak_id');
    const alSecret = get('aliyun_ak_secret');
    if (alId.length > 0 && alSecret.length > 0) {
      const alCfg: Record<string, string> = { 'accessKeyId': alId, 'accessKeySecret': alSecret };
      list.push({ id: 'aliyun', defId: 'aliyun', name: '阿里云翻译', enabled: true, config: alCfg });
      changed = true;
    }
    const bId = get('baidu_appid');
    const bSecret = get('baidu_secret');
    if (bId.length > 0 && bSecret.length > 0) {
      const bCfg: Record<string, string> = { 'appId': bId, 'secret': bSecret };
      list.push({ id: 'baidu', defId: 'baidu', name: '百度翻译', enabled: true, config: bCfg });
      changed = true;
    }
    // 旧自定义 AI 供应商（OpenAI 兼容）
    const customRaw = get('custom_ai_list');
    if (customRaw.length > 0) {
      for (const it of safeParseArray(customRaw)) {
        const cid = getStr(it, 'id');
        const cname = getStr(it, 'name');
        const cbase = getStr(it, 'baseUrl');
        const cmodel = getStr(it, 'model');
        const ckey = get('aikey_' + cid);
        if (cid.length > 0 && cname.length > 0 && cbase.length > 0) {
          const cfg: Record<string, string> = { 'apiKey': ckey, 'baseUrl': cbase };
          if (cmodel.length > 0) {
            cfg['model'] = cmodel;
          }
          list.push({ id: cid, defId: 'ai-openai-compat', name: cname, enabled: true, config: cfg });
          changed = true;
        }
      }
    }
    // 预置 AI 引擎 Key（ai-deepseek 等）
    const presetIds = ['ai-deepseek', 'ai-glm', 'ai-qwen', 'ai-kimi'];
    for (const pid of presetIds) {
      const key = get('aikey_' + pid);
      if (key.length > 0) {
        const cfg: Record<string, string> = { 'apiKey': key };
        const base = get('ai_base_' + pid);
        const model = get('ai_model_' + pid);
        if (base.length > 0) {
          cfg['baseUrl'] = base;
        }
        if (model.length > 0) {
          cfg['model'] = model;
        }
        list.push({ id: pid, defId: pid, name: pid, enabled: true, config: cfg });
        changed = true;
      }
    }

    if (changed) {
      // 旧默认 AI 引擎若在迁移列表中，保留其作为默认引擎
      const legacyDefaultAI = get('default_ai');
      const migrated = list.some((s: ServiceItem): boolean => s.id === legacyDefaultAI);
      if (migrated) {
        this.pref.putSync('engine_id', legacyDefaultAI);
      }
      // 写入服务列表（迁移后的凭证进入新模型）
      this.pref.putSync('services_list', JSON.stringify(list.map((s: ServiceItem): SerializedService => {
        return {
          id: s.id,
          defId: s.defId,
          name: s.name,
          enabled: s.enabled ? '1' : '0',
          config: s.config
        };
      })));
    }
    this.pref.putSync('services_migrated', true);
    this.pref.flush();
  }

  // ---- 默认引擎 ----
  getEngineId(): string {
    return this.pref?.getSync('engine_id', 'edge') as string;
  }

  setEngineId(id: string): Promise<void> {
    return this.put('engine_id', id);
  }

  // ---- 深色模式（'system' | 'light' | 'dark'）----
  getColorModePref(): string {
    return this.pref?.getSync('color_mode', 'system') as string;
  }

  setColorModePref(v: string): Promise<void> {
    return this.put('color_mode', v);
  }

  // ---- 语言对 ----
  getFromLang(): string {
    return this.pref?.getSync('from_lang', 'auto') as string;
  }

  setFromLang(code: string): Promise<void> {
    return this.put('from_lang', code);
  }

  getToLang(): string {
    return this.pref?.getSync('to_lang', 'en') as string;
  }

  setToLang(code: string): Promise<void> {
    return this.put('to_lang', code);
  }

  // ---- 拍照翻译：照片是否保存到系统相册（默认仅临时文件，识别后删除） ----
  getOcrSaveToGallery(): boolean {
    return this.pref?.getSync('ocr_save_to_gallery', false) as boolean;
  }

  setOcrSaveToGallery(v: boolean): Promise<void> {
    return this.put('ocr_save_to_gallery', v);
  }

  // ---- 开发者模式（关于页连点图标 5 次开启；关闭时入口隐藏、日志系统同步关闭） ----
  getDevMode(): boolean {
    return this.pref?.getSync('dev_mode', false) as boolean;
  }

  setDevMode(v: boolean): Promise<void> {
    return this.put('dev_mode', v);
  }

  // ---- 备份与恢复 ----
  /** 上次备份时间戳（0=从未备份）。偏好未初始化/值异常时返回 0，避免上游算出 NaN */
  getLastBackupAt(): number {
    const v = this.pref !== null ? this.pref.getSync('last_backup_at', 0) : 0;
    return typeof v === 'number' && isFinite(v) ? v : 0;
  }

  setLastBackupAt(v: number): Promise<void> {
    return this.put('last_backup_at', v);
  }
}

export const settingsStore = new SettingsStore();
