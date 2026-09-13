// 真实 manggo 插件联调模拟（node 临时脚本）：
//  1. 从 jsvm_runtime.cpp 提取 kModulesRuntime / kManggoBootstrap 原文执行（测真实沙盒 JS）；
//  2. node:crypto 哈希向量（md5/sha1/sha256 + hex/base64/utf8）；
//  3. fetch shim：SSE 流式 getReader / Headers.get / 非流式回放 / 二进制 bodyB64；
//  4. transformManggoModule：包内 ESM 模块 → CommonJS（具名/默认导出、import node:crypto）；
//  5. 多段拼装（服务级 main）+ 流式增量带服务 id（同插件多服务隔离）。
// 用法: node realpack_test.js [真实插件main.js路径]
const fs = require('fs');
const path = require('path');

const cppPath = path.resolve(__dirname, '../../entry/src/main/cpp/jsvm_runtime.cpp');
const realMain = process.argv[2] || '';
const cpp = fs.readFileSync(cppPath, 'utf8');

function extractBlock(name) {
  const marker = 'const char *' + name + ' = R"JS(';
  const start = cpp.indexOf(marker);
  if (start < 0) { throw new Error('block not found: ' + name); }
  const from = start + marker.length;
  const end = cpp.indexOf(')JS";', from);
  if (end < 0) { throw new Error('block end not found: ' + name); }
  return cpp.substring(from, end);
}

const modulesRuntime = extractBlock('kModulesRuntime');
const bootstrap = extractBlock('kManggoBootstrap');

// ===== 模拟宿主 =====
const registered = {};
const rawLog = (msg) => process.stdout.write('  [log] ' + msg + '\n');
globalThis.nativeLog = (lv, m) => rawLog('[' + lv + '] ' + m);
globalThis.nativeStreamText = (t) => { streamSink.push(JSON.parse(t)); };
const streamSink = [];
// nativeHttp 桩：SSE 请求回放增量后 resolve 空 body；记录最近 envelope 供断言
let lastEnvelope = null;
globalThis.nativeHttp = (reqJson) => new Promise((resolve) => {
  lastEnvelope = JSON.parse(reqJson);
  const req = lastEnvelope;
  if (req.stream === true) {
    setTimeout(() => {
      globalThis.__phStreamDeliver('data: hello\n\n');
      globalThis.__phStreamDeliver('data: world');
      resolve(JSON.stringify({ status: 200, headers: {}, body: '' }));
    }, 5);
  } else {
    resolve(JSON.stringify({ status: 200, headers: { 'content-type': 'application/json' }, body: '{"a":1}' }));
  }
});
globalThis.nativeFileOp = () => { throw new Error('nativeFileOp not expected'); };
globalThis.nativeAfter = () => Promise.resolve();
globalThis.__phHostConfig = {};
globalThis.__phPluginDir = '/plugin';
globalThis.__phSandboxDir = '$sandbox';
globalThis.__phModules = {};
globalThis.__phManggoServices = {};

