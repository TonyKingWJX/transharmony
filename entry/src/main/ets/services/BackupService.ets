import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { settingsStore, ServiceItem } from './SettingsStore';
import { historyStore, NewHistoryItem } from './HistoryStore';
import { TranslateUseCase } from './TranslateUseCase';
import { devLogStore } from './DevLogStore';
import { TransImageStore } from '../utils/TransImageStore';
import { PluginInstaller, PluginBackup } from './plugin/PluginInstaller';
import { bobPluginEngine } from './plugin/BobPluginEngine';
import { PILL_VERSION_KEY } from '../components/EngineSelector';

/**
 * 本地备份与恢复：
 * - 备份内容（全局）：全部历史记录（含回收站）+ 服务商配置（翻译/TTS/OCR 三列表，含密钥）
 *   + 偏好设置（引擎/语言/深色模式/免费通道/TTS·OCR 服务选择/离线翻译开关）+ 已安装插件
 *   （文件/凭证/选项，见 PluginInstaller.collectForBackup），打包 JSON 后以 AES-256-GCM 整包加密。
 * - 密码可选（v2）：THBK2 头 flags 标记是否密码加密；有密码 PBKDF2 派生密钥，无密码用固定
 *   应用常量派生（格式统一、仅保完整性，等效明文，UI 弹窗已醒目警示）。
 * - 兼容：THBK1（v1，必密码）旧备份文件可正常恢复；旧备份缺少的新字段恢复时保留本机现值。
 * - 备份位置：系统 DOWNLOAD 模式自动创建的 Download/<包名>/ 目录（免选择界面、
 *   免权限、返回 URI 自带持久化权限）。文件名：鸿译备份_时间.htrans。
 * - 恢复：DocumentViewPicker 拉起系统文件管理器选文件；无密码文件免输密码，有密码文件输入
 *   密码解密，历史可选「合并（按 原文+译文+时间 去重）/覆盖」，服务与偏好整体替换，
 *   插件先于服务恢复（ServiceItem 引用插件记录）。
 *
 * 安全说明：官方文档注明 DOWNLOAD 目录无访问隔离——有密码时凭 AES-GCM 认证加密保护；
 * 无密码备份为用户主动选择（弹窗警示不外传），内容等效明文。
 */

/** 文件头魔数 "THBK1"（TransHarmony Backup v1：必密码） */
const MAGIC_V1: Uint8Array = new Uint8Array([0x54, 0x48, 0x42, 0x4b, 0x31]);
/** 文件头魔数 "THBK2"（TransHarmony Backup v2：flags 标记是否密码加密） */
const MAGIC_V2: Uint8Array = new Uint8Array([0x54, 0x48, 0x42, 0x4b, 0x32]);
const SALT_LEN = 16;
const IV_LEN = 12;
const TAG_LEN = 16;
const PBKDF2_ITERATIONS = 60000;
const HEADER_V1_LEN = MAGIC_V1.length + SALT_LEN + IV_LEN;
/** v2 头：magic(5) + flags(1) + salt + iv */
const HEADER_V2_LEN = MAGIC_V2.length + 1 + SALT_LEN + IV_LEN;
const FLAG_HAS_PASSWORD = 0x01;
/** 无密码备份的派生口令（固定常量：仅统一格式与完整性校验，等效明文） */
const NO_PASSWORD_SECRET = 'transharmony.nopwd.v2';

/** 备份 JSON 结构（ArkTS 显式接口） */
interface BackupHistoryRow {
  source: string;
  result: string;
  engineId: string;
  fromLang: string;
  toLang: string;
  favorite: number;
  createdAt: number;
  recordType: number;
  meta: string;
}

