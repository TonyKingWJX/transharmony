import { fileIo } from '@kit.CoreFileKit';
import zlib from '@ohos.zlib';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AssetVault } from '../AssetVault';
import pluginHost from 'libpluginhost.so';

/**
 * .bobplugin 安装器：zip 解压 → info.json 校验 → 沙箱落盘 → 登记持久化 → 加载进运行时。
 *
 * Bob 插件包结构（.bobplugin = zip）：根目录 info.json + main.js（+ 可选 icon.png/libs）。
 * info.json 关键字段（bobtranslate.com/plugin/quickstart/info.html）：
 *   identifier（数字+小写字母+.）/ version / category（translate|ocr|tts 单值）/ name /
 *   options: [{identifier, type: text|menu, title, defaultValue?, textConfig?, menuValues?}]
 *
 * 持久化：已安装列表存 Preferences「transharmony_plugins」；插件目录 filesDir/plugins/<identifier>/<version>；
 * 选项值存 Preferences key「cfg_<pluginId>_<identifier>」（secure 选项改 Asset Vault 属 UI 阶段工作）。
 */

/** 已安装插件记录 */
export interface InstalledPlugin {
  pluginId: string;
  name: string;
  version: string;
  category: string; // translate | ocr | tts
  /** 插件来源：'bob' | 'manggo'（旧记录缺省按 bob 显示） */
  source: string;
  dir: string; // 解压根目录
  mainPath: string;
  infoJson: string; // info.json 原文（加载时透传给 $info）
}

const PREF_STORE = 'transharmony_plugins';
const PREF_LIST_KEY = 'installed_list';
const CATEGORIES: string[] = ['translate', 'ocr', 'tts'];

/** 插件实例的 ServiceItem id（与 BobPluginEngine.pluginServiceId 一致；本地实现避免循环依赖） */
function pluginServiceAlias(pluginId: string): string {
  return 'plugin-' + pluginId;
}

export class PluginInstaller {
  /** 从 rawfile 内置 .bobplugin 安装（验证安装管线；外部文件导入走 installFromBytes） */
  static async installFromRawfile(ctx: common.UIAbilityContext, rawName: string,
    allowedCategories: string[] = CATEGORIES): Promise<InstalledPlugin> {
    const raw = await ctx.resourceManager.getRawFileContent(rawName);
    return PluginInstaller.installFromBytes(ctx, raw, allowedCategories);
  }

  /** 从文件字节安装（文件管理器导入：DocumentViewPicker 读取后传入） */
  static async installFromBytes(ctx: common.UIAbilityContext, bytes: Uint8Array,
    allowedCategories: string[] = CATEGORIES): Promise<InstalledPlugin> {
    const zipPath = `${ctx.cacheDir}/import_${Date.now()}.bobplugin`;
    const f = fileIo.openSync(zipPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer, { length: bytes.byteLength });
    fileIo.closeSync(f);
    return PluginInstaller.installFromZip(ctx, zipPath, allowedCategories);
  }

