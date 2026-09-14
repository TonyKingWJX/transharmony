import { fileIo } from '@kit.CoreFileKit';
import zlib from '@ohos.zlib';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { AssetVault } from '../AssetVault';
import { devLogStore } from '../DevLogStore';
import pluginHost from 'libpluginhost.so';
import {
  manggoCategoryOfKind,
  manggoServiceId,
  parseManggoConfigItems,
  parseManggoServices,
  isSupportedManggoService,
  transformManggoEsm,
  transformManggoModule,
  buildManggoRegisterSnippetFor,
  resolvePluginIconPath
} from './ManggoTypes';

/**
 * 插件安装器：zip 解压 → 清单校验 → 沙箱落盘 → 登记持久化 → 加载进运行时。
 * 支持两种插件包（均按 zip 解压，以根目录清单文件区分）：
 *  - .bobplugin（info.json，Bob 单服务模型，category 单值）；
 *  - .mplugin（manggo.plugin.json，Manggo 多服务模型，services[] 按 kind 归类）。
 *
 * Bob info.json 关键字段（bobtranslate.com/plugin/quickstart/info.html）：
 *   identifier（数字+小写字母+.）/ version / category（translate|ocr|tts 单值）/ name /
 *   options: [{identifier, type: text|menu, title, defaultValue?, textConfig?, menuValues?}]
 *
 * 持久化：已安装列表存 Preferences「transharmony_plugins」；插件目录 filesDir/plugins/<identifier>/<version>；
 * Bob 选项值存 Preferences key「cfg_<pluginId>_<identifier>」；
 * Manggo 配置值存 Preferences key「cfg_<pluginId>_<serviceId>_<key>」（secure 选项存 Asset Vault）。
 */

/** 已安装插件记录 */
export interface InstalledPlugin {
  pluginId: string;
  name: string;
  version: string;
  /** Bob：info.json category；Manggo：首个受支持服务的 kind 映射（多服务插件取首个） */
  category: string; // translate | ocr | tts
  /** 插件来源：'bob' | 'manggo'（旧记录缺省按 bob 显示） */
  source: string;
  dir: string; // 解压根目录
  mainPath: string;
  /** Bob：info.json 原文（加载时透传给 $info）；Manggo：manggo.plugin.json 原文 */
  infoJson: string;
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

  /** 安装：解压 → 校验 → 落盘 → 登记（allowedCategories 限制可安装类别，默认三类全收；失败采集日志） */
  static async installFromZip(ctx: common.UIAbilityContext, zipPath: string,
    allowedCategories: string[] = CATEGORIES): Promise<InstalledPlugin> {
    try {
      return await PluginInstaller.doInstallFromZip(ctx, zipPath, allowedCategories);
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      devLogStore.append('error', 'plugin', `安装失败：${msg}`);
      throw new Error(msg);
    }
  }

  private static async doInstallFromZip(ctx: common.UIAbilityContext, zipPath: string,
    allowedCategories: string[] = CATEGORIES): Promise<InstalledPlugin> {
    // 1) 解压到临时目录（读清单确定标识与版本；按根目录清单文件区分 Bob/Manggo）
    const tmpDir = `${ctx.cacheDir}/unzip_${Date.now()}`;
    fileIo.mkdirSync(tmpDir, true);
    await zlib.decompressFile(zipPath, tmpDir);

    if (fileIo.accessSync(`${tmpDir}/manggo.plugin.json`)) {
      return PluginInstaller.installManggo(ctx, zipPath, tmpDir, allowedCategories);
    }

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
    devLogStore.append('info', 'plugin', `安装成功：${name} v${version} (${identifier})`);
    return rec;
  }