interface BackupPrefs {
  engineId: string;
  colorMode: string;
  fromLang: string;
  toLang: string;
  ocrSaveGallery: boolean;
  builtinAdded: string[];
  builtinEnabled: string[];
  builtinOrder: string[];
  engineChipOrder: string[];
  /** v1.0.5：语音/文字识别服务选择（可选；旧备份无此字段，恢复时保留本机现值） */
  ttsEngineId?: string;
  ocrEngineId?: string;
  /** v1.0.5：离线翻译开关（可选；旧备份无此字段） */
  offlineAdded?: boolean;
  offlineEnabled?: boolean;
  offlinePackEnabled?: boolean;
}

/** 备份文件解密后的完整载荷（SettingsPage 确认弹窗用） */
export interface BackupPayload {
  version: number;
  app: string;
  exportedAt: number;
  history: BackupHistoryRow[];
  services: ServiceItem[];
  prefs: BackupPrefs;
  /** v2：已安装插件（可选携带，勾选「包含已安装插件」时存在）；v1 旧备份无此字段 */
  plugins?: PluginBackup[];
  /** v1.0.5：语音服务 TTS / 文字识别 OCR 实例（可选；旧备份无此字段，恢复时保留本机现值） */
  ttsServices?: ServiceItem[];
  ocrServices?: ServiceItem[];
}

/** 备份头信息（选文件后判定是否需要输密码） */
export interface BackupHeaderInfo {
  /** 魔数可识别（THBK1/THBK2） */
  valid: boolean;
  /** 格式版本（1=旧必密码格式；2=v2） */
  version: number;
  /** 是否需要密码解密（THBK1 恒需要；THBK2 按 flags） */
  hasPassword: boolean;
}

/** 恢复结果摘要（UI toast 用） */
export interface RestoreSummary {
  historyAdded: number;
  historyReplaced: boolean;
  serviceCount: number;
  pluginCount: number;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

/** 备份文件名（不含目录）：鸿译备份_20260911_153000.htrans */
function backupFileName(now: number): string {
  const d = new Date(now);
  return '鸿译备份_' + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate())
    + '_' + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds()) + '.htrans';
}

export class BackupService {
  // ---- 加密原语 ----

  private static random(len: number): Uint8Array {
    return cryptoFramework.createRandom().generateRandomSync(len).data;
  }

