/**
 * manggo 插件（manggo.plugin.json / .mplugin）纯工具层：
 *  - 清单解析与多服务模型（services[]: translation/ocr/speech/wordbook/action）；
 *  - 服务 id 约定：ServiceItem id = 'plugin-<pluginId>#<serviceId>'，defId = 'plugin:<pluginId>#<serviceId>'；
 *  - 语言码映射：内部（zh/en…）↔ manggo（zh_CN/en_US…），以及清单 language 映射（manggo码 → 第三方码）；
 *  - ESM → 经典脚本转换（JSVM 无模块加载器）：剥 export / 拒绝 import，尾部附服务注册代码。
 * 本文件不 import 插件层其他模块（供 PluginInstaller 与适配器共同使用，避免循环依赖）。
 */

/** manggo 清单 services[] 中受支持的服务定义 */
export interface ManggoServiceDef {
  id: string;
  kind: string; // translation | ocr | speech | wordbook | action
  displayName: string;
  entry: string;
  /** 翻译结果形态：'text'（默认）| 'dictionary'（结构化词典） */
  resultType: string;
  /** 服务专用脚本（清单 services[].main，相对插件目录）；空串 = 使用 runtime.main 主脚本 */
  mainScript: string;
  /** 服务图标（清单 services[].icon，相对插件目录）；空串 = 无 */
  icon: string;
  /** 清单 language 映射原文 JSON（manggo 码 → 第三方码），无映射为空串 */
  languageJson: string;
  /** 清单 config 表单数组原文 JSON，无配置为空串 */
  configJson: string;
}

/** ServiceItem id/defId 拆解结果 */
export interface ManggoServiceRef {
  pluginId: string;
  serviceId: string;
}

/** 服务 kind → 应用类别（wordbook/action 不支持，返回空串） */
export function manggoCategoryOfKind(kind: string): string {
  if (kind === 'translation') {
    return 'translate';
  }
  if (kind === 'ocr') {
    return 'ocr';
  }
  if (kind === 'speech') {
    return 'tts';
  }
  return '';
}

export function isSupportedManggoKind(kind: string): boolean {
  return manggoCategoryOfKind(kind).length > 0;
}

// ---- 服务 id 约定（'#' 分隔插件标识与服务 id；Bob 插件不含 '#'）----

export function manggoServiceId(pluginId: string, serviceId: string): string {
  return 'plugin-' + pluginId + '#' + serviceId;
}

export function manggoDefId(pluginId: string, serviceId: string): string {
  return 'plugin:' + pluginId + '#' + serviceId;
}

/** 'plugin-<pid>#<sid>' / 'plugin:<pid>#<sid>' / 裸 '<pid>#<sid>' → {pluginId, serviceId} */
export function splitServiceRef(ref: string): ManggoServiceRef {
  const idx = ref.indexOf('#');
  const out: ManggoServiceRef = {
    pluginId: idx >= 0 ? ref.substring(0, idx) : ref,
    serviceId: idx >= 0 ? ref.substring(idx + 1) : ''
  };
  return out;
}

/** 沙盒内入口函数的全局名（服务 id 仅保留字母数字下划线，与注册代码一致） */
export function manggoEntryGlobalName(serviceId: string): string {
  return '__phSvc_' + serviceId.replace(/[^A-Za-z0-9_]/g, '_');
}

// ---- 清单解析 ----

