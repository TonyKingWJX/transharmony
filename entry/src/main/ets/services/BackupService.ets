import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';
import { settingsStore, ServiceItem } from './SettingsStore';
import { historyStore, NewHistoryItem } from './HistoryStore';
import { TranslateUseCase } from './TranslateUseCase';
import { devLogStore } from './DevLogStore';
import { TransImageStore, ImageFileData } from '../utils/TransImageStore';
import { PILL_VERSION_KEY } from '../components/EngineSelector';

/**
 * 本地备份与恢复：
 * - 备份内容：全部历史记录（含回收站）+ 服务商配置（含密钥）+ 偏好设置，打包 JSON 后
 *   以「用户密码 PBKDF2 派生 AES-256-GCM 密钥」整包加密。
 * - 图片翻译的原图可选携带（调用方传入 includeImages，勾选项在备份密码弹窗）：
 *   collectForBackup 只收集被历史记录引用的沙箱副本。
 * - 备份位置：系统 DOWNLOAD 模式自动创建的 Download/<包名>/ 目录（免选择界面、
 *   免权限、返回 URI 自带持久化权限）。文件名：鸿译备份_时间.htrans。
 * - 恢复：DocumentViewPicker 拉起系统文件管理器选文件（临时读权限），输入密码解密，
 *   历史可选「合并（按 原文+译文+时间 去重）/覆盖」，服务商与偏好整体替换；
 *   覆盖模式先清空沙箱图片目录再回写备份携带的图片。
 *
 * 安全说明：官方文档注明 DOWNLOAD 目录无访问隔离，故凭证明文不可落盘——
 * 本文件整体加密（AES-GCM 认证加密），无密码不可还原。
 */

/** 文件头魔数 "THBK1"（TransHarmony Backup v1） */
const MAGIC: Uint8Array = new Uint8Array([0x54, 0x48, 0x42, 0x4b, 0x31]);
const SALT_LEN = 16;
const IV_LEN = 12;
const TAG_LEN = 16;
const PBKDF2_ITERATIONS = 60000;
const HEADER_LEN = MAGIC.length + SALT_LEN + IV_LEN;

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
}

/** 备份文件解密后的完整载荷（SettingsPage 确认弹窗用） */
export interface BackupPayload {
  version: number;
  app: string;
  exportedAt: number;
  history: BackupHistoryRow[];
  services: ServiceItem[];
  prefs: BackupPrefs;
  /** 图片翻译原图（可选携带；恢复时写回沙箱） */
  images: ImageFileData[];
}

/** 恢复结果摘要（UI toast 用） */
export interface RestoreSummary {
  historyAdded: number;
  historyReplaced: boolean;
  serviceCount: number;
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

  /** 加密 JSON 明文 → THBK1|salt|iv|cipher|tag 单文件字节流 */
  private static async encryptPayload(json: string, password: string): Promise<Uint8Array> {
    const salt = BackupService.random(SALT_LEN);
    const iv = BackupService.random(IV_LEN);
    const header = new Uint8Array(HEADER_LEN);
    header.set(MAGIC, 0);
    header.set(salt, MAGIC.length);
    header.set(iv, MAGIC.length + SALT_LEN);
    const key = await BackupService.toSymKey(await BackupService.deriveKey(password, salt));
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

  /** 解密文件字节流 → JSON 明文（密码错误/文件损坏时抛错） */
  private static async decryptPayload(bytes: Uint8Array, password: string): Promise<BackupPayload> {
    if (bytes.length <= HEADER_LEN + TAG_LEN) {
      throw new Error('备份文件已损坏');
    }
    for (let i = 0; i < MAGIC.length; i++) {
      if (bytes[i] !== MAGIC[i]) {
        throw new Error('不是鸿译备份文件');
      }
    }
    const header = bytes.slice(0, HEADER_LEN);
    const salt = bytes.slice(MAGIC.length, MAGIC.length + SALT_LEN);
    const iv = bytes.slice(MAGIC.length + SALT_LEN, HEADER_LEN);
    const tag = bytes.slice(bytes.length - TAG_LEN);
    const ct = bytes.slice(HEADER_LEN, bytes.length - TAG_LEN);
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
   * includeImages=true 时携带图片翻译原图。
   * 返回备份文件名；用户取消（picker 返回空）返回空串。
   */
  /** 立即备份（失败采集日志） */
  static async backup(ctx: common.UIAbilityContext, password: string, includeImages: boolean): Promise<string> {
    try {
      return await BackupService.doBackup(ctx, password, includeImages);
    } catch (e) {
      devLogStore.append('error', 'backup', '备份失败：' + ((e instanceof Error) ? e.message : String(e)));
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  private static async doBackup(ctx: common.UIAbilityContext, password: string, includeImages: boolean): Promise<string> {
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
      version: 1,
      app: 'transharmony',
      exportedAt: now,
      history: rows,
      services: settingsStore.getServices(),
      prefs: {
        engineId: settingsStore.getEngineId(),
        colorMode: settingsStore.getColorModePref(),
        fromLang: settingsStore.getFromLang(),
        toLang: settingsStore.getToLang(),
        ocrSaveGallery: settingsStore.getOcrSaveToGallery(),
        builtinAdded: settingsStore.getBuiltinAdded(),
        builtinEnabled: settingsStore.getBuiltinEnabled(),
        builtinOrder: settingsStore.getBuiltinOrder(),
        engineChipOrder: settingsStore.getEngineChipOrder()
      },
      images: includeImages ? await TransImageStore.collectForBackup(ctx) : []
    };
    const bytes = await BackupService.encryptPayload(JSON.stringify(payload), password);
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
    if (payload.images.length > 0) {
      text += ' · 图片 ' + payload.images.length + ' 张';
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

    // 图片：覆盖模式先清空沙箱图片目录，再把备份携带的图片写回，最后清孤儿
    if (historyReplace) {
      TransImageStore.clearAll(ctx);
    }
    TransImageStore.writeAll(ctx, payload.images);
    await TransImageStore.cleanOrphans(ctx);

    // 服务商与偏好整体替换
    await settingsStore.setServices(payload.services);
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
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    AppStorage.setOrCreate('pref_engine_id', p.engineId);
    AppStorage.setOrCreate('pref_from_lang', p.fromLang);
    AppStorage.setOrCreate('pref_to_lang', p.toLang);
    return { historyAdded: rows.length, historyReplaced: historyReplace, serviceCount: payload.services.length };
  }
}
