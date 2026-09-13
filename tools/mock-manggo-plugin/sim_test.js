// 模拟宿主沙盒验证（node 临时脚本）：ESM 转换 → 服务注册 → 三类入口调用约定
const fs = require('fs');
const manifest = fs.readFileSync(__dirname + '/manggo.plugin.json', 'utf8');
const code = fs.readFileSync(__dirname + '/main.js', 'utf8');

// ===== 复制 transformManggoEsm（与 ManggoTypes.ets 同逻辑）=====
function transformManggoEsm(code, registerSnippet) {
  if (/(^|\n)[ \t]*import[\s{"'*]/.test(code) || /\bimport\s*\(/.test(code)) {
    return { code: '', error: 'import 语句' };
  }
  let out = code;
  out = out.replace(/(^|\n)([ \t]*)export[ \t]+default[ \t]+/g, '$1$2__phDefaultExport = ');
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\{[^}]*\}[ \t]*;?/g, '$1');
  out = out.replace(/(^|\n)[ \t]*export[ \t]*\*[^;\n]*;?/g, '$1');
  out = out.replace(/(^|\n)([ \t]*)export(?=[ \t]+(async[ \t]+function|function|class|const|let|var)\b)/g, '$1$2');
  return { code: '"use strict";\nvar __phDefaultExport;\n' + out + registerSnippet, error: '' };
}

// ===== 复制 buildManggoRegisterSnippet =====
function buildManggoRegisterSnippet(manifestJson) {
  const svcs = JSON.parse(manifestJson).services;
  let js = '\n;(function () {\n';
  js += 'var __de = (typeof __phDefaultExport !== "undefined" && __phDefaultExport !== null) ? __phDefaultExport : null;\n';
  let idx = 0;
  for (const svc of svcs) {
    const sidJson = JSON.stringify(svc.id), e = JSON.stringify(svc.entry), v = '__fn' + idx;
    js += 'try {\nvar ' + v + ' = (typeof ' + svc.entry + ' === "function") ? ' + svc.entry
      + ' : ((__de !== null && typeof __de[' + e + '] === "function") ? __de[' + e + '] : undefined);\n';
    js += '__phManggoRegister(' + sidJson + ', ' + JSON.stringify(svc.kind) + ', ' + v
      + ', __phManggoServices[' + sidJson + '] || {});\n';
    js += '} catch (er) { try { nativeLog("error", "reg " + er); } catch (e2) {} }\n';
    idx++;
  }
  return js + '})();\n';
}

const tr = transformManggoEsm(code, buildManggoRegisterSnippet(manifest));
if (tr.error) { console.log('TRANSFORM FAIL', tr.error); process.exit(1); }
console.log('transform ok, code len', tr.code.length);

// ===== 模拟宿主环境 =====
const registered = {};
const deltas = [];
globalThis.nativeLog = (lv, m) => console.log('[log:' + lv + ']', m);
globalThis.nativeStreamText = (t) => deltas.push(JSON.parse(t).__manggoDelta);
// 各服务配置（buildManggoConfig 的产出：默认值 + boolean 还原）
globalThis.__phManggoServices = {};
for (const s of JSON.parse(manifest).services) {
  const cfg = {};
  for (const c of (s.config || [])) {
    cfg[c.key] = c.default !== undefined ? c.default : (c.control === 'boolean' ? false : '');
  }
  globalThis.__phManggoServices[s.id] = cfg;
}
// 与 kManggoBootstrap 对齐：detect 收进 options.detect，options 占住最后一个形参位
globalThis.__phManggoRegister = function (serviceId, kind, entryFn, cfg) {
  const key = '__phSvc_' + String(serviceId).replace(/[^A-Za-z0-9_]/g, '_');
  registered[key] = function () {
    let args = Array.prototype.slice.call(arguments);
    const detect = (args.length >= 4 && typeof args[3] === 'string') ? args[3] : undefined;
    const options = {
      config: cfg || {},
      detect: (typeof detect === 'string') ? detect : null,
      setResult: (chunk) => globalThis.nativeStreamText(JSON.stringify({ __manggoDelta: String(chunk) })),
      utils: { osType: 'Linux' }
    };
    if (args.length >= 4) { args[3] = options; } else { args.push(options); }
    const call = Promise.resolve().then(() => entryFn.apply(null, args));
    if (kind !== 'speech') { return call; }
    return call.then((r) => {
      if (r && typeof r === 'object' && r.bytes instanceof Uint8Array) {
        return { __phAudio: { base64: 'B64LEN:' + r.bytes.length, format: r.format } };
      }
      throw new Error('无法识别音频');
    });
  };
  console.log('registered:', key, kind, '| entry type:', typeof entryFn);
};

eval(tr.code);

(async () => {
  const r1 = await registered['__phSvc_main']('hello world', 'zh-Hans', 'en-US', 'en-US');
  console.log('translate =>', JSON.stringify(r1));
  console.log('stream deltas =>', deltas.join('|'));
  const r2 = await registered['__phSvc_ocr']('UklGRg==', 'ja-JP');
  console.log('ocr =>', JSON.stringify(r2));
  const r3 = await registered['__phSvc_tts']('你好', 'zh-Hans');
  console.log('tts =>', JSON.stringify(r3));
  if (!deltas.length || r1.indexOf('(无密钥)') < 0 || r3.__phAudio.base64.indexOf('B64LEN') < 0) {
    console.error('ASSERT FAILED');
    process.exit(1);
  }
  console.log('ALL JS-CONTRACT CHECKS PASSED');
})().catch((e) => { console.error('CHECK FAILED:', e && e.message); process.exit(1); });