/** 解析清单 services[]（bob 插件的 info.json 无 services，返回空数组） */
export function parseManggoServices(manifestJson: string): ManggoServiceDef[] {
  const out: ManggoServiceDef[] = [];
  if (manifestJson.length === 0) {
    return out;
  }
  let manifest: Record<string, Object>;
  try {
    manifest = JSON.parse(manifestJson) as Record<string, Object>;
  } catch (e) {
    return out;
  }
  const raw = manifest['services'];
  if (!Array.isArray(raw)) {
    return out;
  }
  for (const item of raw as Array<Object>) {
    if (typeof item !== 'object' || item === null) {
      continue;
    }
    const o = item as Record<string, Object>;
    const id = typeof o['id'] === 'string' ? o['id'] as string : '';
    const kind = typeof o['kind'] === 'string' ? o['kind'] as string : '';
    const entry = typeof o['entry'] === 'string' ? o['entry'] as string : '';
    if (id.length === 0 || kind.length === 0 || entry.length === 0) {
      continue;
    }
    let languageJson = '';
    if (typeof o['language'] === 'object' && o['language'] !== null) {
      try {
        languageJson = JSON.stringify(o['language']);
      } catch (e) {
        languageJson = '';
      }
    }
    let configJson = '';
    if (Array.isArray(o['config'])) {
      try {
        configJson = JSON.stringify(o['config']);
      } catch (e) {
        configJson = '';
      }
    }
    const def: ManggoServiceDef = {
      id: id,
      kind: kind,
      displayName: typeof o['displayName'] === 'string' ? o['displayName'] as string : '',
      entry: entry,
      resultType: typeof o['resultType'] === 'string' ? o['resultType'] as string : 'text',
      mainScript: typeof o['main'] === 'string' ? o['main'] as string : '',
      icon: typeof o['icon'] === 'string' ? o['icon'] as string : '',
      languageJson: languageJson,
      configJson: configJson
    };
    out.push(def);
  }
  return out;
}

/** 解析服务 config 表单数组原文（[]） */
export function parseManggoConfigItems(configJson: string): Array<Record<string, Object>> {
  if (configJson.length === 0) {
    return [];
  }
  try {
    const arr = JSON.parse(configJson) as Object;
    return Array.isArray(arr) ? arr as Array<Record<string, Object>> : [];
  } catch (e) {
    return [];
  }
}

/** 服务是否为受支持类别（翻译/OCR/语音） */
export function isSupportedManggoService(svc: ManggoServiceDef): boolean {
  return isSupportedManggoKind(svc.kind);
}

// ---- 语言码映射 ----

// 内部码（BCP-47 主子标签）→ manggo 码（下划线全称）；未收录原样直通
const APP_TO_MANGGO: Record<string, string> = {
  'zh': 'zh_CN',
  'en': 'en_US',
  'ja': 'ja_JP',
  'ko': 'ko_KR',
  'fr': 'fr_FR',
  'de': 'de_DE',
  'ru': 'ru_RU',
  'es': 'es_ES',
  'th': 'th_TH',
  'vi': 'vi_VN',
  'id': 'id_ID',
  'tet': 'tet_TL'
};

/** 内部语言码 → manggo 码（auto 原样） */
export function toManggoLang(code: string): string {
  if (code === 'auto') {
    return 'auto';
  }
  const hit = APP_TO_MANGGO[code];
  return hit !== undefined ? hit : code;
}

/** manggo 码 → 内部语言码（反查映射表，未收录按 xx_YY 前缀启发式） */
export function fromManggoLang(code: string): string {
  if (code === 'auto') {
    return 'auto';
  }
  for (const k of Object.keys(APP_TO_MANGGO)) {
    if (APP_TO_MANGGO[k] === code) {
      return k;
    }
  }
  const i = code.indexOf('_');
  if (i > 0) {
    return code.substring(0, i).toLowerCase();
  }
  return code;
}

/** 应用服务声明语言（manggo 码列表）→ 应用支持语言交集（保序） */
export function mapManggoLangs(mgCodes: string[]): string[] {
  const out: string[] = [];
  for (const raw of mgCodes) {
    const c = fromManggoLang(raw);
    if (c !== 'auto' && !out.includes(c)) {
      out.push(c);
    }
  }
  return out;
}

/** 应用清单语言与插件声明语言取交集（应用 LANGUAGE_LIST 过滤在调用方按需进行） */