  /** Manggo 插件（.mplugin）安装：清单校验 → 落盘 → 登记（多服务插件登记为一条记录，服务经 services[] 解析） */
  private static async installManggo(ctx: common.UIAbilityContext, zipPath: string, tmpDir: string,
    allowedCategories: string[]): Promise<InstalledPlugin> {
    const manifestPath = `${tmpDir}/manggo.plugin.json`;
    const manifestJson = fileIo.readTextSync(manifestPath);
    let manifest: Record<string, Object> = {};
    try {
      manifest = JSON.parse(manifestJson) as Record<string, Object>;
    } catch (e) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('manggo.plugin.json 不是有效的 JSON');
    }
    if (manifest['manifestVersion'] !== 1) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('不支持的 manggo 清单版本（仅支持 manifestVersion: 1）');
    }
    const identifier = PluginInstaller.strField(manifest, 'id');
    const version = PluginInstaller.strField(manifest, 'version');
    const name = PluginInstaller.strField(manifest, 'name');
    if (identifier === '' || version === '' || name === '') {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('manggo.plugin.json 缺少必填字段（id/version/name）');
    }
    // 运行时：固定 bun / manggo.plugin.v1（宿主以 JSVM + ESM 转换层模拟）
    const rawRuntime = manifest['runtime'];
    if (typeof rawRuntime !== 'object' || rawRuntime === null) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('manggo.plugin.json 缺少 runtime 字段');
    }
    const runtime = rawRuntime as Record<string, Object>;
    const api = PluginInstaller.strField(runtime, 'api');
    if (api !== 'manggo.plugin.v1') {
      PluginInstaller.rmDir(tmpDir);
      throw new Error(`不支持的插件 API 版本: ${api}（仅支持 manggo.plugin.v1）`);
    }
    const mainFile = PluginInstaller.strField(runtime, 'main') !== ''
      ? PluginInstaller.strField(runtime, 'main') : 'main.js';
    // 服务：至少一个受支持类别（translation/ocr/speech；wordbook/action 暂不支持）
    const services = parseManggoServices(manifestJson).filter((s): boolean => isSupportedManggoService(s));
    if (services.length === 0) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('插件未包含受支持的服务（翻译 / OCR / 语音）');
    }
    if (!fileIo.accessSync(`${tmpDir}/${mainFile}`)) {
      PluginInstaller.rmDir(tmpDir);
      throw new Error('不是有效的 manggo 插件包：缺少 ' + mainFile);
    }

    // 落盘：filesDir/plugins/<id>/<version>（重装覆盖）
    const destDir = `${ctx.filesDir}/plugins/${identifier}/${version}`;
    PluginInstaller.rmDir(destDir);
    fileIo.mkdirSync(destDir, true);
    await zlib.decompressFile(zipPath, destDir);
    PluginInstaller.rmDir(tmpDir);
    fileIo.unlinkSync(zipPath);

    // 类别：首个受支持服务的 kind（多服务插件归入首个板块）
    const category = manggoCategoryOfKind(services[0].kind);
    const rec: InstalledPlugin = {
      pluginId: identifier,
      name: name,
      version: version,
      category: category,
      source: 'manggo',
      dir: destDir,
      mainPath: `${destDir}/${mainFile}`,
      infoJson: manifestJson
    };
    const list = await PluginInstaller.list(ctx);
    const idx = list.findIndex(p => p.pluginId === rec.pluginId);
    if (idx >= 0) {
      list[idx] = rec;
    } else {
      list.push(rec);
    }
    await PluginInstaller.saveList(ctx, list);
    devLogStore.append('info', 'plugin', `安装成功：${name} v${version} (${identifier})`);
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

  /** 加载已安装插件进运行时（确保 runtime 已启动；读取 main.js + 附加 .js 模块 + 组装 configJson）。
   *  Bob：原生脚本直接加载（Bob shim）；Manggo：ESM 转换 + 服务注册代码（manggo 启动脚本）。 */
  static async loadInstalled(ctx: common.UIAbilityContext, rec: InstalledPlugin,
    valuesOverride?: Record<string, string>): Promise<string> {
    await pluginHost.initRuntime();
    try {
      const result = rec.source === 'manggo'
        ? await PluginInstaller.loadManggo(ctx, rec)
        : await PluginInstaller.loadBob(ctx, rec, valuesOverride);
      devLogStore.append('info', 'plugin', `加载成功：${rec.name} v${rec.version} (${rec.pluginId})`);
      return result;
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      devLogStore.append('error', 'plugin', `加载失败：${rec.name} (${rec.pluginId})：${msg}`);
      throw new Error(msg);
    }
  }

  /** Bob 加载（原 loadInstalled 主体，抽出便于错误采集） */
  private static async loadBob(ctx: common.UIAbilityContext, rec: InstalledPlugin,
    valuesOverride?: Record<string, string>): Promise<string> {
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

  /** Manggo 加载：主脚本（注册默认服务）+ 各服务专用脚本（services[].main，IIFE 隔离顶层命名）；
   *  全部经 ESM → 经典脚本转换，配置 = 各服务 config 表单值。 */
  private static async loadManggo(ctx: common.UIAbilityContext, rec: InstalledPlugin): Promise<string> {
    const mainJs = fileIo.readTextSync(rec.mainPath);
    const configJson = await PluginInstaller.buildManggoConfig(ctx, rec);
    const modulesJson = PluginInstaller.collectModules(ctx, rec);
    const sandboxDir = `${ctx.filesDir}/plugin_sandbox/${rec.pluginId}`;
    try {
      if (!fileIo.accessSync(sandboxDir)) {
        fileIo.mkdirSync(sandboxDir, true);
      }
    } catch (e) {
      // 已存在等场景忽略
    }
    const services = parseManggoServices(rec.infoJson).filter((s): boolean => isSupportedManggoService(s));
    const defaultSvcs = services.filter((s): boolean => s.mainScript === '');
    const customSvcs = services.filter((s): boolean => s.mainScript !== '');
    const trMain = transformManggoEsm(mainJs, buildManggoRegisterSnippetFor(defaultSvcs));
    if (trMain.error.length > 0) {
      throw new Error(trMain.error);
    }
    let code = trMain.code;
    for (const svc of customSvcs) {
      const segPath = `${rec.dir}/${svc.mainScript}`;
      if (!fileIo.accessSync(segPath)) {
        throw new Error(`服务 ${svc.id} 的专用脚本不存在: ${svc.mainScript}`);
      }
      const segJs = fileIo.readTextSync(segPath);
      const trSeg = transformManggoEsm(segJs, buildManggoRegisterSnippetFor([svc]));
      if (trSeg.error.length > 0) {
        throw new Error(`服务 ${svc.id} 脚本转换失败: ${trSeg.error}`);
      }
      // IIFE 隔离：各段顶层 const/class 互不冲突；段内注册代码解析本段入口，全局注册器/服务配置照常可达
      code += '\n;(function () {\n' + trSeg.code + '\n})();\n';
    }
    return pluginHost.loadPlugin(rec.pluginId, code, configJson, modulesJson,
      rec.dir, sandboxDir, ctx.applicationInfo.name, 'manggo');
  }

  /** Manggo 配置组装：{manggo: true, services: {<serviceId>: {<key>: 类型化值}}}。
   *  值优先级：ASSET（password）→ Preferences（cfg_<pid>_<sid>_<key>）→ 清单 default；
   *  boolean/integer/decimal 按清单控件类型还原（存储一律为字符串）。 */
  static async buildManggoConfig(ctx: common.UIAbilityContext, rec: InstalledPlugin): Promise<string> {
    const services: Record<string, Object> = {};
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    for (const svc of parseManggoServices(rec.infoJson)) {
      if (!isSupportedManggoService(svc)) {
        continue;
      }
      const cfg: Record<string, Object> = {};
      for (const item of parseManggoConfigItems(svc.configJson)) {
        const key = PluginInstaller.strField(item, 'key');
        if (key === '') {
          continue;
        }
        const control = PluginInstaller.strField(item, 'control');
        const rawDefault = item['default'];
        const defStr = typeof rawDefault === 'string' ? rawDefault as string
          : (typeof rawDefault === 'number' || typeof rawDefault === 'boolean') ? `${rawDefault}` : '';
        let value = await store.get(`cfg_${rec.pluginId}_${svc.id}_${key}`, '') as string;
        if ((value === undefined || value.length === 0) && control === 'password') {
          const secret = AssetVault.read(`${manggoServiceId(rec.pluginId, svc.id)}_${key}`);
          if (secret !== '') {
            value = secret;
          }
        }
        if (value === undefined || value.length === 0) {
          value = defStr;
        }
        let typed: Object = value;
        if (control === 'boolean') {
          typed = value === 'true';
        } else if (control === 'integer') {
          const n = parseInt(value, 10);
          if (!isNaN(n)) {
            typed = n;
          }
        } else if (control === 'decimal') {
          const f = parseFloat(value);
          if (!isNaN(f)) {
            typed = f;
          }
        }
        cfg[key] = typed;
      }
      services[svc.id] = cfg;
    }
    const configObj: Record<string, Object> = { 'manggo': true, 'services': services };
    return JSON.stringify(configObj);
  }

  /** 保存单个 Manggo 服务配置项：password → ASSET，其余 → Preferences（插件配置页保存用） */
  static async saveManggoOptionValue(ctx: common.UIAbilityContext, pluginId: string, serviceId: string,
    item: Record<string, Object>, value: string): Promise<void> {
    const key = PluginInstaller.strField(item, 'key');
    if (key === '') {
      return;
    }
    if (PluginInstaller.strField(item, 'control') === 'password') {
      const alias = `${manggoServiceId(pluginId, serviceId)}_${key}`;
      if (value.length > 0) {
        await AssetVault.write(alias, value);
      } else {
        AssetVault.remove(alias);
      }
      return;
    }
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    await store.put(`cfg_${pluginId}_${serviceId}_${key}`, value);
    await store.flush();
  }

  /** 收集插件包内全部 .js 源码（相对路径 → 源码），供沙盒内 CommonJS require */
  /** 收集插件包内全部 .js 源码（相对路径 → 源码），供沙盒内 CommonJS require。
   *  manggo 插件的模块文件若含 import/export（ESM），先转换为 CommonJS（export 回填 module.exports）。 */
  private static collectModules(ctx: common.UIAbilityContext, rec: InstalledPlugin): string {
    const modules: Record<string, string> = {};
    try {
      const names = fileIo.listFileSync(rec.dir);
      for (const name of names) {
        if (name.length > 3 && name.substring(name.length - 3) === '.js') {
          let src = fileIo.readTextSync(`${rec.dir}/${name}`);
          if (rec.source === 'manggo' && /(^|\n)[ \t]*(import[\s{("' *]|export[ \t{*])/.test(src)) {
            const tr = transformManggoModule(src);
            if (tr.error.length === 0) {
              src = tr.code;
            }
          }
          modules[name] = src;
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

  /** 选项是否为密钥类：textConfig.type === 'secure'，或 Bob 新版标记 isKeyOption === true */
  static isSecureOption(item: Record<string, Object>): boolean {
    if (item['isKeyOption'] === true) {
      return true;
    }
    const tc = item['textConfig'];
    if (typeof tc !== 'object' || tc === null || Array.isArray(tc)) {
      return false;
    }
    const t = (tc as Record<string, Object>)['type'];
    return t === 'secure';
  }

  /** 解析插件 info.json 中的 secure 选项 identifier 列表（仅 Bob；卸载清密钥用） */
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

  /** 收集卸载时需清除的 ASSET 别名（完整别名，uninstall 直接按别名清除）：
   *  Bob：plugin-<pid>_<optIdentifier>；Manggo：plugin-<pid>#<sid>_<cfgKey>（control=password） */
  static secureAliases(rec: InstalledPlugin): string[] {
    const out: string[] = [];
    if (rec.source === 'manggo') {
      for (const svc of parseManggoServices(rec.infoJson)) {
        if (!isSupportedManggoService(svc)) {
          continue;
        }
        const svcAlias = manggoServiceId(rec.pluginId, svc.id);
        for (const item of parseManggoConfigItems(svc.configJson)) {
          const key = PluginInstaller.strField(item, 'key');
          if (key !== '' && PluginInstaller.strField(item, 'control') === 'password') {
            out.push(`${svcAlias}_${key}`);
          }
        }
      }
      return out;
    }
    for (const key of PluginInstaller.secureOptionIds(rec)) {
      out.push(`${pluginServiceAlias(rec.pluginId)}_${key}`);
    }
    return out;
  }

  /** 插件图标绝对路径（Bob info.json icon / manggo 清单 icon；支持字符串或 {universal:...} 对象）。
   *  无图标或路径不存在返回空串。 */
  static pluginIconPath(rec: InstalledPlugin): string {
    try {
      const info = JSON.parse(rec.infoJson) as Record<string, Object>;
      const path = resolvePluginIconPath(rec.dir, info['icon']);
      return path.length > 0 && fileIo.accessSync(path) ? path : '';
    } catch (e) {
      return '';
    }
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
    devLogStore.append('info', 'plugin', `已卸载：${hit !== undefined ? hit.name : pluginId} (${pluginId})`);
    // secureKeys 为完整 ASSET 别名（Bob: plugin-<pid>_<opt>；Manggo: plugin-<pid>#<sid>_<key>）
    for (const key of secureKeys) {
      AssetVault.remove(key);
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

  // ---- 备份与恢复（应用内加密备份携带插件） ----

  /** 递归收集目录下全部文件的相对路径（'' 起步） */
  private static listFilesRecursive(root: string, rel: string): string[] {
    const out: string[] = [];
    const abs = rel === '' ? root : `${root}/${rel}`;
    for (const name of fileIo.listFileSync(abs)) {
      const childRel = rel === '' ? name : `${rel}/${name}`;
      const childAbs = `${root}/${childRel}`;
      if (fileIo.statSync(childAbs).isDirectory()) {
        for (const sub of PluginInstaller.listFilesRecursive(root, childRel)) {
          out.push(sub);
        }
      } else {
        out.push(childRel);
      }
    }
    return out;
  }

  /** 收集单个插件的备份内容（文件 + secure 凭证 + 非密钥选项）；读取失败直接抛错（调用方中止整次备份） */
  static async collectForBackup(ctx: common.UIAbilityContext, rec: InstalledPlugin): Promise<PluginBackup> {
    const b64 = new util.Base64Helper();
    const files: PluginBackupFile[] = [];
    for (const rel of PluginInstaller.listFilesRecursive(rec.dir, '')) {
      const abs = `${rec.dir}/${rel}`;
      const stat = fileIo.statSync(abs);
      const buf = new ArrayBuffer(stat.size);
      const f = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(f.fd, buf);
      } finally {
        fileIo.closeSync(f);
      }
      files.push({ path: rel, dataB64: b64.encodeToStringSync(new Uint8Array(buf)) });
    }
    const credentials: PluginBackupCredential[] = [];
    for (const alias of PluginInstaller.secureAliases(rec)) {
      const value = AssetVault.read(alias);
      if (value !== '') {
        credentials.push({ alias: alias, value: value });
      }
    }
    const options: PluginBackupOption[] = [];
    const store = await preferences.getPreferences(ctx, PREF_STORE);
    const all = await store.getAll() as Record<string, Object>;
    const prefix = `cfg_${rec.pluginId}_`;
    for (const key of Object.keys(all)) {
      const v = all[key];
      if (key.startsWith(prefix) && typeof v === 'string') {
        options.push({ key: key, value: v as string });
      }
    }
    return {
      pluginId: rec.pluginId,
      name: rec.name,
      version: rec.version,
      category: rec.category,
      source: rec.source,
      infoJson: rec.infoJson,
      files: files,
      credentials: credentials,
      options: options
    };
  }

  /** 收集全部已安装插件的备份内容 */
  static async collectAllForBackup(ctx: common.UIAbilityContext): Promise<PluginBackup[]> {
    const list = await PluginInstaller.list(ctx);
    const out: PluginBackup[] = [];
    for (const rec of list) {
      out.push(await PluginInstaller.collectForBackup(ctx, rec));
    }
    return out;
  }

  /** 从备份恢复单个插件：文件直写落盘 → 重建登记 → 回写凭证与选项。
   *  返回登记记录（registerRecord 由调用方执行，避免本文件与 BobPluginEngine 循环依赖） */
  static async restorePlugin(ctx: common.UIAbilityContext, item: PluginBackup): Promise<InstalledPlugin> {
    const destDir = `${ctx.filesDir}/plugins/${item.pluginId}/${item.version}`;
    try {
      PluginInstaller.rmDir(destDir);
      fileIo.mkdirSync(destDir, true);
    } catch (e) {
      const be = e as BusinessError;
      throw new Error(`插件目录准备失败 ${destDir}: ${be.code ?? ''} ${be.message ?? String(e)}`);
    }
    const b64 = new util.Base64Helper();
    for (const f of item.files) {
      const abs = `${destDir}/${f.path}`;
      const idx = f.path.lastIndexOf('/');
      try {
        if (idx > 0) {
          // 注意：截取父目录必须用相对路径 f.path，而非 abs（否则会落到沙箱根目录触发 EACCES）
          fileIo.mkdirSync(`${destDir}/${f.path.substring(0, idx)}`, true);
        }
        const u8 = b64.decodeSync(f.dataB64);
        const out = fileIo.openSync(abs,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          const data = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
          fileIo.writeSync(out.fd, data);
        } finally {
          fileIo.closeSync(out);
        }
      } catch (e) {
        const be = e as BusinessError;
        throw new Error(`插件文件写入失败 ${f.path}: ${be.code ?? ''} ${be.message ?? String(e)}`);
      }
    }
    const rec: InstalledPlugin = {
      pluginId: item.pluginId,
      name: item.name,
      version: item.version,
      category: item.category,
      source: item.source,
      dir: destDir,
      mainPath: `${destDir}/main.js`,
      infoJson: item.infoJson
    };
    const list = await PluginInstaller.list(ctx);
    const i = list.findIndex(p => p.pluginId === rec.pluginId);
    if (i >= 0) {
      list[i] = rec;
    } else {
      list.push(rec);
    }
    await PluginInstaller.saveList(ctx, list);
    for (const c of item.credentials) {
      try {
        await AssetVault.write(c.alias, c.value);
      } catch (e) {
        // 单个凭证回写失败不阻塞整体恢复（用户可到插件配置页重填）
      }
    }
    if (item.options.length > 0) {
      const store = await preferences.getPreferences(ctx, PREF_STORE);
      for (const o of item.options) {
        await store.put(o.key, o.value);
      }
      await store.flush();
    }
    devLogStore.append('info', 'plugin', `插件恢复：${item.name} v${item.version} (${item.pluginId})`);
    return rec;
  }
}

/** 插件备份：单文件条目（相对 rec.dir 路径 + base64 内容） */
export interface PluginBackupFile {
  path: string;
  dataB64: string;
}

/** 插件备份：secure 选项凭证（ASSET 别名 → 明文；由备份整包加密保护） */
export interface PluginBackupCredential {
  alias: string;
  value: string;
}

/** 插件备份：非密钥选项（cfg_<pluginId>_ 前缀 Preferences 键值） */
export interface PluginBackupOption {
  key: string;
  value: string;
}

/** 插件备份条目（BackupPayload.plugins 元素） */
export interface PluginBackup {
  pluginId: string;
  name: string;
  version: string;
  category: string;
  source: string;
  /** 清单原文（info.json / manggo.plugin.json） */
  infoJson: string;
  files: PluginBackupFile[];
  credentials: PluginBackupCredential[];
  options: PluginBackupOption[];
}