  /** 安装：解压 → 校验 → 落盘 → 登记（allowedCategories 限制可安装类别，默认三类全收） */
  static async installFromZip(ctx: common.UIAbilityContext, zipPath: string,
    allowedCategories: string[] = CATEGORIES): Promise<InstalledPlugin> {
    // 1) 解压到临时目录（读 info.json 确定标识与版本）
    const tmpDir = `${ctx.cacheDir}/unzip_${Date.now()}`;
    fileIo.mkdirSync(tmpDir, true);
    await zlib.decompressFile(zipPath, tmpDir);

    const infoPath = `${tmpDir}/info.json`;
    if (!fileIo.accessSync(infoPath)) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('不是有效的 Bob 插件包：缺少 info.json');
    }
    const infoJson = fileIo.readTextSync(infoPath);
    const info = JSON.parse(infoJson) as Record<string, Object>;
    const identifier = PluginInstaller.strField(info, 'identifier');
    const version = PluginInstaller.strField(info, 'version');
    const category = PluginInstaller.strField(info, 'category');
    const name = PluginInstaller.strField(info, 'name');
    if (identifier === '' || version === '' || name === '') {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('info.json 缺少必填字段（identifier/version/name）');
    }
    if (CATEGORIES.indexOf(category) < 0) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error(`不支持的插件类型: ${category}（仅支持 translate/ocr/tts）`);
    }
    if (allowedCategories.indexOf(category) < 0) {
      PluginInstaller.rmDir(tmpDir);
      const label = category === 'ocr' ? 'OCR' : (category === 'tts' ? 'TTS' : category);
      throw new Error(`已识别为 ${label} 插件，该类型暂不支持，后续版本开放`);
    }
    const mainPath = `${tmpDir}/main.js`;
    if (!fileIo.accessSync(mainPath)) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('不是有效的 Bob 插件包：缺少 main.js');
    }

    // 2) 正式落盘：filesDir/plugins/<identifier>/<version>（重装覆盖）
    const destDir = `${ctx.filesDir}/plugins/${identifier}/${version}`;
    PluginInstaller.rmDir(destDir);
    fileIo.mkdirSync(destDir, true);
    await zlib.decompressFile(zipPath, destDir);
    PluginInstaller.rmDir(tmpDir);
    fileIo.unlinkSync(zipPath);

    // 3) 登记
    const rec: InstalledPlugin = {
      pluginId: identifier,
      name: name,
      version: version,
      category: category,
      source: 'bob',
      dir: destDir,
      mainPath: `${destDir}/main.js`,
      infoJson: infoJson
    };
    const list = await PluginInstaller.list(ctx);
    const idx = list.findIndex(p => p.pluginId === rec.pluginId);
    if (idx >= 0) {
      list[idx] = rec;
    } else {
      list.push(rec);
    }
    await PluginInstaller.saveList(ctx, list);
    return rec;
  }

  /** 已安装列表 */
  static async list(ctx: common.UIAbilityContext): Promise<InstalledPlugin[]> {
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    const raw = await store.get(PREF_LIST_KEY, '[]') as string;
    try {
      return JSON.parse(raw) as InstalledPlugin[];
    } catch (e) {
      return [];
    }
  }

  /** 加载已安装插件进运行时（确保 runtime 已启动；读取 main.js + 附加 .js 模块 + 组装 configJson） */
  static async loadInstalled(ctx: common.UIAbilityContext, rec: InstalledPlugin,
    valuesOverride?: Record<string, string>): Promise<string> {
    await pluginHost.initRuntime();
    const mainJs = fileIo.readTextSync(rec.mainPath);
    const configJson = await PluginInstaller.buildConfigJson(ctx, rec, valuesOverride);
    const modulesJson = PluginInstaller.collectModules(ctx, rec);
    // $file 沙箱目录：插件可写区（卸载随插件目录一起清除）；
    // 传包名供 native 侧把 ArkTS 虚拟路径解析为真实路径（native 看不见 /data/storage 虚拟视图）
    const sandboxDir = `${ctx.filesDir}/plugin_sandbox/${rec.pluginId}`;
    try {
      if (!fileIo.accessSync(sandboxDir)) {
        fileIo.mkdirSync(sandboxDir, true);
      }
    } catch (e) {
      // 已存在等场景忽略
    }
    return pluginHost.loadPlugin(rec.pluginId, mainJs, configJson, modulesJson,
      rec.dir, sandboxDir, ctx.applicationInfo.name);
  }

  /** 收集插件包内全部 .js 源码（相对路径 → 源码），供沙盒内 CommonJS require */
  private static collectModules(ctx: common.UIAbilityContext, rec: InstalledPlugin): string {
    const modules: Record<string, string> = {};
    try {
      const names = fileIo.listFileSync(rec.dir);
      for (const name of names) {
        if (name.length > 3 && name.substring(name.length - 3) === '.js') {
          modules[name] = fileIo.readTextSync(`${rec.dir}/${name}`);
        }
      }
    } catch (e) {
      // 目录读取失败按无附加模块处理
    }
    return JSON.stringify(modules);
  }

  /** 组装 configJson：{info: <info.json 原文对象>, option: {identifier: value}}。
   *  textConfig.secure 的选项从 ASSET 读取（别名规则与官方服务商一致），缺失时回退默认值。 */
  static async buildConfigJson(ctx: common.UIAbilityContext, rec: InstalledPlugin,
    valuesOverride?: Record<string, string>): Promise<string> {
    const info = JSON.parse(rec.infoJson) as Record<string, Object>;
    const rawOptions = info['options'];
    const items = Array.isArray(rawOptions) ? rawOptions as Array<Record<string, Object>> : [];
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    const option: Record<string, string> = {};
    for (const item of items) {
      const id = PluginInstaller.strField(item, 'identifier');
      if (id === '') {
        continue;
      }
      const def = PluginInstaller.strField(item, 'defaultValue');
      const stored = await store.get(`cfg_${rec.pluginId}_${id}`, '') as string;
      let value = stored !== '' ? stored : def;
      if (valuesOverride !== undefined && valuesOverride[id] !== undefined) {
        value = valuesOverride[id];
      }
      // secure 选项（textConfig.type === 'secure'）：以 ASSET 为准
      if (PluginInstaller.isSecureOption(item)) {
        const secret = AssetVault.read(`${pluginServiceAlias(rec.pluginId)}_${id}`);
        if (secret !== '') {
          value = secret;
        }
      }
      option[id] = value;
    }
    const configObj: Record<string, Object> = { 'info': info, 'option': option };
    return JSON.stringify(configObj);
  }

  /** 选项是否为密钥类（textConfig.type === 'secure'） */
  static isSecureOption(item: Record<string, Object>): boolean {
    const tc = item['textConfig'];
    if (typeof tc !== 'object' || tc === null || Array.isArray(tc)) {
      return false;
    }
    const t = (tc as Record<string, Object>)['type'];
    return t === 'secure';
  }

  /** 解析插件 info.json 中的 secure 选项 identifier 列表（卸载清密钥用） */
  static secureOptionIds(rec: InstalledPlugin): string[] {
    const out: string[] = [];
    try {
      const info = JSON.parse(rec.infoJson) as Record<string, Object>;
      const rawOptions = info['options'];
      const items = Array.isArray(rawOptions) ? rawOptions as Array<Record<string, Object>> : [];
      for (const item of items) {
        const id = PluginInstaller.strField(item, 'identifier');
        if (id !== '' && PluginInstaller.isSecureOption(item)) {
          out.push(id);
        }
      }
    } catch (e) {
      // info.json 异常按无密钥项处理
    }
    return out;
  }

  /** 保存单个选项值：secure → ASSET，其余 → Preferences（插件配置页保存用） */
  static async saveOptionValue(ctx: common.UIAbilityContext, pluginId: string,
    item: Record<string, Object>, value: string): Promise<void> {
    const id = PluginInstaller.strField(item, 'identifier');
    if (id === '') {
      return;
    }
    if (PluginInstaller.isSecureOption(item)) {
      const alias = `${pluginServiceAlias(pluginId)}_${id}`;
      if (value.length > 0) {
        await AssetVault.write(alias, value);
      } else {
        AssetVault.remove(alias);
      }
      return;
    }
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    await store.put(`cfg_${pluginId}_${id}`, value);
    await store.flush();
  }

  /** 卸载：删登记 + 删沙箱插件目录 + 清理该插件的 ASSET 密钥（不动 services_list，由调用方处理） */
  static async uninstall(ctx: common.UIAbilityContext, pluginId: string,
    secureKeys: string[] = []): Promise<void> {
    const list = await PluginInstaller.list(ctx);
    const hit = list.find(p => p.pluginId === pluginId);
    const rest = list.filter(p => p.pluginId !== pluginId);
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    await store.put(PREF_LIST_KEY, JSON.stringify(rest));
    await store.flush();
    if (hit !== undefined) {
      PluginInstaller.rmDir(`${ctx.filesDir}/plugins/${pluginId}`);
      PluginInstaller.rmDir(`${ctx.filesDir}/plugin_sandbox/${pluginId}`);
    }
    for (const key of secureKeys) {
      AssetVault.remove(`${pluginServiceAlias(pluginId)}_${key}`);
    }
  }

  private static async saveList(ctx: common.UIAbilityContext, list: InstalledPlugin[]): Promise<void> {
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    await store.put(PREF_LIST_KEY, JSON.stringify(list));
    await store.flush();
  }

  private static strField(obj: Record<string, Object>, key: string): string {
    const v = obj[key];
    return typeof v === 'string' ? v as string : '';
  }

  private static rmDir(dir: string): void {
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      // 目录不存在等场景忽略
    }
  }
}