/** 服务 language 映射应用：manggo 码 → 第三方码（无映射/未声明时原样返回） */
export function applyManggoLangMap(languageJson: string, mgCode: string): string {
  if (languageJson.length === 0) {
    return mgCode;
  }
  try {
    const m = JSON.parse(languageJson) as Record<string, Object>;
    const v = m[mgCode];
    if (typeof v === 'string') {
      return v as string;
    }
    return mgCode;
  } catch (e) {
    return mgCode;
  }
}

/** 服务声明支持的应用语言（清单 language 的 key 集合；未声明 → 空数组表示全集） */
export function manggoServiceLangs(languageJson: string): string[] {
  if (languageJson.length === 0) {
    return [];
  }
  try {
    const m = JSON.parse(languageJson) as Record<string, Object>;
    return mapManggoLangs(Object.keys(m));
  } catch (e) {
    return [];
  }
}

// ---- ESM → 经典脚本转换（JSVM 无模块加载器）----

export interface ManggoTransformResult {
  code: string;
  error: string; // 非空表示转换失败（原因）
}

/**
 * 把 manggo 插件 main.js（ES Module）转成经典脚本：
 *  - 静态 import（默认/具名/命名空间/裸/混合）→ `__phModRequire('模块')` 解构/取值（相对导入走
 *    沙盒 CommonJS 模块系统，node:crypto 等内置模块由启动脚本提供）；
 *  - `export default X` → `__phDefaultExport = X`；
 *  - `export { a, b as c }` / `export * from '...'` → 删除；
 *  - `export function/async function/class/const/let/var` → 去掉 export 保留声明；
 *  - 头部补 "use strict"（对齐 ESM 隐式严格模式）+ __phDefaultExport 预声明；
 *  - 尾部追加 registerSnippet（服务入口注册，由清单生成）。
 * 转换后的入口函数经 __phManggoRegister 挂到全局 __phSvc_<serviceId>，供 callPluginFn 按名调用。
 */
export function transformManggoEsm(code: string, registerSnippet: string): ManggoTransformResult {
  let out = rewriteManggoImports(code);
  // export default（含 export default async function 等）
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+default[ \t]+/g, '$1$2__phDefaultExport = ');
  // 具名导出列表 / 星号导出（含 re-export）
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\{[^}]*\}[ \t]*;?/g, '$1');
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\*[^;\n]*;?/g, '$1');
  // export 声明（函数/类/变量）
  out = out.replace(/(^|\n)([ \t]*)export(?=[ \t]+(async[ \t]+function|function|class|const|let|var)\b)/g, '$1$2');
  const header = '"use strict";\nvar __phDefaultExport;\n';
  const r: ManggoTransformResult = { code: header + out + registerSnippet, error: '' };
  return r;
}