// ===== 与 ManggoTypes.ets 同版的转换器 =====
function expandNamed(names, ref) {
  let js = '';
  for (const raw of names.split(',')) {
    const seg = raw.trim();
    if (!seg) { continue; }
    const asIdx = seg.indexOf(' as ');
    const imported = asIdx >= 0 ? seg.substring(0, asIdx).trim() : seg;
    const local = asIdx >= 0 ? seg.substring(asIdx + 4).trim() : seg;
    if (!/^[A-Za-z_$][\w$]*$/.test(local)) { continue; }
    js += 'const ' + local + ' = ' + ref + '[' + JSON.stringify(imported) + '];\n';
  }
  return js;
}
function rewriteImports(code) {
  let out = code;
  out = out.replace(/(^|\n)([ \t]*)import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\5/g,
    (_m, cr, ind, def, names, _q, mod) => cr + ind + 'const __phI = __phModRequire(' + JSON.stringify(mod) + ');\n' + ind
      + 'const ' + def + ' = __phInterop(__phI);\n' + ind + expandNamed(names, '__phI'));
  out = out.replace(/(^|\n)([ \t]*)import\s+([A-Za-z_$][\w$]*)\s*from\s*(['"])([^'"]+)\4/g,
    (_m, cr, ind, def, _q, mod) => cr + ind + 'const ' + def + ' = __phInterop(__phModRequire(' + JSON.stringify(mod) + '));');
  out = out.replace(/(^|\n)([ \t]*)import\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\4/g,
    (_m, cr, ind, names, _q, mod) => cr + ind + 'const __phI = __phModRequire(' + JSON.stringify(mod) + ');\n' + ind
      + expandNamed(names, '__phI'));
  out = out.replace(/(^|\n)([ \t]*)import\s*\*\s*as\s+([A-Za-z_$][\w$]*)\s*from\s*(['"])([^'"]+)\4/g,
    (_m, cr, ind, ns, _q, mod) => cr + ind + 'const ' + ns + ' = __phModRequire(' + JSON.stringify(mod) + ');');
  out = out.replace(/(^|\n)([ \t]*)import\s*(['"])([^'"]+)\3/g,
    (_m, cr, ind, _q, mod) => cr + ind + '__phModRequire(' + JSON.stringify(mod) + ');');
  out = out.replace(/\bimport\s*\(/g, '__phModRequire(');
  return out;
}
function transformManggoEsm(code, registerSnippet) {
  let out = rewriteImports(code);
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+default[ \t]+/g, '$1$2__phDefaultExport = ');
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\{[^}]*\}[ \t]*;?/g, '$1');
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\*[^;\n]*;?/g, '$1');
  out = out.replace(/(^|\n)([ \t]*)export(?=[ \t]+(async[ \t]+function|function|class|const|let|var)\b)/g, '$1$2');
  return { code: '"use strict";\nvar __phDefaultExport;\n' + out + registerSnippet, error: '' };
}
function transformManggoModule(code) {
  let out = rewriteImports(code);
  const tail = [];
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+default[ \t]+/g, '$1$2__phModDefault = ');
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\{([^}]*)\}[ \t]*;?/g,
    (_m, cr, names) => {
      for (const raw of names.split(',')) {
        const seg = raw.trim();
        if (!seg) { continue; }
        const asIdx = seg.indexOf(' as ');
        const local = asIdx >= 0 ? seg.substring(0, asIdx).trim() : seg;
        const exported = asIdx >= 0 ? seg.substring(asIdx + 4).trim() : seg;
        if (/^[A-Za-z_$][\w$]*$/.test(exported)) {
          tail.push('module.exports[' + JSON.stringify(exported) + '] = ' + local + ';');
        }
      }
      return cr;
    });
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\*[ \t]+from[ \t]*(['"])([^'"]+)\2[ \t]*;?/g,
    (_m, cr, _q, mod) => cr + 'Object.assign(module.exports, __phModRequire(' + JSON.stringify(mod) + '));');
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\*[ \t]*;?/g, '$1');
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+((?:async[ \t]+)?function|class)[ \t]+([A-Za-z_$][\w$]*)/g,
    (_m, cr, ind, kind, name) => {
      tail.push('module.exports[' + JSON.stringify(name) + '] = ' + name + ';');
      return cr + ind + kind + ' ' + name;
    });
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+(const|let|var)[ \t]+([^;\n]*)/g,
    (_m, cr, ind, kw, head) => {
      for (const part of head.split('=')) {
        const seg = part.trim();
        if (!seg || seg.indexOf('(') >= 0 || seg.indexOf('[') >= 0) { continue; }
        const m = seg.match(/^([A-Za-z_$][\w$]*)/);
        if (m && m[1] !== 'function') { tail.push('module.exports[' + JSON.stringify(m[1]) + '] = ' + m[1] + ';'); }
      }
      return cr + ind + kw + ' ' + head;
    });
  const footer = tail.join('\n')
    + '\nif (typeof __phModDefault !== "undefined" && __phModDefault !== null) { module.exports["default"] = __phModDefault; }\n';
  return { code: '"use strict";\nvar __phModDefault;\n' + out + footer, error: '' };
}
function buildRegisterSnippet(svcs) {
  let js = '\n;(function () {\n';
  js += 'var __de = (typeof __phDefaultExport !== "undefined" && __phDefaultExport !== null) ? __phDefaultExport : null;\n';
  svcs.forEach((svc, idx) => {
    const sidJson = JSON.stringify(svc.id), e = JSON.stringify(svc.entry), v = '__fn' + idx;
    js += 'try {\nvar ' + v + ' = (typeof ' + svc.entry + ' === "function") ? ' + svc.entry
      + ' : ((__de !== null && typeof __de[' + e + '] === "function") ? __de[' + e + '] : undefined);\n';
    js += '__phManggoRegister(' + sidJson + ', ' + JSON.stringify(svc.kind) + ', ' + v
      + ', __phManggoServices[' + sidJson + '] || {});\n';
    js += '} catch (er) { try { nativeLog("error", "reg " + er); } catch (e2) {} }\n';
  });
  return js + '})();\n';
}