  /** PBKDF2(SHA256, 6 万次) 从口令派生 32 字节 AES-256 密钥 */
  private static async deriveKey(password: string, salt: Uint8Array): Promise<Uint8Array> {
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: salt,
      iterations: PBKDF2_ITERATIONS,
      keySize: 32
    };
    const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    const secret = await kdf.generateSecret(spec);
    return secret.data;
  }

  private static async toSymKey(keyData: Uint8Array): Promise<cryptoFramework.SymKey> {
    const gen = cryptoFramework.createSymKeyGenerator('AES256');
    const blob: cryptoFramework.DataBlob = { data: keyData };
    return gen.convertKey(blob);
  }

  private static gcmParams(iv: Uint8Array, aad: Uint8Array, tag: Uint8Array): cryptoFramework.GcmParamsSpec {
    return {
      iv: { data: iv } as cryptoFramework.DataBlob,
      aad: { data: aad } as cryptoFramework.DataBlob,
      authTag: { data: tag } as cryptoFramework.DataBlob,
      algName: 'GcmParamsSpec'
    };
  }

  /** 备份口令 → PBKDF2 派生输入：有密码用密码，无密码用固定常量（仅格式/完整性统一） */
  private static kdfPassword(password: string, hasPassword: boolean): string {
    return hasPassword && password.length > 0 ? password : NO_PASSWORD_SECRET;
  }

  /** 加密 JSON 明文 → THBK2|flags|salt|iv|cipher|tag 单文件字节流（v2 格式，恒走此路径） */
  private static async encryptPayload(json: string, password: string, hasPassword: boolean): Promise<Uint8Array> {
    const salt = BackupService.random(SALT_LEN);
    const iv = BackupService.random(IV_LEN);
    const header = new Uint8Array(HEADER_V2_LEN);
    header.set(MAGIC_V2, 0);
    header[MAGIC_V2.length] = hasPassword ? FLAG_HAS_PASSWORD : 0;
    header.set(salt, MAGIC_V2.length + 1);
    header.set(iv, MAGIC_V2.length + 1 + SALT_LEN);
    const kdfPwd = BackupService.kdfPassword(password, hasPassword);
    const key = await BackupService.toSymKey(await BackupService.deriveKey(kdfPwd, salt));
    const params = BackupService.gcmParams(iv, header, new Uint8Array(TAG_LEN));
    const cipher = cryptoFramework.createCipher('AES256|GCM');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const plain: cryptoFramework.DataBlob = {
      data: new Uint8Array(buffer.from(json, 'utf-8').buffer)
    };
    const ct = await cipher.update(plain);
    const tag = await cipher.doFinal(null);
    const out = new Uint8Array(header.length + ct.data.length + tag.data.length);
    out.set(header, 0);
    out.set(ct.data, header.length);
    out.set(tag.data, header.length + ct.data.length);
    return out;
  }

  /** 识别备份头（选文件后 UI 据此决定是否弹密码框）；魔数不符返回 valid=false */
  static peekHeader(bytes: Uint8Array): BackupHeaderInfo {
    const matches = (m: Uint8Array): boolean => {
      if (bytes.length < m.length) {
        return false;
      }
      for (let i = 0; i < m.length; i++) {
        if (bytes[i] !== m[i]) {
          return false;
        }
      }
      return true;
    };
    if (matches(MAGIC_V2)) {
      if (bytes.length < HEADER_V2_LEN) {
        return { valid: false, version: 2, hasPassword: false };
      }
      return { valid: true, version: 2, hasPassword: (bytes[MAGIC_V2.length] & FLAG_HAS_PASSWORD) !== 0 };
    }
    if (matches(MAGIC_V1)) {
      return { valid: true, version: 1, hasPassword: true };
    }
    return { valid: false, version: 0, hasPassword: false };
  }

  /** 解密文件字节流 → JSON 明文（THBK1/THBK2 自适应；密码错误/文件损坏时抛错） */
  private static async decryptPayload(bytes: Uint8Array, password: string): Promise<BackupPayload> {
    const head = BackupService.peekHeader(bytes);
    if (!head.valid) {
      throw new Error('不是鸿译备份文件');
    }
    if (head.version === 2) {
      if (bytes.length <= HEADER_V2_LEN + TAG_LEN) {
        throw new Error('备份文件已损坏');
      }
      const header = bytes.slice(0, HEADER_V2_LEN);
      const salt = bytes.slice(MAGIC_V2.length + 1, MAGIC_V2.length + 1 + SALT_LEN);
      const iv = bytes.slice(MAGIC_V2.length + 1 + SALT_LEN, HEADER_V2_LEN);
      const tag = bytes.slice(bytes.length - TAG_LEN);
      const ct = bytes.slice(HEADER_V2_LEN, bytes.length - TAG_LEN);
      const kdfPwd = BackupService.kdfPassword(password, head.hasPassword);
      const key = await BackupService.toSymKey(await BackupService.deriveKey(kdfPwd, salt));
      const params = BackupService.gcmParams(iv, header, tag);
      const decoder = cryptoFramework.createCipher('AES256|GCM');
      await decoder.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
      const plain = await decoder.update({ data: ct } as cryptoFramework.DataBlob);
      await decoder.doFinal(null); // 认证失败在此抛 17630001（密码错误/篡改）
      if (plain === null || plain === undefined) {
        throw new Error('密码错误或备份文件已损坏');
      }
      return JSON.parse(util.TextDecoder.create('utf-8').decodeToString(plain.data)) as BackupPayload;
    }
    // THBK1（v1 旧格式）：必密码，头 33 字节
    if (bytes.length <= HEADER_V1_LEN + TAG_LEN) {
      throw new Error('备份文件已损坏');
    }
    const header = bytes.slice(0, HEADER_V1_LEN);
    const salt = bytes.slice(MAGIC_V1.length, MAGIC_V1.length + SALT_LEN);
    const iv = bytes.slice(MAGIC_V1.length + SALT_LEN, HEADER_V1_LEN);
    const tag = bytes.slice(bytes.length - TAG_LEN);
    const ct = bytes.slice(HEADER_V1_LEN, bytes.length - TAG_LEN);
    const key = await BackupService.toSymKey(await BackupService.deriveKey(password, salt));
    const params = BackupService.gcmParams(iv, header, tag);
    const decoder = cryptoFramework.createCipher('AES256|GCM');
    await decoder.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
    const plain = await decoder.update({ data: ct } as cryptoFramework.DataBlob);
    await decoder.doFinal(null); // 认证失败在此抛 17630001（密码错误/篡改）
    if (plain === null || plain === undefined) {
      throw new Error('密码错误或备份文件已损坏');
    }
    return JSON.parse(util.TextDecoder.create('utf-8').decodeToString(plain.data)) as BackupPayload;
  }

  // ---- 对外：备份 ----

  /**
   * 立即备份：收集数据 → 加密 → 写 Download/<包名>/。
   * password 可空（空 = 不加密，仅完整性校验）；includePlugins=true 携带已安装插件。
   * 返回备份文件名；用户取消（picker 返回空）返回空串。
   */
  /** 立即备份（失败采集日志） */
  static async backup(ctx: common.UIAbilityContext, password: string, includePlugins: boolean): Promise<string> {
    try {
      return await BackupService.doBackup(ctx, password, includePlugins);
    } catch (e) {
      devLogStore.append('error', 'backup', '备份失败：' + ((e instanceof Error) ? e.message : String(e)));
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  private static async doBackup(ctx: common.UIAbilityContext, password: string, includePlugins: boolean): Promise<string> {
    const history = await historyStore.getAll();
    const rows: BackupHistoryRow[] = [];
    for (const h of history) {
      rows.push({
        source: h.source,
        result: h.result,
        engineId: h.engineId,
        fromLang: h.fromLang,
        toLang: h.toLang,
        favorite: h.favorite,
        createdAt: h.createdAt,
        recordType: h.recordType,
        meta: h.meta
      });
    }
    const now = Date.now();
    const payload: BackupPayload = {
      version: 2,
      app: 'transharmony',
      exportedAt: now,
      history: rows,
      services: settingsStore.getServices(),
      ttsServices: settingsStore.getTtsServices(),
      ocrServices: settingsStore.getOcrServices(),
      prefs: {
        engineId: settingsStore.getEngineId(),
        colorMode: settingsStore.getColorModePref(),
        fromLang: settingsStore.getFromLang(),
        toLang: settingsStore.getToLang(),
        ocrSaveGallery: settingsStore.getOcrSaveToGallery(),
        builtinAdded: settingsStore.getBuiltinAdded(),
        builtinEnabled: settingsStore.getBuiltinEnabled(),
        builtinOrder: settingsStore.getBuiltinOrder(),
        engineChipOrder: settingsStore.getEngineChipOrder(),
        ttsEngineId: settingsStore.getTtsEngineId(),
        ocrEngineId: settingsStore.getOcrEngineId(),
        offlineAdded: settingsStore.getOfflineAdded(),
        offlineEnabled: settingsStore.getOfflineEnabled(),
        offlinePackEnabled: settingsStore.getOfflinePackEnabled()
      }
    };
    if (includePlugins) {
      payload.plugins = await PluginInstaller.collectAllForBackup(ctx);
    }
    const bytes = await BackupService.encryptPayload(JSON.stringify(payload), password, password.length > 0);
    // DOWNLOAD 模式：直达 Download/<包名>/，返回目录 URI（持久化权限）
    const saveOpts = new picker.DocumentSaveOptions();
    saveOpts.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const dvp = new picker.DocumentViewPicker(ctx);
    const uris = await dvp.save(saveOpts);
    if (uris === undefined || uris.length === 0) {
      return '';
    }
    const fileName = backupFileName(now);
    const filePath = new fileUri.FileUri(uris[0] + '/' + fileName).path;
    const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer);
    } finally {
      fs.closeSync(file);
    }
    await settingsStore.setLastBackupAt(now);
    return fileName;
  }

  /** 上次备份时间戳（0=从未备份） */
  static lastBackupAt(): number {
    return settingsStore.getLastBackupAt();
  }

  /** 拉起系统文件管理器选择备份文件，返回文件字节（用户取消返回 null） */
  static async pickBackupFile(ctx: common.UIAbilityContext): Promise<Uint8Array | null> {
    const selOpts = new picker.DocumentSelectOptions();
    selOpts.maxSelectNumber = 1;
    selOpts.fileSuffixFilters = ['鸿译备份(.htrans)|.htrans'];
    const dvp = new picker.DocumentViewPicker(ctx);
    const uris = await dvp.select(selOpts);
    if (uris === undefined || uris.length === 0) {
      return null;
    }
    const path = new fileUri.FileUri(uris[0]).path;
    const stat = fs.statSync(path);
    const buf = new ArrayBuffer(stat.size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buf);
    } finally {
      fs.closeSync(file);
    }
    return new Uint8Array(buf);
  }

  /** 解密并校验文件（密码错误/损坏抛错），返回 payload 给 UI 二次确认（失败采集日志） */
  static async parse(bytes: Uint8Array, password: string): Promise<BackupPayload> {
    try {
      return await BackupService.doParse(bytes, password);
    } catch (e) {
      devLogStore.append('error', 'backup', '备份文件解析失败：' + ((e instanceof Error) ? e.message : String(e)));
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  private static async doParse(bytes: Uint8Array, password: string): Promise<BackupPayload> {
    const payload = await BackupService.decryptPayload(bytes, password);
    if (payload.app !== 'transharmony') {
      throw new Error('不是鸿译的备份文件');
    }
    return payload;
  }

  /** 恢复预览（确认弹窗文案用） */
  static describe(payload: BackupPayload): string {
    const d = new Date(payload.exportedAt);
    let text = '备份时间 ' + d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate())
      + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes())
      + ' · 历史 ' + payload.history.length + ' 条 · 服务商 ' + payload.services.length + ' 个';
    if (payload.ttsServices !== undefined && payload.ttsServices.length > 0) {
      text += ' · 语音 ' + payload.ttsServices.length + ' 个';
    }
    if (payload.ocrServices !== undefined && payload.ocrServices.length > 0) {
      text += ' · 识别 ' + payload.ocrServices.length + ' 个';
    }
    if (payload.plugins !== undefined && payload.plugins.length > 0) {
      text += ' · 插件 ' + payload.plugins.length + ' 个';
    }
    return text;
  }

  /**
   * 应用恢复：历史（合并去重 / 覆盖）、服务商配置与偏好（整体替换，调用方需已二次确认）、
   * 图片回写沙箱（覆盖模式先清空图片目录）。完成后刷新引擎注册表并广播版本号。
   */
  /** 应用恢复入口（失败采集日志） */
  static async apply(payload: BackupPayload, historyReplace: boolean, ctx: common.Context): Promise<RestoreSummary> {
    try {
      return await BackupService.doApply(payload, historyReplace, ctx);
    } catch (e) {
      devLogStore.append('error', 'backup', '恢复失败：' + ((e instanceof Error) ? e.message : String(e)));
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  private static async doApply(payload: BackupPayload, historyReplace: boolean, ctx: common.Context): Promise<RestoreSummary> {
    // 插件：先于服务恢复（payload.services 的插件条目引用插件登记记录）
    let pluginCount = 0;
    if (payload.plugins !== undefined && payload.plugins.length > 0) {
      const uiCtx = ctx as common.UIAbilityContext;
      try {
        for (const item of payload.plugins) {
          const rec = await PluginInstaller.restorePlugin(uiCtx, item);
          bobPluginEngine.registerRecord(rec);
          pluginCount++;
        }
      } catch (e) {
        devLogStore.append('error', 'backup', '恢复失败于插件阶段：' + ((e instanceof Error) ? e.message : String(e)));
        throw new Error('插件恢复阶段：' + ((e instanceof Error) ? e.message : String(e)));
      }
    }
    let rows: NewHistoryItem[] = [];
    for (const r of payload.history) {
      rows.push({
        source: r.source,
        result: r.result,
        engineId: r.engineId,
        fromLang: r.fromLang,
        toLang: r.toLang,
        favorite: r.favorite,
        createdAt: r.createdAt,
        recordType: r.recordType,
        meta: r.meta
      });
    }
    try {
      if (!historyReplace) {
        // 合并：按 原文+译文+时间 去重
        const existing = await historyStore.getAll();
        const keys = new Set<string>();
        for (const it of existing) {
          keys.add(it.source + '\u0001' + it.result + '\u0001' + it.createdAt);
        }
        rows = rows.filter((r: NewHistoryItem): boolean =>
          !keys.has(r.source + '\u0001' + r.result + '\u0001' + r.createdAt));
      }
      await historyStore.restoreAll(rows, historyReplace);

      // 图片不再随备份携带（v2 起）：仅清理孤儿文件；
      // 本机恢复时仍被历史 meta.imgPath 引用的旧原图保留，详情页可继续显示
      await TransImageStore.cleanOrphans(ctx);
    } catch (e) {
      devLogStore.append('error', 'backup', '恢复失败于历史阶段：' + ((e instanceof Error) ? e.message : String(e)));
      throw new Error('历史恢复阶段：' + ((e instanceof Error) ? e.message : String(e)));
    }

    try {
      // 服务商与偏好整体替换（旧备份无 TTS/OCR 列表字段 → 保留本机现值）
      await settingsStore.setServices(payload.services);
      if (payload.ttsServices !== undefined) {
        await settingsStore.setTtsServices(payload.ttsServices);
      }
      if (payload.ocrServices !== undefined) {
        await settingsStore.setOcrServices(payload.ocrServices);
      }
      const p = payload.prefs;
      await settingsStore.setEngineId(p.engineId);
      await settingsStore.setColorModePref(p.colorMode);
      await settingsStore.setFromLang(p.fromLang);
      await settingsStore.setToLang(p.toLang);
      await settingsStore.setOcrSaveToGallery(p.ocrSaveGallery);
      await settingsStore.setBuiltinAdded(p.builtinAdded);
      await settingsStore.setBuiltinEnabled(p.builtinEnabled);
      await settingsStore.setBuiltinOrder(p.builtinOrder);
      await settingsStore.setEngineChipOrder(p.engineChipOrder);
      // v1.0.5 新增：旧备份无这些字段时保留本机现值
      if (p.ttsEngineId !== undefined) {
        await settingsStore.setTtsEngineId(p.ttsEngineId);
      }
      if (p.ocrEngineId !== undefined) {
        await settingsStore.setOcrEngineId(p.ocrEngineId);
      }
      if (p.offlineAdded !== undefined) {
        await settingsStore.setOfflineAdded(p.offlineAdded);
      }
      if (p.offlineEnabled !== undefined) {
        await settingsStore.setOfflineEnabled(p.offlineEnabled);
      }
      if (p.offlinePackEnabled !== undefined) {
        await settingsStore.setOfflinePackEnabled(p.offlinePackEnabled);
      }
    } catch (e) {
      devLogStore.append('error', 'backup', '恢复失败于偏好阶段：' + ((e instanceof Error) ? e.message : String(e)));
      throw new Error('偏好恢复阶段：' + ((e instanceof Error) ? e.message : String(e)));
    }
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    AppStorage.setOrCreate('pref_engine_id', payload.prefs.engineId);
    AppStorage.setOrCreate('pref_from_lang', payload.prefs.fromLang);
    AppStorage.setOrCreate('pref_to_lang', payload.prefs.toLang);
    return { historyAdded: rows.length, historyReplaced: historyReplace, serviceCount: payload.services.length, pluginCount: pluginCount };
  }
}