/** import 语句重写（入口脚本与模块文件共用）：静态/动态 import → __phModRequire */
function rewriteManggoImports(code: string): string {
  let out = code;
  // import 默认 + 具名混合：import X, { a, b as c } from 'mod'
  out = out.replace(/(^|\n)([ \t]*)import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\5/g,
    (_m: string, cr: string, ind: string, def: string, names: string, _q: string, mod: string): string => {
      return cr + ind + 'const __phI = __phModRequire(' + JSON.stringify(mod) + ');\n' + ind
        + 'const ' + def + ' = __phInterop(__phI);\n' + ind + expandNamedImports(names, '__phI');
    });
  // import 默认：import X from 'mod'
  out = out.replace(/(^|\n)([ \t]*)import\s+([A-Za-z_$][\w$]*)\s*from\s*(['"])([^'"]+)\4/g,
    (_m: string, cr: string, ind: string, def: string, _q: string, mod: string): string => {
      return cr + ind + 'const ' + def + ' = __phInterop(__phModRequire(' + JSON.stringify(mod) + '));';
    });
  // import 具名：import { a, b as c } from 'mod'
  out = out.replace(/(^|\n)([ \t]*)import\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\4/g,
    (_m: string, cr: string, ind: string, names: string, _q: string, mod: string): string => {
      return cr + ind + 'const __phI = __phModRequire(' + JSON.stringify(mod) + ');\n' + ind
        + expandNamedImports(names, '__phI');
    });
  // import 命名空间：import * as ns from 'mod'
  out = out.replace(/(^|\n)([ \t]*)import\s*\*\s*as\s+([A-Za-z_$][\w$]*)\s*from\s*(['"])([^'"]+)\4/g,
    (_m: string, cr: string, ind: string, ns: string, _q: string, mod: string): string => {
      return cr + ind + 'const ' + ns + ' = __phModRequire(' + JSON.stringify(mod) + ');';
    });
  // 裸导入：import 'mod'
  out = out.replace(/(^|\n)([ \t]*)import\s*(['"])([^'"]+)\3/g,
    (_m: string, cr: string, ind: string, _q: string, mod: string): string => {
      return cr + ind + '__phModRequire(' + JSON.stringify(mod) + ');';
    });
  // 动态 import(...) → __phModRequire(...)（尽力而为：同步返回，不支持真正的异步加载）
  out = out.replace(/\bimport\s*\(/g, '__phModRequire(');
  return out;
}

/**
 * 包内模块文件的 ESM → CommonJS 转换（供沙盒 __phRequire 执行）：
 *  - import 同入口脚本规则重写；export 具名/默认/星号 → 末尾回填 module.exports；
 *  - 相对/裸模块名由模块系统解析，node:crypto 等内置模块同入口脚本。
 */
export function transformManggoModule(code: string): ManggoTransformResult {
  let out = rewriteManggoImports(code);
  const tail: string[] = [];
  // export default（表达式/具名函数均可，末尾统一挂 default）
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+default[ \t]+/g, '$1$2__phModDefault = ');
  // export { a, b as c }：本文件具名导出 → 末尾回填
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\{([^}]*)\}[ \t]*;?/g,
    (_m: string, cr: string, names: string): string => {
      for (const raw of names.split(',')) {
        const seg = raw.trim();
        if (seg.length === 0) {
          continue;
        }
        const asIdx = seg.indexOf(' as ');
        const local = asIdx >= 0 ? seg.substring(0, asIdx).trim() : seg;
        const exported = asIdx >= 0 ? seg.substring(asIdx + 4).trim() : seg;
        if (/^[A-Za-z_$][\w$]*$/.test(exported)) {
          tail.push('module.exports[' + JSON.stringify(exported) + '] = ' + local + ';');
        }
      }
      return cr;
    });
  // export * from 'mod'：整体转嫁
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\*[ \t]+from[ \t]*(['"])([^'"]+)\2[ \t]*;?/g,
    (_m: string, cr: string, _q: string, mod: string): string => {
      return cr + 'Object.assign(module.exports, __phModRequire(' + JSON.stringify(mod) + '));';
    });
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\*[ \t]*;?/g, '$1');
  // export 声明（函数/类/变量）：剥 export + 收集导出名
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+((?:async[ \t]+)?function|class)[ \t]+([A-Za-z_$][\w$]*)/g,
    (_m: string, cr: string, ind: string, kind: string, name: string): string => {
      tail.push('module.exports[' + JSON.stringify(name) + '] = ' + name + ';');
      return cr + ind + kind + ' ' + name;
    });
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+(const|let|var)[ \t]+([^;\n]*)/g,
    (_m: string, cr: string, ind: string, kw: string, head: string): string => {
      for (const part of head.split('=')) {
        const seg = part.trim();
        if (seg.length === 0 || seg.indexOf('(') >= 0 || seg.indexOf('[') >= 0) {
          continue; // 函数调用/解构声明不取导出名
        }
        const m = seg.match(/^([A-Za-z_$][\w$]*)/);
        if (m !== null && m[1] !== 'function') {
          tail.push('module.exports[' + JSON.stringify(m[1]) + '] = ' + m[1] + ';');
        }
      }
      return cr + ind + kw + ' ' + head;
    });
  const header = '"use strict";\nvar __phModDefault;\n';
  let footer = '';
  for (const t of tail) {
    footer += t + '\n';
  }
  footer += 'if (typeof __phModDefault !== "undefined" && __phModDefault !== null) { module.exports["default"] = __phModDefault; }\n';
  const r: ManggoTransformResult = { code: header + out + footer, error: '' };
  return r;
}

/** 具名导入列表展开：`a, b as c` → `const a = I.a; const c = I.b;`（非法标识符跳过） */
function expandNamedImports(names: string, ref: string): string {
  let js = '';
  const parts = names.split(',');
  for (const raw of parts) {
    const seg = raw.trim();
    if (seg.length === 0) {
      continue;
    }
    const asIdx = seg.indexOf(' as ');
    const imported = asIdx >= 0 ? seg.substring(0, asIdx).trim() : seg;
    const local = asIdx >= 0 ? seg.substring(asIdx + 4).trim() : seg;
    if (!/^[A-Za-z_$][\w$]*$/.test(local)) {
      continue;
    }
    js += 'const ' + local + ' = ' + ref + '[' + JSON.stringify(imported) + '];\n';
  }
  return js;
}

/**
 * 按服务子集生成注册代码（追加在对应脚本段尾部）：
 *  - 主脚本段：注册未声明服务级 main 的服务；
 *  - 服务专用脚本段（services[].main）：IIFE 隔离顶层命名，只注册该服务。
 * 入口解析顺序：全局/脚本作用域标识符 → 默认导出对象属性；逐服务 try 隔离。
 * 依赖 kManggoBootstrap 提供：__phManggoRegister / __phManggoServices / nativeLog。
 */
export function buildManggoRegisterSnippetFor(svcs: ManggoServiceDef[]): string {
  let js = '\n;(function () {\n';
  js += 'var __de = (typeof __phDefaultExport !== "undefined" && __phDefaultExport !== null) ? __phDefaultExport : null;\n';
  let idx = 0;
  for (const svc of svcs) {
    if (!isSupportedManggoService(svc)) {
      continue;
    }
    const sidJson = JSON.stringify(svc.id);
    const entry = svc.entry;
    const varName = '__fn' + idx;
    js += 'try {\n';
    js += 'var ' + varName + ' = (typeof ' + entry + ' === "function") ? ' + entry + ' : ' +
      '((__de !== null && typeof __de[' + JSON.stringify(entry) + '] === "function") ? __de[' + JSON.stringify(entry) + '] : undefined);\n';
    js += '__phManggoRegister(' + sidJson + ', ' + JSON.stringify(svc.kind) + ', ' + varName +
      ', __phManggoServices[' + sidJson + '] || {});\n';
    js += '} catch (e) { try { nativeLog("error", "manggo register ' + svc.id + ': " + (e && e.message ? e.message : String(e))); } catch (e2) {} }\n';
    idx++;
  }
  js += '})();\n';
  return js;
}

/** 按整份清单生成注册代码（全部挂主脚本段） */
export function buildManggoRegisterSnippet(manifestJson: string): string {
  return buildManggoRegisterSnippetFor(parseManggoServices(manifestJson));
}

/**
 * 插件/服务图标绝对路径解析：icon 字段支持字符串或对象（优先 universal，取首个非空值）。
 * 返回 'file://' 可用的绝对路径；无图标返回空串。
 */
export function resolvePluginIconPath(dir: string, icon: Object | undefined | null): string {
  let rel = '';
  if (typeof icon === 'string') {
    rel = icon as string;
  } else if (typeof icon === 'object' && icon !== null) {
    const o = icon as Record<string, Object>;
    if (typeof o['universal'] === 'string') {
      rel = o['universal'] as string;
    } else {
      for (const k of Object.keys(o)) {
        const v = o[k];
        if (typeof v === 'string' && (v as string).length > 0) {
          rel = v as string;
          break;
        }
      }
    }
  }
  return rel.length > 0 ? dir + '/' + rel : '';
}