let failed = 0;
function check(name, cond) {
  console.log((cond ? '  PASS ' : '  FAIL ') + name);
  if (!cond) { failed++; }
}

(async () => {
  // 1. 沙盒 JS（kModulesRuntime + kManggoBootstrap 原文）
  (0, eval)(modulesRuntime + '\n' + bootstrap);
  // bootstrap 自带 __phManggoRegister（真实包装 + 写 globalThis）——委托它，同时捕获包装后的可调用体
  const bootstrapRegister = globalThis.__phManggoRegister;
  globalThis.__phManggoRegister = function (serviceId, kind, entryFn, cfg) {
    bootstrapRegister(serviceId, kind, entryFn, cfg);
    const key = '__phSvc_' + String(serviceId).replace(/[^A-Za-z0-9_]/g, '_');
    registered[key] = { kind, type: typeof entryFn, fn: globalThis[key], cfg };
  };

  // 2. node:crypto 哈希向量
  console.log('[1] node:crypto 内置模块');
  const nc = (0, eval)('__phModRequire("node:crypto")');
  const md5 = nc.createHash('md5'); md5.update('abc', 'utf8');
  check('md5("abc") hex', md5.digest('hex') === '900150983cd24fb0d6963f7d28e17f72');
  const md5b = nc.createHash('md5'); md5b.update('你好', 'utf8');
  check('md5("你好") utf8 hex', md5b.digest('hex') === '7eca689f0d3389d9dea66ae112e5cfd7');
  const s1 = nc.createHash('sha1'); s1.update('abc', 'utf8');
  check('sha1("abc") hex', s1.digest('hex') === 'a9993e364706816aba3e25717850c26c9cd0d89d');
  const s256 = nc.createHash('sha256'); s256.update('abc', 'utf8');
  check('sha256("abc") hex', s256.digest('hex') === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');

  // 2.5 fetch shim
  console.log('[1.5] fetch shim（SSE / Headers / body reader / bodyB64）');
  const fetchFn = (0, eval)('__phManggoUtils.fetch');
  const sseResp = await fetchFn('http://x/sse', { method: 'POST', headers: { Accept: 'text/event-stream' }, body: '{}' });
  check('SSE status/ok', sseResp.status === 200 && sseResp.ok === true);
  const reader = sseResp.body.getReader();
  const dec = new TextDecoder();
  const c1 = await reader.read();
  const cA = await reader.read();
  const cB = await reader.read();
  check('SSE 增量读取', dec.decode(c1.value) + dec.decode(cA.value) === 'data: hello\n\ndata: world' && cB.done === true);
  check('SSE text() 收集增量', (await sseResp.text()) === 'data: hello\n\ndata: world');
  const jsonResp = await fetchFn('http://x/api');
  check('JSON text() + headers.get', (await jsonResp.text()) === '{"a":1}' && jsonResp.headers.get('content-type') === 'application/json');
  // 二进制请求体 → bodyB64
  lastEnvelope = null;
  await fetchFn('http://x/bin', { method: 'POST', body: new Uint8Array([1, 2, 3]) });
  check('二进制 body → bodyB64', lastEnvelope !== null && lastEnvelope.bodyB64 === 'AQID' && lastEnvelope.body === '');
  lastEnvelope = null;
  await fetchFn('http://x/txt', { method: 'POST', body: 'plain' });
  check('文本 body 不走 bodyB64', lastEnvelope !== null && lastEnvelope.body === 'plain' && lastEnvelope.bodyB64 === undefined);

  // 3. 模块 ESM → CommonJS（经沙盒 require 真实执行）
  console.log('[2] transformManggoModule');
  const utilSrc = [
    'import { createHash } from "node:crypto";',
    'export const VERSION = "1.2";',
    'export function md5Hex(s) { return createHash("md5").update(s, "utf8").digest("hex"); }',
    'export default md5Hex;'
  ].join('\n');
  const trUtil = transformManggoModule(utilSrc);
  check('模块转换成功', trUtil.error === '');
  globalThis.__phModules['util.js'] = trUtil.code;
  const utilMod = (0, eval)('__phModRequire("util.js")');
  check('模块具名导出', utilMod.VERSION === '1.2');
  check('模块函数 + 内置模块导入', utilMod.md5Hex('abc') === '900150983cd24fb0d6963f7d28e17f72');
  check('模块默认导出', typeof utilMod.default === 'function' && utilMod.default('abc') === '900150983cd24fb0d6963f7d28e17f72');

  // 4. 多段拼装（服务级 main）+ 流式增量带服务 id
  console.log('[3] 多段拼装 + 流式服务隔离');
  const manifest = {
    services: [
      { id: 'main', kind: 'translation', entry: 'translate', displayName: '主' },
      { id: 'ext', kind: 'translation', entry: 'translateExt', displayName: '扩展', main: 'ext.js' }
    ]
  };
  globalThis.__phModules['extutil.js'] = transformManggoModule('export const label = "[EXT]";').code;
  const mainSrc = 'export async function translate(text, from, to, options) { options.setResult("M:"); return "M" + text; }';
  const extSrc = 'import { label } from "./extutil.js";\n'
    + 'export async function translateExt(text, from, to, options) { options.setResult("E:"); return label + text; }';
  // 与 PluginInstaller.loadManggo 相同的多段拼装
  let code = transformManggoEsm(mainSrc, buildRegisterSnippet([manifest.services[0]])).code;
  code += '\n;(function () {\n' + transformManggoEsm(extSrc, buildRegisterSnippet([manifest.services[1]])).code + '\n})();\n';
  (0, eval)(code);
  check('主脚本服务注册', registered['__phSvc_main'] !== undefined && registered['__phSvc_main'].type === 'function');
  check('专用脚本服务注册', registered['__phSvc_ext'] !== undefined && registered['__phSvc_ext'].type === 'function');
  streamSink.length = 0;
  const rMain = await registered['__phSvc_main'].fn('hello', 'zh_CN', 'en_US', undefined);
  const rExt = await registered['__phSvc_ext'].fn('hi', 'zh_CN', 'en_US', undefined);
  check('主服务结果', rMain === 'Mhello');
  check('扩展服务结果（相对导入 ESM 模块）', rExt === '[EXT]hi');
  const mainDelta = streamSink.find((d) => d.__manggoDelta === 'M:');
  const extDelta = streamSink.find((d) => d.__manggoDelta === 'E:');
  check('流式增量携带服务 id（隔离）', mainDelta !== undefined && mainDelta.__manggoSvc === 'main'
    && extDelta !== undefined && extDelta.__manggoSvc === 'ext');

  // 5. 真实插件（可选参数）
  if (realMain) {
    console.log('[4] 真实插件: ' + realMain);
    const codeReal = fs.readFileSync(realMain, 'utf8');
    const manifestPath = path.join(path.dirname(realMain), 'manggo.plugin.json');
    const manifestReal = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    const svcs = manifestReal.services.filter((s) => ['translation', 'ocr', 'speech'].includes(s.kind));
    const tr = transformManggoEsm(codeReal,
      buildRegisterSnippet(svcs) + '\n;globalThis.__probe = typeof createHash; globalThis.__probeDe = typeof __phDefaultExport;');
    check('转换成功', tr.error === '');
    (0, eval)(tr.code);
    for (const svc of svcs) {
      const key = '__phSvc_' + svc.id;
      check('注册 ' + svc.id + ' (' + svc.kind + ')', registered[key] !== undefined && registered[key].type === 'function');
    }
    check('import 重写探测', globalThis.__probe === 'function' || globalThis.__probe === 'undefined');
    console.log('注册详情:', Object.keys(registered).map((k) => k + '=' + registered[k].kind).join(', '));
  }
  console.log(failed === 0 ? 'ALL CHECKS PASSED' : failed + ' CHECKS FAILED');
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => { console.error('TEST ERROR:', e && e.message); process.exit(1); });
