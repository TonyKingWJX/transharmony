#include "jsvm_runtime.h"
#include "ark_runtime/jsvm.h"
#include <hilog/log.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <dirent.h>
#include <map>
#include <mutex>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

#define LOG_DOMAIN 0x0202
#define LOG_TAG "PluginHost"

namespace pluginhost {

namespace {

std::once_flag g_jsvmInitOnce;

void EnsureJsvmInit()
{
    std::call_once(g_jsvmInitOnce, []() {
        JSVM_InitOptions initOptions = {};
        OH_JSVM_Init(&initOptions);
    });
}

double NowMs()
{
    return std::chrono::duration<double, std::milli>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// 每个插件 Env 注入的前奏脚本：包装三种调用模式，结果统一经 __settle(json) 回流
const char *kPrelude = R"JS(
function __phNormalize(v) {
    var s = JSON.stringify(v);
    return s === undefined ? "null" : s;
}
function __phParseArgs(argsJson) {
    var args = JSON.parse(argsJson);
    if (!Array.isArray(args)) args = [];
    return args;
}
function __phFail(callId, e) {
    __settle(callId, 0, JSON.stringify({ message: String(e) }));
}
function __phRunSync(callId, fn, argsJson) {
    try { __settle(callId, 1, __phNormalize(fn.apply(null, __phParseArgs(argsJson)))); }
    catch (e) { __phFail(callId, e); }
}
function __phRunPromise(callId, fn, argsJson) {
    var args;
    try { args = __phParseArgs(argsJson); }
    catch (e) { __phFail(callId, e); return; }
    try {
        Promise.resolve(fn.apply(null, args)).then(
            function (r) { __settle(callId, 1, __phNormalize(r)); },
            function (e) { __phFail(callId, e); }
        );
    } catch (e) { __phFail(callId, e); }
}
function __phRunCallback(callId, fn, argsJson) {
    var args;
    try { args = __phParseArgs(argsJson); }
    catch (e) { __phFail(callId, e); return; }
    try {
        var complete = function (result) { __settle(callId, 1, __phNormalize(result)); };
        // Bob 1.8.0+ 推荐形态：query.onCompletion({result|error})。
        // query 是首参对象时把完成回调同时挂上去，completion 参数照传（向后兼容）。
        if (args.length > 0 && args[0] !== null && typeof args[0] === 'object' && !Array.isArray(args[0])) {
            args[0].onCompletion = complete;
            args[0].onStream = function (result) {
                nativeStreamText(typeof result === 'string' ? result : __phNormalize(result));
            };
            args[0].cancelSignal = {};
            // OCR 约定：宿主在 query 里传 imageB64（图片 base64），此处转成 Bob 规范的 image($data)
            if (typeof args[0].imageB64 === 'string' && args[0].imageB64.length > 0) {
                args[0].image = $data.fromBase64(args[0].imageB64);
                delete args[0].imageB64;
            }
        }
        args.push(complete);
        fn.apply(null, args);
    } catch (e) { __phFail(callId, e); }
}
)JS";

// Bob 插件运行时 shim：按 bobtranslate.com 官方 API 契约重建 Bob 全局。
// 在 HandleLoad 里、用户脚本之前求值；依赖先行的 __phHostConfig 注入（info/option 配置）。
const char *kBobShim = R"JS(
var __phCfg = (typeof __phHostConfig === 'undefined') ? {} : __phHostConfig;

// ---- UTF-8 / Base64 纯 JS 工具（裸 JSVM 无 TextEncoder）----
function __phUtf8Encode(str) {
    var out = [];
    for (var i = 0; i < str.length; i++) {
        var c = str.codePointAt(i);
        if (c > 0xFFFF) i++;
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
        else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
}
function __phUtf8Decode(bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
        var b = bytes[i];
        var cp = b;
        if (b < 0x80) { i += 1; }
        else if (b < 0xE0) { cp = ((b & 31) << 6) | (bytes[i + 1] & 63); i += 2; }
        else if (b < 0xF0) { cp = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63); i += 3; }
        else { cp = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63); i += 4; }
        out += String.fromCodePoint(cp);
    }
    return out;
}
var __phB64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function __phB64Encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
        var b1 = bytes[i], b2 = i + 1 < bytes.length ? bytes[i + 1] : 0, b3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
        out += __phB64[b1 >> 2] + __phB64[((b1 & 3) << 4) | (b2 >> 4)];
        out += i + 1 < bytes.length ? __phB64[((b2 & 15) << 2) | (b3 >> 6)] : '=';
        out += i + 2 < bytes.length ? __phB64[b3 & 63] : '=';
    }
    return out;
}
function __phB64Decode(s) {
    s = String(s).replace(/[^A-Za-z0-9+/]/g, '');
    var out = [];
    for (var i = 0; i < s.length; i += 4) {
        var n = (__phB64.indexOf(s[i]) << 18) | (__phB64.indexOf(s[i + 1]) << 12);
        if (s[i + 2] !== undefined) n |= __phB64.indexOf(s[i + 2]) << 6;
        if (s[i + 3] !== undefined) n |= __phB64.indexOf(s[i + 3]);
        out.push((n >> 16) & 255);
        if (s[i + 2] !== undefined) out.push((n >> 8) & 255);
        if (s[i + 3] !== undefined) out.push(n & 255);
    }
    return out;
}

// ---- $data（NSData 包装的字节容器）----
function PhData(bytes) { this._b = bytes; }
Object.defineProperty(PhData.prototype, 'length', {
    get: function () { return this._b.length; }
});
PhData.prototype.toUTF8 = function () { return __phUtf8Decode(this._b); };
PhData.prototype.toHex = function (upper) {
    var out = '';
    for (var i = 0; i < this._b.length; i++) {
        var h = this._b[i].toString(16);
        out += h.length < 2 ? '0' + h : h;
    }
    return upper ? out.toUpperCase() : out;
};
PhData.prototype.toBase64 = function () { return __phB64Encode(this._b); };
PhData.prototype.toByteArray = function () { return this._b.slice(); };
PhData.prototype.readUInt8 = function (i) { return (i >= 0 && i < this._b.length) ? this._b[i] : 0; };
PhData.prototype.writeUInt8 = function (v, i) {
    if (i >= 0 && i < this._b.length && v >= 0 && v <= 255) { this._b[i] = v; }
};
PhData.prototype.subData = function (start, end) { return new PhData(this._b.slice(start, end)); };
PhData.prototype.appendData = function (other) {
    for (var i = 0; i < other._b.length; i++) { this._b.push(other._b[i]); }
};
var $data = {
    fromUTF8: function (s) { return new PhData(__phUtf8Encode(String(s))); },
    fromHex: function (s) {
        s = String(s);
        var out = [];
        for (var i = 0; i + 1 < s.length; i += 2) { out.push(parseInt(s.substr(i, 2), 16)); }
        return new PhData(out);
    },
    fromBase64: function (s) { return new PhData(__phB64Decode(s)); },
    fromByteArray: function (a) { return new PhData(Array.prototype.slice.call(a)); },
    fromData: function (d) { return new PhData(d._b.slice()); },
    isData: function (o) { return o instanceof PhData; }
};

// ---- $log ----
function __phToString(o) {
    if (o === undefined) return 'undefined';
    if (o === null) return 'null';
    return String(o);
}
var $log = {
    info: function (o) { nativeLog('info', __phToString(o)); },
    error: function (o) { nativeLog('error', __phToString(o)); }
};

// ---- $info / $option / $env ----
var $info = __phCfg.info || {};
var $option = __phCfg.option || {};
var $env = { appVersion: '1.8.0', appBuild: '103', macOSVersion: '', macModel: '' };

// ---- $signal（纯 JS 事件模型）----
function PhSignal() { this._subs = []; }
PhSignal.prototype.send = function (data) {
    var subs = this._subs.slice();
    for (var i = 0; i < subs.length; i++) {
        try { subs[i].fn(data); } catch (e) {}
    }
};
PhSignal.prototype.subscribe = function (fn) {
    var sub = { fn: fn };
    this._subs.push(sub);
    var self = this;
    return { dispose: function () {
        var idx = self._subs.indexOf(sub);
        if (idx >= 0) self._subs.splice(idx, 1);
    } };
};
PhSignal.prototype.removeAllSubscriber = function () { this._subs = []; };
var $signal = { new: function () { return new PhSignal(); } };

// ---- $timer（基于 nativeAfter 定时原语，interval 单位秒）----
var __phTimers = {};
var __phTimerSeq = 1;
var $timer = {
    schedule: function (opts) {
        var id = __phTimerSeq++;
        __phTimers[id] = opts;
        var arm = function () {
            nativeAfter(id, Math.max(1, (opts.interval || 0) * 1000)).then(function () {
                var t = __phTimers[id];
                if (!t) return;
                try { t.handler(); } catch (e) { nativeLog('error', 'timer handler: ' + e); }
                if (__phTimers[id] && t.repeats) { arm(); } else { delete __phTimers[id]; }
            });
        };
        arm();
        return id;
    },
    invalidate: function (id) { delete __phTimers[id]; }
};

// ---- $http（语义对齐 bobtranslate.com/plugin/api/http.html）----
function __phEncodeRequest(opts) {
    var method = (opts.method || 'GET').toUpperCase();
    var header = opts.header || {};
    var url = opts.url;
    var body = '';
    var b = opts.body;
    if (b !== undefined && b !== null) {
        if ($data.isData(b)) { body = b.toUTF8() || ''; }
        else if (typeof b === 'string') { body = b; }
        else if (method === 'GET' || method === 'HEAD' || method === 'DELETE') {
            var qs = Object.keys(b).map(function (k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(b[k]);
            }).join('&');
            if (qs) { url = url + (url.indexOf('?') >= 0 ? '&' : '?') + qs; }
        } else {
            var ct = header['Content-Type'] || header['content-type'] || 'application/x-www-form-urlencoded';
            if (ct.toLowerCase().indexOf('json') >= 0) { body = JSON.stringify(b); }
            else {
                body = Object.keys(b).map(function (k) {
                    return encodeURIComponent(k) + '=' + encodeURIComponent(b[k]);
                }).join('&');
            }
        }
    }
    return {
        url: url, method: method, header: header, body: body,
        timeout: opts.timeout === undefined ? 60 : opts.timeout
    };
}
function __phBuildResponse(raw, reqUrl) {
    var bodyText = raw.body === undefined || raw.body === null ? '' : String(raw.body);
    var parsed = bodyText;
    try { parsed = JSON.parse(bodyText); } catch (e) {}
    var ct = raw.headers ? (raw.headers['content-type'] || '') : '';
    return {
        data: parsed,
        rawData: $data.fromUTF8(bodyText),
        response: {
            url: reqUrl, MIMEType: ct, expectedContentLength: bodyText.length,
            textEncodingName: 'UTF-8', suggestedFilename: '',
            statusCode: raw.status, headers: raw.headers || {}
        }
    };
}
function __phRequestPromise(opts) {
    var o = opts || {};
    var enc = __phEncodeRequest(o);
    return nativeHttp(JSON.stringify(enc)).then(
        function (rawStr) { return __phBuildResponse(JSON.parse(rawStr), enc.url); },
        function (errStr) {
            var e = {};
            try { e = JSON.parse(errStr); } catch (x) {}
            throw { message: e.message || 'request failed', debugMessage: e.message || '' };
        });
}
// 流式请求：桥以 SSE 文本分块回传（envelope: {streamText: chunk}），逐块交给 streamHandler。
// 完成时 handler 收到不带 data/rawData 的 resp（对齐 Bob 1.8.0 语义）。
function __phStreamRequest(opts) {
    var o = opts || {};
    var enc = __phEncodeRequest(o);
    __phActiveStreamHandler = (typeof o.streamHandler === 'function') ? o.streamHandler : null;
    return nativeHttp(JSON.stringify({
        url: enc.url, method: enc.method, header: enc.header, body: enc.body,
        timeout: enc.timeout, stream: true
    })).then(function (rawStr) {
        __phActiveStreamHandler = null;
        var env2 = JSON.parse(rawStr);
        return { response: { url: enc.url, statusCode: env2.status || 0, headers: env2.headers || {} } };
    }, function (errStr) {
        __phActiveStreamHandler = null;
        var e = {};
        try { e = JSON.parse(errStr); } catch (x) {}
        throw { message: e.message || 'stream request failed', debugMessage: e.message || '' };
    });
}
var $http = {
    request: function (opts) {
        var p = __phRequestPromise(opts);
        if (opts && typeof opts.handler === 'function') {
            p.then(function (resp) { opts.handler(resp); },
                   function (err) { opts.handler({ error: err }); });
            return undefined;
        }
        return p;
    },
    get: function (opts) { (opts = opts || {}).method = 'GET'; return $http.request(opts); },
    post: function (opts) { (opts = opts || {}).method = 'POST'; return $http.request(opts); },
    streamRequest: function (opts) {
        var p = __phStreamRequest(opts);
        if (opts && typeof opts.handler === 'function') {
            p.then(function (resp) { opts.handler(resp); },
                   function (err) { opts.handler({ error: err }); });
            return undefined;
        }
        return p;
    }
};
// 流式数据通路：ArkTS 桥收到 SSE 增量后经命令队列回沙盒，调 __phStreamDeliver 回放给
// 当前活跃请求的 streamHandler（{text, rawData}，对齐 Bob 1.8.0）。
var __phActiveStreamHandler = null;
function __phStreamDeliver(text) {
    var h = __phActiveStreamHandler;
    if (h) {
        try { h({ text: text, rawData: $data.fromUTF8(text) }); } catch (e) {}
    }
}

// ---- 浏览器/Node 习惯全局 polyfill（裸 JSVM 缺失，插件常用）----

function __phArgsJoin(args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) { parts.push(__phToString(args[i])); }
    return parts.join(' ');
}
var console = {
    log: function () { nativeLog('info', __phArgsJoin(arguments)); },
    info: function () { nativeLog('info', __phArgsJoin(arguments)); },
    debug: function () { nativeLog('info', __phArgsJoin(arguments)); },
    warn: function () { nativeLog('info', __phArgsJoin(arguments)); },
    error: function () { nativeLog('error', __phArgsJoin(arguments)); }
};

// btoa/atob：按 Web 规范只接受 Latin1（charCode ≤ 255）
function btoa(s) {
    s = String(s);
    var bytes = [];
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        if (c > 255) { throw new Error('InvalidCharacterError: btoa 输入包含 Latin1 范围之外的字符'); }
        bytes.push(c);
    }
    return __phB64Encode(bytes);
}
function atob(s) {
    var bytes = __phB64Decode(String(s));
    var out = '';
    for (var i = 0; i < bytes.length; i++) { out += String.fromCharCode(bytes[i]); }
    return out;
}

// 定时器标准名（底层 nativeAfter；id 从 1000000 起，与 $timer 的 id 空间隔离）
var __phTimeouts = {};
var __phTimeoutSeq = 1000000;
function setTimeout(fn, ms) {
    var id = __phTimeoutSeq++;
    var rest = Array.prototype.slice.call(arguments, 2);
    __phTimeouts[id] = fn;
    nativeAfter(id, Math.max(1, ms || 0)).then(function () {
        var f = __phTimeouts[id];
        if (!f) { return; }
        delete __phTimeouts[id];
        try { f.apply(null, rest); } catch (e) { nativeLog('error', 'setTimeout handler: ' + e); }
    });
    return id;
}
function clearTimeout(id) { delete __phTimeouts[id]; }
function setInterval(fn, ms) {
    var id = __phTimeoutSeq++;
    var rest = Array.prototype.slice.call(arguments, 2);
    __phTimeouts[id] = fn;
    var arm = function () {
        nativeAfter(id, Math.max(1, ms || 0)).then(function () {
            var f = __phTimeouts[id];
            if (!f) { return; }
            try { f.apply(null, rest); } catch (e) { nativeLog('error', 'setInterval handler: ' + e); }
            if (__phTimeouts[id]) { arm(); }
        });
    };
    arm();
    return id;
}
function clearInterval(id) { delete __phTimeouts[id]; }

// TextEncoder / TextDecoder
function TextEncoder() {}
TextEncoder.prototype.encode = function (s) { return new Uint8Array(__phUtf8Encode(String(s))); };
function TextDecoder() {}
TextDecoder.prototype.decode = function (u8) { return __phUtf8Decode(Array.prototype.slice.call(u8)); };

// ---- $file：虚拟路径 / （插件目录，只读）与 $sandbox/（可写）----
// 路径解析全部在 native（ResolveVirtual）：JS 只透传原始虚拟路径，避免双重前缀
var $file = {
    read: function (path) { return $data.fromBase64(nativeFileOp('read', path)); },
    write: function (o) { return nativeFileOp('write', o.path, __phB64Encode(o.data._b)) === '1'; },
    delete: function (path) { return nativeFileOp('delete', path) === '1'; },
    list: function (path) { return JSON.parse(nativeFileOp('list', path)); },
    copy: function (o) { return nativeFileOp('copy', o.src, o.dst) === '1'; },
    move: function (o) { return nativeFileOp('move', o.src, o.dst) === '1'; },
    mkdir: function (path) { return nativeFileOp('mkdir', path) === '1'; },
    exists: function (path) { return nativeFileOp('exists', path) === '1'; },
    isDirectory: function (path) { return nativeFileOp('isdir', path) === '1'; }
};

// ---- $websocket：底层经 nativeWsNew/nativeWsOp 转交 ArkTS 真实 @ohos.net.websocket，
//      事件经命令队列回放 __phWsEvent。readyState：0 connecting / 1 open / 2 closing / 3 closed ----
var __phWsRegistry = {};
function PhWebSocket(opts) {
    var o = opts || {};
    var self = this;
    this._id = Number(nativeWsNew(JSON.stringify({
        op: 'new', url: String(o.url || ''), header: o.header || {}
    })));
    this._state = 0;
    this._h = { open: [], close: [], error: [], rs: [], rd: [], rp: [], rpong: [] };
    __phWsRegistry[this._id] = self;
}
Object.defineProperty(PhWebSocket.prototype, 'readyState', {
    get: function () { return this._state; }
});
PhWebSocket.prototype.open = function () {
    nativeWsOp(JSON.stringify({ op: 'open', id: this._id }));
};
PhWebSocket.prototype.close = function (o) {
    this._state = 2;
    var code = (o && typeof o.code === 'number') ? o.code : 1000;
    nativeWsOp(JSON.stringify({ op: 'close', id: this._id, code: code }));
};
PhWebSocket.prototype.sendString = function (s) {
    nativeWsOp(JSON.stringify({ op: 'send', id: this._id, text: String(s) }));
};
PhWebSocket.prototype.sendData = function (d) {
    nativeWsOp(JSON.stringify({ op: 'sendb', id: this._id, b64: d.toBase64() }));
};
PhWebSocket.prototype.ping = function () {};
PhWebSocket.prototype.pong = function () {};
PhWebSocket.prototype._fire = function (name, a, b) {
    var list = this._h[name];
    for (var i = 0; i < list.length; i++) {
        try { list[i](this, a, b); } catch (e) { nativeLog('error', 'ws handler: ' + e); }
    }
};
PhWebSocket.prototype.listenOpen = function (fn) { this._h.open.push(fn); };
PhWebSocket.prototype.listenClose = function (fn) { this._h.close.push(fn); };
PhWebSocket.prototype.listenError = function (fn) { this._h.error.push(fn); };
PhWebSocket.prototype.listenReceiveString = function (fn) { this._h.rs.push(fn); };
PhWebSocket.prototype.listenReceiveData = function (fn) { this._h.rd.push(fn); };
PhWebSocket.prototype.listenReceivePing = function (fn) { this._h.rp.push(fn); };
PhWebSocket.prototype.listenReceivePong = function (fn) { this._h.rpong.push(fn); };
var $websocket = { new: function (o) { return new PhWebSocket(o); } };
function __phWsEvent(id, type, dataJson) {
    var ws = __phWsRegistry[id];
    if (!ws) { return; }
    var data = {};
    try { data = JSON.parse(dataJson || '{}'); } catch (e) {}
    if (type === 'open') {
        ws._state = 1;
        ws._fire('open');
    } else if (type === 'message') {
        if (typeof data.text === 'string') {
            ws._fire('rs', data.text);
        } else if (typeof data.b64 === 'string') {
            ws._fire('rd', $data.fromBase64(data.b64));
        }
    } else if (type === 'close') {
        ws._state = 3;
        delete __phWsRegistry[id];
        ws._fire('close', typeof data.code === 'number' ? data.code : 1000, data.reason || '');
    } else if (type === 'error') {
        ws._state = 3;
        ws._fire('error', { message: data.message || 'websocket error', code: 0, type: 'network' });
    }
}

// ---- 宿主内置模块：crypto-js（有道/DeepL 等签名用；覆盖 MD5 与 Hex/Utf8/Base64 编码器，
//      Bob 环境里插件包不带该依赖、由宿主提供。其余算法按真实插件需要再扩充）----
function __phToHexBytes(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
        var h = bytes[i].toString(16);
        out += h.length < 2 ? '0' + h : h;
    }
    return out;
}
function __phWordArray(bytes) {
    var wa = {
        sigBytes: bytes.length,
        words: [],
        _b: bytes,
        toString: function (enc) {
            if (enc === __phCryptoJS.enc.Base64) { return __phB64Encode(bytes); }
            if (enc === __phCryptoJS.enc.Utf8) { return __phUtf8Decode(bytes); }
            return __phToHexBytes(bytes);
        }
    };
    for (var i = 0; i < bytes.length; i += 4) {
        wa.words.push(((bytes[i] || 0) << 24) | ((bytes[i + 1] || 0) << 16) | ((bytes[i + 2] || 0) << 8) | (bytes[i + 3] || 0));
    }
    return wa;
}
function __phMd5(bytes) {
    var s = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
             5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
             4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
             6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    var K = [];
    for (var i = 0; i < 64; i++) { K[i] = (Math.abs(Math.sin(i + 1)) * 4294967296) | 0; }
    var H = [1732584193, -271733879, -1732584194, 271733878];
    var msg = bytes.slice();
    msg.push(0x80);
    while (msg.length % 64 !== 56) { msg.push(0); }
    var bitLen = bytes.length * 8;
    msg.push(bitLen & 255, (bitLen >>> 8) & 255, (bitLen >>> 16) & 255, (bitLen >>> 24) & 255, 0, 0, 0, 0);
    for (var off = 0; off < msg.length; off += 64) {
        var M = [];
        for (var j = 0; j < 16; j++) {
            M[j] = msg[off + j * 4] | (msg[off + j * 4 + 1] << 8) | (msg[off + j * 4 + 2] << 16) | (msg[off + j * 4 + 3] << 24);
        }
        var A = H[0], B = H[1], C = H[2], D = H[3];
        for (var r = 0; r < 64; r++) {
            var F, g;
            if (r < 16) { F = (B & C) | (~B & D); g = r; }
            else if (r < 32) { F = (D & B) | (~D & C); g = (5 * r + 1) % 16; }
            else if (r < 48) { F = B ^ C ^ D; g = (3 * r + 5) % 16; }
            else { F = C ^ (B | ~D); g = (7 * r) % 16; }
            F = (F + A + K[r] + M[g]) | 0;
            A = D; D = C; C = B;
            B = (B + ((F << s[r]) | (F >>> (32 - s[r])))) | 0;
        }
        H[0] = (H[0] + A) | 0; H[1] = (H[1] + B) | 0;
        H[2] = (H[2] + C) | 0; H[3] = (H[3] + D) | 0;
    }
    var out = [];
    for (var q = 0; q < 4; q++) {
        out.push(H[q] & 255, (H[q] >>> 8) & 255, (H[q] >>> 16) & 255, (H[q] >>> 24) & 255);
    }
    return out;
}
var __phCryptoJS = {
    lib: { WordArray: { create: function (bytes) { return __phWordArray(bytes); } } },
    enc: {
        Hex: {
            stringify: function (wa) { return wa.toString(); },
            parse: function (hex) { return __phWordArray($data.fromHex(hex)._b); }
        },
        Utf8: {
            stringify: function (wa) { return __phUtf8Decode(wa._b); },
            parse: function (s) { return __phWordArray(__phUtf8Encode(String(s))); }
        },
        Base64: {
            stringify: function (wa) { return __phB64Encode(wa._b); },
            parse: function (s) { return __phWordArray(__phB64Decode(String(s))); }
        }
    },
    MD5: function (msg) {
        if ($data.isData(msg)) { return __phWordArray(__phMd5(msg._b)); }
        return __phWordArray(__phMd5(__phUtf8Encode(String(msg))));
    }
};
__phBuiltinModules['crypto-js'] = function (module, exports) {
    module.exports = __phCryptoJS;
};
)JS";

// CommonJS 模块系统：Bob 插件支持多文件结构（main.js 里 require('./config.js') 等）。
// __phModules 由 HandleLoad 注入（插件包内全部 .js：相对路径 → 源码）；
// __phBuiltinModules 由 Bob shim 注册宿主内置模块（如 crypto-js）；
// 平铺命名空间（去掉 './' 前缀，缺省补 .js），带缓存与循环依赖兜底（先挂缓存再执行工厂）。
const char *kModulesRuntime = R"JS(
var __phModuleCache = {};
var __phBuiltinModules = {};
function __phModKey(p) {
    var key = String(p);
    while (key.indexOf('./') === 0) { key = key.substring(2); }
    if (!/\.js$/.test(key)) { key = key + '.js'; }
    return key;
}
function __phRequire(curKey) {
    return function (p) {
        var key = __phModKey(p);
        var cached = __phModuleCache[key];
        if (cached !== undefined) { return cached.exports; }
        var factory = __phBuiltinModules[key] !== undefined ? __phBuiltinModules[key]
            : __phBuiltinModules[String(p)] !== undefined ? __phBuiltinModules[String(p)]
            : undefined;
        if (factory === undefined) {
            var code = __phModules[key];
            if (code === undefined) { throw new Error('module not found: ' + p); }
            factory = new Function('module', 'exports', 'require',
                code + '\n//# sourceURL=' + key);
        }
        var module = { exports: {} };
        __phModuleCache[key] = module;
        factory(module, module.exports, __phRequire(key));
        return module.exports;
    };
}
var exports = {};
var module = { exports: exports };
var require = __phRequire('main.js');
)JS";

// worker 线程私有状态（仅 worker 访问，无需加锁）
struct PendingCall {
    double deadlineMs = 0;
    bool abandoned = false;
    bool resolved = false;
    bool posted = false;
    bool ok = true;
    std::string payload;
};

struct PluginEnv {
    JSVM_Env env = nullptr;
    JSVM_EnvScope envScope = nullptr;
    JSVM_CallbackStruct fileOpCb = {nullptr, nullptr};
    std::string pluginId;   // 实例 id（流式回投路由用）
    std::string pluginDir;  // $file 的只读区（虚拟路径 /）
    std::string sandboxDir; // $file 的可写区（虚拟路径 $sandbox/）
};

// ---- base64（$file 的二进制经 JS 桥传输用）----
const char B64_CHARS[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string JsonEscapeStr(const std::string &s)
{
    std::string out;
    for (char c : s) {
        if (c == '"') { out += "\\\""; }
        else if (c == '\\') { out += "\\\\"; }
        else { out += c; }
    }
    return out;
}

std::string B64EncodeBytes(const std::vector<unsigned char> &in)
{
    std::string out;
    out.reserve((in.size() + 2) / 3 * 4);
    for (size_t i = 0; i < in.size(); i += 3) {
        unsigned b1 = in[i];
        unsigned b2 = i + 1 < in.size() ? in[i + 1] : 0;
        unsigned b3 = i + 2 < in.size() ? in[i + 2] : 0;
        out.push_back(B64_CHARS[b1 >> 2]);
        out.push_back(B64_CHARS[((b1 & 3) << 4) | (b2 >> 4)]);
        out.push_back(i + 1 < in.size() ? B64_CHARS[((b2 & 15) << 2) | (b3 >> 6)] : '=');
        out.push_back(i + 2 < in.size() ? B64_CHARS[b3 & 63] : '=');
    }
    return out;
}

int B64Val(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

std::vector<unsigned char> B64DecodeBytes(const std::string &in)
{
    std::vector<unsigned char> out;
    int val = 0;
    int bits = 0;
    for (char c : in) {
        if (c == '=' || c == '\r' || c == '\n') {
            continue;
        }
        int v = B64Val(c);
        if (v < 0) {
            continue;
        }
        val = (val << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back(static_cast<unsigned char>((val >> bits) & 255));
        }
    }
    return out;
}

std::vector<unsigned char> ReadAllBytes(const std::string &path, bool &ok)
{
    ok = false;
    std::vector<unsigned char> data;
    FILE *f = fopen(path.c_str(), "rb");
    if (f == nullptr) {
        return data;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size > 0) {
        data.resize(static_cast<size_t>(size));
        size_t rd = fread(data.data(), 1, data.size(), f);
        data.resize(rd);
    }
    fclose(f);
    ok = true;
    return data;
}

bool WriteAllBytes(const std::string &path, const std::vector<unsigned char> &data)
{
    FILE *f = fopen(path.c_str(), "wb");
    if (f == nullptr) {
        return false;
    }
    if (!data.empty()) {
        fwrite(data.data(), 1, data.size(), f);
    }
    fclose(f);
    return true;
}

bool PathExists(const std::string &path, bool *isDir)
{
    struct stat st;
    if (stat(path.c_str(), &st) != 0) {
        return false;
    }
    if (isDir != nullptr) {
        *isDir = S_ISDIR(st.st_mode);
    }
    return true;
}

// native 侧确保目录存在（逐级 mkdir，EEXIST 忽略）。
// ArkTS fileIo 建的目录在 native stat() 视图下可能不可见（沙箱视图差异），
// $file 的读写全部发生在 native，必须由 native 自己保证目录存在。
void EnsureDirNative(const std::string &path)
{
    if (path.empty()) {
        return;
    }
    std::string cur;
    for (size_t i = 0; i < path.size(); i++) {
        cur += path[i];
        if (path[i] == '/' && cur.size() > 1) {
            mkdir(cur.c_str(), 0755);
        }
    }
    mkdir(path.c_str(), 0755);
}

// nativeHttp 挂起的请求（worker 私有）：httpId → {env, deferred}
struct HttpPending {
    JSVM_Env env = nullptr;
    JSVM_Deferred deferred = nullptr;
};

// nativeAfter(id, delayMs) 挂起的定时（worker 私有）：到点后以 id 兑现 Promise
struct AfterPending {
    JSVM_Env env = nullptr;
    JSVM_Deferred deferred = nullptr;
    double fireAtMs = 0;
};

JSVM_VM g_vm = nullptr;
std::map<std::string, PluginEnv *> g_envs;
std::map<uint64_t, PendingCall> g_pendings;
std::map<uint64_t, HttpPending> g_httpPendings;
std::map<uint64_t, AfterPending> g_afterPendings;
std::atomic<uint64_t> g_httpSeq{1};
std::atomic<uint64_t> g_wsSeq{1};

std::mutex g_queueMtx;
std::condition_variable g_queueCv;
std::deque<RuntimeCommand> g_queue;
std::atomic<uint64_t> g_callSeq{1};

napi_threadsafe_function g_tsfn = nullptr;
bool g_started = false;

std::string JsToString(JSVM_Env env, JSVM_Value value)
{
    size_t len = 0;
    OH_JSVM_GetValueStringUtf8(env, value, nullptr, 0, &len);
    std::vector<char> buf(len + 1, '\0');
    size_t copied = 0;
    OH_JSVM_GetValueStringUtf8(env, value, buf.data(), len + 1, &copied);
    return std::string(buf.data(), copied);
}

// ---- 注入给插件 Env 的 native 全局 ----

// __settle(callId:number, ok:0|1, json:string)：JS 侧统一完成信号
JSVM_Value SettleCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 3;
    JSVM_Value argv[3] = {nullptr, nullptr, nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        return nullptr;
    }
    double id = 0;
    double ok = 0;
    OH_JSVM_GetValueDouble(env, argv[0], &id);
    OH_JSVM_GetValueDouble(env, argv[1], &ok);
    std::string json = JsToString(env, argv[2]);

    auto it = g_pendings.find(static_cast<uint64_t>(id));
    if (it != g_pendings.end() && !it->second.abandoned && !it->second.resolved) {
        it->second.resolved = true;
        it->second.ok = (ok != 0);
        it->second.payload = json;
    }
    return nullptr;
}

JSVM_Value EchoCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1 || argv[0] == nullptr) {
        JSVM_Value undef = nullptr;
        OH_JSVM_GetUndefined(env, &undef);
        return undef;
    }
    std::string out = "echo(" + JsToString(env, argv[0]) + ")";
    JSVM_Value result = nullptr;
    OH_JSVM_CreateStringUtf8(env, out.c_str(), out.size(), &result);
    return result;
}

// nativeHttp(requestJson)：发起真实 HTTP 请求 —— 立即返回未决 Promise，
// 请求经 TSFN 转交主线程（ArkTS handler 执行），应答经命令队列回来后兑现。
// 信封注入 __pid（实例 id）与 stream 标记透传，供 ArkTS 桥做流式路由。
JSVM_Value HttpCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    std::string requestJson = "{}";
    if (argc >= 1 && argv[0] != nullptr) {
        requestJson = JsToString(env, argv[0]);
    }

    JSVM_Deferred deferred = nullptr;
    JSVM_Value promise = nullptr;
    OH_JSVM_CreatePromise(env, &deferred, &promise);

    void *envData = nullptr;
    OH_JSVM_GetInstanceData(env, &envData);
    auto *pe = static_cast<PluginEnv *>(envData);
    std::string pid = pe != nullptr ? pe->pluginId : "";
    if (!pid.empty() && !requestJson.empty() && requestJson.back() == '}') {
        requestJson = requestJson.substr(0, requestJson.size() - 1) +
                      ",\"__pid\":\"" + JsonEscapeStr(pid) + "\"}";
    }

    uint64_t httpId = g_httpSeq.fetch_add(1);
    g_httpPendings[httpId] = {env, deferred};
    Runtime::Instance().PostHttpRequest(httpId, requestJson);
    return promise;
}

JSVM_Value GetUndefinedLocal(JSVM_Env env)
{
    JSVM_Value undef = nullptr;
    OH_JSVM_GetUndefined(env, &undef);
    return undef;
}

// nativeLog(level, message)：插件 $log 输出 → hilog + 转投主线程
JSVM_Value LogCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 2;
    JSVM_Value argv[2] = {nullptr, nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    std::string level = argc >= 1 && argv[0] != nullptr ? JsToString(env, argv[0]) : "info";
    std::string message = argc >= 2 && argv[1] != nullptr ? JsToString(env, argv[1]) : "";
    if (level == "error") {
        OH_LOG_ERROR(LOG_APP, "[plugin] %{public}s", message.c_str());
    } else {
        OH_LOG_INFO(LOG_APP, "[plugin] %{public}s", message.c_str());
    }
    Runtime::Instance().PostLog(level, message);
    return GetUndefinedLocal(env);
}

// nativeStreamText(text)：插件 query.onStream 的底层原语（kind=3 转投主线程）
JSVM_Value StreamTextCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    std::string text = argc >= 1 && argv[0] != nullptr ? JsToString(env, argv[0]) : "";
    void *envData = nullptr;
    OH_JSVM_GetInstanceData(env, &envData);
    auto *pe = static_cast<PluginEnv *>(envData);
    std::string pid = pe != nullptr ? pe->pluginId : "";
    Runtime::Instance().PostStreamText(pid, text);
    return GetUndefinedLocal(env);
}

// nativeWsNew(requestJson)：创建 WebSocket（C++ 分配 id 注入信封，返回 id 字符串）
JSVM_Value WsNewCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    std::string requestJson = "{}";
    if (argc >= 1 && argv[0] != nullptr) {
        requestJson = JsToString(env, argv[0]);
    }
    void *envData = nullptr;
    OH_JSVM_GetInstanceData(env, &envData);
    auto *pe = static_cast<PluginEnv *>(envData);
    std::string pid = pe != nullptr ? pe->pluginId : "";
    uint64_t wsId = g_wsSeq.fetch_add(1);
    std::string envelope;
    if (!requestJson.empty() && requestJson.back() == '}') {
        envelope = requestJson.substr(0, requestJson.size() - 1) + ",\"__pid\":\"" +
                   JsonEscapeStr(pid) + "\",\"__wsid\":" + std::to_string(wsId) + "}";
    } else {
        envelope = requestJson;
    }
    Runtime::Instance().PostWsRequest(envelope);
    JSVM_Value out = nullptr;
    OH_JSVM_CreateStringUtf8(env, std::to_string(wsId).c_str(), std::to_string(wsId).size(), &out);
    return out;
}

// nativeWsOp(requestJson)：open/send/close 等操作（fire-and-forget）
JSVM_Value WsOpCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    std::string requestJson = "{}";
    if (argc >= 1 && argv[0] != nullptr) {
        requestJson = JsToString(env, argv[0]);
    }
    void *envData = nullptr;
    OH_JSVM_GetInstanceData(env, &envData);
    auto *pe = static_cast<PluginEnv *>(envData);
    std::string pid = pe != nullptr ? pe->pluginId : "";
    if (!pid.empty() && !requestJson.empty() && requestJson.back() == '}') {
        requestJson = requestJson.substr(0, requestJson.size() - 1) +
                      ",\"__pid\":\"" + JsonEscapeStr(pid) + "\"}";
    }
    Runtime::Instance().PostWsRequest(requestJson);
    return GetUndefinedLocal(env);
}

// nativeAfter(id, delayMs)：到点后以 id 为载荷兑现 Promise（$timer 的底层原语）
JSVM_Value AfterCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    size_t argc = 2;
    JSVM_Value argv[2] = {nullptr, nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, nullptr);
    double id = 0;
    double delayMs = 0;
    if (argc >= 1) {
        OH_JSVM_GetValueDouble(env, argv[0], &id);
    }
    if (argc >= 2) {
        OH_JSVM_GetValueDouble(env, argv[1], &delayMs);
    }

    JSVM_Deferred deferred = nullptr;
    JSVM_Value promise = nullptr;
    OH_JSVM_CreatePromise(env, &deferred, &promise);
    g_afterPendings[static_cast<uint64_t>(id)] = {env, deferred, NowMs() + delayMs};
    return promise;
}

// ---- $file 的 native 同步文件桥 ----

// 虚拟路径 → 沙箱内绝对路径（唯一解析点）：
// '$sandbox' → sandboxDir；'$sandbox/x' → sandboxDir/x；'/' → pluginDir；'/x' → pluginDir/x；拒绝 '..'
bool ResolveVirtual(PluginEnv *pe, const std::string &v, std::string &out)
{
    if (v == "$sandbox") {
        out = pe->sandboxDir;
    } else if (v.rfind("$sandbox/", 0) == 0) {
        out = pe->sandboxDir + "/" + v.substr(9);
    } else if (v == "/") {
        out = pe->pluginDir;
    } else if (!v.empty() && v[0] == '/') {
        out = pe->pluginDir + v;
    } else {
        return false;
    }
    if (out.find("..") != std::string::npos) {
        return false;
    }
    return true;
}

// op 分发：read/write/delete/list/copy/move/mkdir/exists/isdir。
// ok=true 时 result 为回传值（base64 / JSON 数组 / "1"/"0"）；ok=false 时 result 为错误消息。
void RunFileOp(PluginEnv *pe, const std::string &op, const std::string &a, const std::string &b,
               bool &ok, std::string &result)
{
    ok = true;
    std::string pathA;
    if (op != "list" || !a.empty()) {
        if (!ResolveVirtual(pe, a, pathA)) {
            ok = false;
            result = "bad path: " + a;
            return;
        }
    }
    if (op == "read") {
        bool rd = false;
        auto data = ReadAllBytes(pathA, rd);
        if (!rd) { ok = false; result = "read failed"; return; }
        result = B64EncodeBytes(data);
        return;
    }
    if (op == "write") {
        result = WriteAllBytes(pathA, B64DecodeBytes(b)) ? "1" : "0";
        return;
    }
    if (op == "delete") {
        result = remove(pathA.c_str()) == 0 ? "1" : "0";
        return;
    }
    if (op == "list") {
        DIR *dir = opendir(pathA.c_str());
        if (dir == nullptr) { ok = false; result = "list failed"; return; }
        std::string json = "[";
        bool first = true;
        struct dirent *ent = nullptr;
        while ((ent = readdir(dir)) != nullptr) {
            std::string name = ent->d_name;
            if (name == "." || name == "..") { continue; }
            if (!first) { json += ","; }
            json += "\"" + JsonEscapeStr(name) + "\"";
            first = false;
        }
        closedir(dir);
        json += "]";
        result = json;
        return;
    }
    if (op == "mkdir") {
        int rc = mkdir(pathA.c_str(), 0755);
        result = (rc == 0 || errno == EEXIST) ? "1" : "0";
        return;
    }
    if (op == "exists") {
        result = PathExists(pathA, nullptr) ? "1" : "0";
        return;
    }
    if (op == "isdir") {
        bool isDir = false;
        bool ex = PathExists(pathA, &isDir);
        result = (ex && isDir) ? "1" : "0";
        return;
    }
    if (op == "copy" || op == "move") {
        std::string pathB;
        if (!ResolveVirtual(pe, b, pathB)) { ok = false; result = "bad path: " + b; return; }
        bool rd = false;
        auto data = ReadAllBytes(pathA, rd);
        if (!rd || !WriteAllBytes(pathB, data)) { ok = false; result = "copy failed"; return; }
        if (op == "move") { remove(pathA.c_str()); }
        result = "1";
        return;
    }
    ok = false;
    result = "unknown op: " + op;
}

// nativeFileOp(op, path, data?): 同步文件桥，结果以字符串返回
JSVM_Value FileOpCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    void *data = nullptr;
    size_t argc = 3;
    JSVM_Value argv[3] = {nullptr, nullptr, nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &data);
    auto *pe = static_cast<PluginEnv *>(data);
    std::string op = argc >= 1 && argv[0] != nullptr ? JsToString(env, argv[0]) : "";
    std::string a = argc >= 2 && argv[1] != nullptr ? JsToString(env, argv[1]) : "";
    std::string b = argc >= 3 && argv[2] != nullptr ? JsToString(env, argv[2]) : "";
    bool ok = false;
    std::string result;
    RunFileOp(pe, op, a, b, ok, result);
    if (!ok) {
        OH_JSVM_ThrowError(env, nullptr, result.c_str());
        return nullptr;
    }
    JSVM_Value out = nullptr;
    OH_JSVM_CreateStringUtf8(env, result.c_str(), result.size(), &out);
    return out;
}

// 创建插件 Env：注册全局函数 + 求值前奏脚本
PluginEnv *CreatePluginEnv(const std::string &pluginId, const std::string &pluginDir,
                           const std::string &sandboxDir, std::string &err)
{
    JSVM_Env env = nullptr;
    if (OH_JSVM_CreateEnv(g_vm, 0, nullptr, &env) != JSVM_OK || env == nullptr) {
        err = "CreateEnv failed for " + pluginId;
        return nullptr;
    }
    auto *pe = new PluginEnv();
    pe->env = env;
    pe->pluginId = pluginId;
    pe->pluginDir = pluginDir;
    pe->sandboxDir = sandboxDir;
    OH_JSVM_OpenEnvScope(env, &pe->envScope);
    OH_JSVM_SetInstanceData(env, pe, nullptr, nullptr);

    JSVM_HandleScope hs;
    OH_JSVM_OpenHandleScope(env, &hs);

    JSVM_Value global = nullptr;
    OH_JSVM_GetGlobal(env, &global);
    static JSVM_CallbackStruct settleCb = {SettleCb, nullptr};
    static JSVM_CallbackStruct echoCb = {EchoCb, nullptr};
    static JSVM_CallbackStruct httpCb = {HttpCb, nullptr};
    static JSVM_CallbackStruct logCb = {LogCb, nullptr};
    static JSVM_CallbackStruct afterCb = {AfterCb, nullptr};
    static JSVM_CallbackStruct streamCb = {StreamTextCb, nullptr};
    static JSVM_CallbackStruct wsNewCb = {WsNewCb, nullptr};
    static JSVM_CallbackStruct wsOpCb = {WsOpCb, nullptr};
    pe->fileOpCb = {FileOpCb, pe};
    JSVM_Value fn = nullptr;
    OH_JSVM_CreateFunction(env, "__settle", JSVM_AUTO_LENGTH, &settleCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "__settle", fn);
    OH_JSVM_CreateFunction(env, "nativeEcho", JSVM_AUTO_LENGTH, &echoCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeEcho", fn);
    OH_JSVM_CreateFunction(env, "nativeHttp", JSVM_AUTO_LENGTH, &httpCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeHttp", fn);
    OH_JSVM_CreateFunction(env, "nativeLog", JSVM_AUTO_LENGTH, &logCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeLog", fn);
    OH_JSVM_CreateFunction(env, "nativeAfter", JSVM_AUTO_LENGTH, &afterCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeAfter", fn);
    OH_JSVM_CreateFunction(env, "nativeStreamText", JSVM_AUTO_LENGTH, &streamCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeStreamText", fn);
    OH_JSVM_CreateFunction(env, "nativeWsNew", JSVM_AUTO_LENGTH, &wsNewCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeWsNew", fn);
    OH_JSVM_CreateFunction(env, "nativeWsOp", JSVM_AUTO_LENGTH, &wsOpCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeWsOp", fn);
    OH_JSVM_CreateFunction(env, "nativeFileOp", JSVM_AUTO_LENGTH, &pe->fileOpCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeFileOp", fn);
    OH_JSVM_CreateFunction(env, "nativeLog", JSVM_AUTO_LENGTH, &logCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeLog", fn);
    OH_JSVM_CreateFunction(env, "nativeAfter", JSVM_AUTO_LENGTH, &afterCb, &fn);
    OH_JSVM_SetNamedProperty(env, global, "nativeAfter", fn);

    JSVM_Value src = nullptr;
    OH_JSVM_CreateStringUtf8(env, kPrelude, strlen(kPrelude), &src);
    JSVM_Script script = nullptr;
    if (OH_JSVM_CompileScript(env, src, nullptr, 0, true, nullptr, &script) != JSVM_OK ||
        OH_JSVM_RunScript(env, script, &fn) != JSVM_OK) {
        const JSVM_ExtendedErrorInfo *errInfo = nullptr;
        OH_JSVM_GetLastErrorInfo(env, &errInfo);
        err = std::string("prelude failed: ") +
              (errInfo && errInfo->errorMessage ? errInfo->errorMessage : "?");
        OH_JSVM_CloseHandleScope(env, hs);
        OH_JSVM_CloseEnvScope(env, pe->envScope);
        OH_JSVM_DestroyEnv(env);
        delete pe;
        return nullptr;
    }

    OH_JSVM_CloseHandleScope(env, hs);
    return pe;
}

// 求值一段脚本，失败时返回错误信息（空串 = 成功）。
// 失败路径会捕获并清除 env 的挂起异常（GetLastErrorInfo 只给 "An exception is pending"，
// 真实异常内容经 GetAndClearLastException 取出拼进错误信息），同时让 env 恢复可用。
std::string TakePendingException(JSVM_Env env)
{
    bool pending = false;
    OH_JSVM_IsExceptionPending(env, &pending);
    if (!pending) {
        return "";
    }
    JSVM_Value ex = nullptr;
    if (OH_JSVM_GetAndClearLastException(env, &ex) != JSVM_OK || ex == nullptr) {
        return "";
    }
    JSVM_Value str = nullptr;
    if (OH_JSVM_CoerceToString(env, ex, &str) != JSVM_OK || str == nullptr) {
        return "(unstringifiable exception)";
    }
    return JsToString(env, str);
}

std::string EvalScript(JSVM_Env env, const char *code, size_t len, const std::string &what)
{
    JSVM_Value src = nullptr;
    OH_JSVM_CreateStringUtf8(env, code, len, &src);
    JSVM_Script script = nullptr;
    if (OH_JSVM_CompileScript(env, src, nullptr, 0, true, nullptr, &script) != JSVM_OK) {
        const JSVM_ExtendedErrorInfo *errInfo = nullptr;
        OH_JSVM_GetLastErrorInfo(env, &errInfo);
        std::string pending = TakePendingException(env);
        return what + " compile failed: " +
               (errInfo && errInfo->errorMessage ? errInfo->errorMessage : "?") +
               (pending.empty() ? "" : " | " + pending);
    }
    JSVM_Value out = nullptr;
    if (OH_JSVM_RunScript(env, script, &out) != JSVM_OK) {
        const JSVM_ExtendedErrorInfo *errInfo = nullptr;
        OH_JSVM_GetLastErrorInfo(env, &errInfo);
        std::string pending = TakePendingException(env);
        return what + " run failed: " +
               (errInfo && errInfo->errorMessage ? errInfo->errorMessage : "?") +
               (pending.empty() ? "" : " | " + pending);
    }
    return "";
}

// ArkTS 沙箱虚拟路径（/data/storage/el2/base/...）在 native 视图不可靠（stat 时真时假、
// fopen 必败），一律换算为真实路径 /data/app/el2/100/base/<包名>/...。
std::string NativeResolvePath(const std::string &p, const std::string &bundle)
{
    if (p.empty() || bundle.empty()) {
        return p;
    }
    const std::string vprefix = "/data/storage/el2/base/";
    if (p.rfind(vprefix, 0) == 0) {
        return "/data/app/el2/100/base/" + bundle + "/" + p.substr(vprefix.size());
    }
    return p;
}

// 执行 Load 命令：配置注入 → CommonJS 模块系统 → Bob shim → 用户脚本（顺序不可换）
void HandleLoad(const RuntimeCommand &cmd)
{
    // $file 目录：ArkTS 传入虚拟路径（/data/storage/...），native 与 ArkTS 同视图直接使用
    // （此前 native fopen 失败是 JS+native 双重前缀解析所致，非路径视图问题）
    const std::string pluginDir = cmd.pluginDir;
    const std::string sandboxDir = cmd.sandboxDir;
    OH_LOG_INFO(LOG_APP, "load %{public}s bundle=[%{public}s] sandbox=[%{public}s] -> [%{public}s]",
                cmd.pluginId.c_str(), cmd.bundleName.c_str(), cmd.sandboxDir.c_str(), sandboxDir.c_str());

    PluginEnv *pe = nullptr;
    auto it = g_envs.find(cmd.pluginId);
    if (it != g_envs.end()) {
        pe = it->second;
    } else {
        std::string err;
        pe = CreatePluginEnv(cmd.pluginId, pluginDir, sandboxDir, err);
        if (pe == nullptr) {
            g_pendings[cmd.callId] = {NowMs(), false, true, false, false, err};
            return;
        }
        g_envs[cmd.pluginId] = pe;
    }

    JSVM_HandleScope hs;
    OH_JSVM_OpenHandleScope(pe->env, &hs);

    // native 视角确保 $file 沙箱目录存在（见 EnsureDirNative 注释）
    EnsureDirNative(sandboxDir);

    std::string configLiteral = cmd.configJson.empty() ? std::string("{}") : cmd.configJson;
    std::string configCode = "var __phHostConfig = " + configLiteral + ";" +
                             "var __phPluginDir = \"" + JsonEscapeStr(pluginDir) + "\";" +
                             "var __phSandboxDir = \"" + JsonEscapeStr(sandboxDir) + "\";";
    std::string modulesCode = std::string("var __phModules = ") +
                              (cmd.modulesJson.empty() ? "{}" : cmd.modulesJson) + ";\n" +
                              kModulesRuntime;
    std::string err = EvalScript(pe->env, configCode.c_str(), configCode.size(), "config");
    if (err.empty()) {
        err = EvalScript(pe->env, modulesCode.c_str(), modulesCode.size(), "modules");
    }
    if (err.empty()) {
        err = EvalScript(pe->env, kBobShim, strlen(kBobShim), "bobshim");
    }
    if (err.empty()) {
        err = EvalScript(pe->env, cmd.code.c_str(), cmd.code.size(), "plugin");
    }
    const bool ok = err.empty();
    OH_JSVM_CloseHandleScope(pe->env, hs);
    g_pendings[cmd.callId] = {NowMs(), false, true, false, ok,
                              ok ? ("loaded:" + cmd.pluginId) : err};
}

// 执行 Call 命令：经前奏包装函数发起调用，结果稍后经 __settle 回流
void HandleCall(const RuntimeCommand &cmd)
{
    auto it = g_envs.find(cmd.pluginId);
    if (it == g_envs.end()) {
        g_pendings[cmd.callId] = {NowMs(), false, true, false, false,
                                  "plugin not loaded: " + cmd.pluginId};
        return;
    }
    JSVM_Env env = it->second->env;

    JSVM_HandleScope hs;
    OH_JSVM_OpenHandleScope(env, &hs);

    JSVM_Value global = nullptr;
    OH_JSVM_GetGlobal(env, &global);
    JSVM_Value fn = nullptr;
    OH_JSVM_GetNamedProperty(env, global, cmd.fnName.c_str(), &fn);
    bool isFn = false;
    OH_JSVM_IsFunction(env, fn, &isFn);
    if (!isFn) {
        g_pendings[cmd.callId] = {NowMs(), false, true, false, false,
                                  "function not found: " + cmd.fnName};
        OH_JSVM_CloseHandleScope(env, hs);
        return;
    }

    const char *helperName = cmd.mode == 1 ? "__phRunPromise"
                             : cmd.mode == 2 ? "__phRunCallback"
                                             : "__phRunSync";
    JSVM_Value helper = nullptr;
    OH_JSVM_GetNamedProperty(env, global, helperName, &helper);

    JSVM_Value callIdVal = nullptr;
    JSVM_Value argsJsonVal = nullptr;
    OH_JSVM_CreateDouble(env, static_cast<double>(cmd.callId), &callIdVal);
    OH_JSVM_CreateStringUtf8(env, cmd.argsJson.c_str(), cmd.argsJson.size(), &argsJsonVal);

    // 先登记 pending 再调用：sync 模式与同步完成的 callback 会在 CallFunction 期间
    // 就触发 __settle，届时 pending 必须已存在，否则完成信号被丢弃、调用永远超时
    g_pendings[cmd.callId] = {NowMs() + cmd.timeoutMs, false, false, false, true, ""};

    JSVM_Value argv[3] = {callIdVal, fn, argsJsonVal};
    JSVM_Value out = nullptr;
    JSVM_Status st = OH_JSVM_CallFunction(env, global, helper, 3, argv, &out);
    if (st != JSVM_OK) {
        const JSVM_ExtendedErrorInfo *errInfo = nullptr;
        OH_JSVM_GetLastErrorInfo(env, &errInfo);
        std::string pending = TakePendingException(env);
        PendingCall &pc = g_pendings[cmd.callId];
        pc.resolved = true;
        pc.ok = false;
        pc.payload = std::string("call failed: ") +
                     (errInfo && errInfo->errorMessage ? errInfo->errorMessage : "?") +
                     (pending.empty() ? "" : " | " + pending);
    }
    OH_JSVM_CloseHandleScope(env, hs);
}

// 执行 ResolveHttp 命令：用真实 HTTP 应答兑现 nativeHttp 的 Promise
void HandleResolveHttp(const RuntimeCommand &cmd)
{
    auto it = g_httpPendings.find(cmd.callId);
    if (it == g_httpPendings.end()) {
        return; // 调用侧已超时废弃，应答迟到，丢弃
    }
    JSVM_Env env = it->second.env;
    JSVM_Deferred deferred = it->second.deferred;
    g_httpPendings.erase(it);

    JSVM_HandleScope hs;
    OH_JSVM_OpenHandleScope(env, &hs);
    JSVM_Value payload = nullptr;
    OH_JSVM_CreateStringUtf8(env, cmd.payload.c_str(), cmd.payload.size(), &payload);
    if (cmd.ok) {
        OH_JSVM_ResolveDeferred(env, deferred, payload);
    } else {
        OH_JSVM_RejectDeferred(env, deferred, payload);
    }
    OH_JSVM_CloseHandleScope(env, hs);
}

// 执行 DeliverStream 命令：把 SSE 增量回放进插件沙盒（回放 streamHandler）
void HandleDeliverStream(const RuntimeCommand &cmd)
{
    auto it = g_envs.find(cmd.pluginId);
    if (it == g_envs.end()) {
        return;
    }
    JSVM_Env env = it->second->env;
    JSVM_HandleScope hs;
    OH_JSVM_OpenHandleScope(env, &hs);
    JSVM_Value global = nullptr;
    OH_JSVM_GetGlobal(env, &global);
    JSVM_Value fn = nullptr;
    OH_JSVM_GetNamedProperty(env, global, "__phStreamDeliver", &fn);
    bool isFn = false;
    OH_JSVM_IsFunction(env, fn, &isFn);
    if (isFn) {
        JSVM_Value textVal = nullptr;
        OH_JSVM_CreateStringUtf8(env, cmd.payload.c_str(), cmd.payload.size(), &textVal);
        JSVM_Value undef = nullptr;
        OH_JSVM_GetUndefined(env, &undef);
        JSVM_Value out = nullptr;
        OH_JSVM_CallFunction(env, undef, fn, 1, &textVal, &out);
    }
    OH_JSVM_CloseHandleScope(env, hs);
}

// 执行 WsEvent 命令：把 ArkTS WebSocket 事件回放进插件沙盒（__phWsEvent(id, type, dataJson)）
void HandleWsEvent(const RuntimeCommand &cmd)
{
    auto it = g_envs.find(cmd.pluginId);
    if (it == g_envs.end()) {
        return;
    }
    JSVM_Env env = it->second->env;
    JSVM_HandleScope hs;
    OH_JSVM_OpenHandleScope(env, &hs);
    JSVM_Value global = nullptr;
    OH_JSVM_GetGlobal(env, &global);
    JSVM_Value fn = nullptr;
    OH_JSVM_GetNamedProperty(env, global, "__phWsEvent", &fn);
    bool isFn = false;
    OH_JSVM_IsFunction(env, fn, &isFn);
    if (isFn) {
        JSVM_Value args[3] = {nullptr, nullptr, nullptr};
        OH_JSVM_CreateDouble(env, static_cast<double>(cmd.callId), &args[0]);
        OH_JSVM_CreateStringUtf8(env, cmd.fnName.c_str(), cmd.fnName.size(), &args[1]);
        OH_JSVM_CreateStringUtf8(env, cmd.payload.c_str(), cmd.payload.size(), &args[2]);
        JSVM_Value undef = nullptr;
        OH_JSVM_GetUndefined(env, &undef);
        JSVM_Value out = nullptr;
        OH_JSVM_CallFunction(env, undef, fn, 3, args, &out);
    }
    OH_JSVM_CloseHandleScope(env, hs);
}

// 消息泵一轮：微任务 → 宏任务 → 超时回收 → 结果回投主线程
void PumpAndSweep()
{
    OH_JSVM_PerformMicrotaskCheckpoint(g_vm);
    bool more = false;
    OH_JSVM_PumpMessageLoop(g_vm, &more);

    // 定时器到点：以 timerId 兑现 nativeAfter 的 Promise，JS 侧继续执行 handler
    double now = NowMs();
    for (auto it = g_afterPendings.begin(); it != g_afterPendings.end();) {
        if (it->second.fireAtMs <= now) {
            JSVM_HandleScope hs;
            OH_JSVM_OpenHandleScope(it->second.env, &hs);
            JSVM_Value idVal = nullptr;
            OH_JSVM_CreateDouble(it->second.env, static_cast<double>(it->first), &idVal);
            OH_JSVM_ResolveDeferred(it->second.env, it->second.deferred, idVal);
            OH_JSVM_CloseHandleScope(it->second.env, hs);
            it = g_afterPendings.erase(it);
        } else {
            ++it;
        }
    }

    double nowSweep = NowMs();
    for (auto it = g_pendings.begin(); it != g_pendings.end();) {
        PendingCall &pc = it->second;
        if (!pc.resolved && !pc.abandoned && nowSweep > pc.deadlineMs) {
            pc.abandoned = true;
            pc.resolved = true;
            pc.ok = false;
            pc.payload = "timeout";
        }
        if (pc.resolved && !pc.posted) {
            pc.posted = true;
            Runtime::Instance().PostResult(it->first, pc.ok, pc.payload);
            it = g_pendings.erase(it);
        } else {
            ++it;
        }
    }
}

} // namespace

// ---- Runtime ----

Runtime &Runtime::Instance()
{
    static Runtime inst;
    return inst;
}

uint64_t Runtime::NextCallId()
{
    return g_callSeq.fetch_add(1);
}

std::string Runtime::Start(napi_env env, uint64_t startCallId)
{
    std::lock_guard<std::mutex> lk(g_queueMtx);

    // 幂等：runtime 已在运行时，直接兑现成功（重复 initRuntime 不允许再起 worker/VM）
    if (g_started) {
        PostResult(startCallId, true, "started");
        return "";
    }

    napi_value name = nullptr;
    napi_create_string_utf8(env, "pluginhost-result", NAPI_AUTO_LENGTH, &name);
    napi_status st = napi_create_threadsafe_function(
        env, nullptr, nullptr, name, 0, 1, nullptr, nullptr, nullptr,
        [](napi_env nenv, napi_value cb, void *context, void *data) {
            auto *cr = static_cast<CallResult *>(data);
            RuntimeDispatchOnMain(nenv, *cr);
            delete cr;
        },
        &g_tsfn);
    if (st != napi_ok || g_tsfn == nullptr) {
        return "create threadsafe function failed: " + std::to_string(static_cast<int>(st));
    }
    mainEnv_ = env;

    RuntimeCommand cmd;
    cmd.type = RuntimeCommand::Type::Start;
    cmd.callId = startCallId;
    g_queue.push_back(cmd);
    std::thread(&Runtime::WorkerLoop, this).detach();
    g_started = true;
    g_queueCv.notify_one();
    return "";
}

void Runtime::PostResult(uint64_t callId, bool ok, const std::string &payload)
{
    auto *cr = new CallResult{callId, ok, payload, 0};
    napi_call_threadsafe_function(g_tsfn, cr, napi_tsfn_nonblocking);
}

void Runtime::PostHttpRequest(uint64_t httpId, const std::string &requestJson)
{
    auto *cr = new CallResult{httpId, true, requestJson, 1};
    napi_call_threadsafe_function(g_tsfn, cr, napi_tsfn_nonblocking);
}

void Runtime::PostLog(const std::string &level, const std::string &message)
{
    std::string escaped;
    escaped.reserve(message.size() + 16);
    for (char c : message) {
        switch (c) {
            case '"': escaped += "\\\""; break;
            case '\\': escaped += "\\\\"; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) >= 0x20) {
                    escaped += c;
                }
                break;
        }
    }
    auto *cr = new CallResult{0, true, "{\"level\":\"" + level + "\",\"message\":\"" + escaped + "\"}", 2};
    napi_call_threadsafe_function(g_tsfn, cr, napi_tsfn_nonblocking);
}

void Runtime::PostStreamText(const std::string &pluginId, const std::string &text)
{
    std::string escaped;
    escaped.reserve(text.size() + 16);
    for (char c : text) {
        switch (c) {
            case '"': escaped += "\\\""; break;
            case '\\': escaped += "\\\\"; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) >= 0x20) {
                    escaped += c;
                }
                break;
        }
    }
    std::string json = "{\"pluginId\":\"" + pluginId + "\",\"text\":\"" + escaped + "\"}";
    auto *cr = new CallResult{0, true, json, 3};
    napi_call_threadsafe_function(g_tsfn, cr, napi_tsfn_nonblocking);
}

void Runtime::PostDeliverStream(const std::string &pluginId, const std::string &text)
{
    std::lock_guard<std::mutex> lk(g_queueMtx);
    RuntimeCommand cmd;
    cmd.type = RuntimeCommand::Type::DeliverStream;
    cmd.pluginId = pluginId;
    cmd.payload = text;
    g_queue.push_back(cmd);
    g_queueCv.notify_one();
}

void Runtime::PostWsRequest(const std::string &requestJson)
{
    auto *cr = new CallResult{0, true, requestJson, 4};
    napi_call_threadsafe_function(g_tsfn, cr, napi_tsfn_nonblocking);
}

void Runtime::PostWsEvent(const std::string &pluginId, uint64_t wsId, const std::string &type,
                          const std::string &dataJson)
{
    std::lock_guard<std::mutex> lk(g_queueMtx);
    RuntimeCommand cmd;
    cmd.type = RuntimeCommand::Type::WsEvent;
    cmd.pluginId = pluginId;
    cmd.callId = wsId;
    cmd.fnName = type;
    cmd.payload = dataJson;
    g_queue.push_back(cmd);
    g_queueCv.notify_one();
}

void Runtime::PostResolveHttp(uint64_t httpId, bool ok, const std::string &responseJson)
{
    std::lock_guard<std::mutex> lk(g_queueMtx);
    RuntimeCommand cmd;
    cmd.type = RuntimeCommand::Type::ResolveHttp;
    cmd.callId = httpId;
    cmd.ok = ok;
    cmd.payload = responseJson;
    g_queue.push_back(cmd);
    g_queueCv.notify_one();
}

void Runtime::PostLoad(uint64_t callId, const std::string &pluginId, const std::string &code,
                       const std::string &configJson, const std::string &modulesJson,
                       const std::string &pluginDir, const std::string &sandboxDir,
                       const std::string &bundleName)
{
    std::lock_guard<std::mutex> lk(g_queueMtx);
    RuntimeCommand cmd;
    cmd.type = RuntimeCommand::Type::Load;
    cmd.callId = callId;
    cmd.pluginId = pluginId;
    cmd.code = code;
    cmd.configJson = configJson;
    cmd.modulesJson = modulesJson;
    cmd.pluginDir = pluginDir;
    cmd.sandboxDir = sandboxDir;
    cmd.bundleName = bundleName;
    g_queue.push_back(cmd);
    g_queueCv.notify_one();
}

void Runtime::PostCall(uint64_t callId, const std::string &pluginId, const std::string &fnName,
                       const std::string &argsJson, int mode, double timeoutMs)
{
    std::lock_guard<std::mutex> lk(g_queueMtx);
    RuntimeCommand cmd;
    cmd.type = RuntimeCommand::Type::Call;
    cmd.callId = callId;
    cmd.pluginId = pluginId;
    cmd.fnName = fnName;
    cmd.argsJson = argsJson;
    cmd.mode = mode;
    cmd.timeoutMs = timeoutMs;
    g_queue.push_back(cmd);
    g_queueCv.notify_one();
}

void Runtime::WorkerLoop()
{
    EnsureJsvmInit();

    uint64_t startCallId = 0;
    {
        std::lock_guard<std::mutex> lk(g_queueMtx);
        if (!g_queue.empty() && g_queue.front().type == RuntimeCommand::Type::Start) {
            startCallId = g_queue.front().callId;
            g_queue.pop_front();
        }
    }

    JSVM_CreateVMOptions vmOptions = {};
    if (OH_JSVM_CreateVM(&vmOptions, &g_vm) != JSVM_OK || g_vm == nullptr) {
        PostResult(startCallId, false, "CreateVM failed");
        return;
    }
    JSVM_VMScope vmScope;
    OH_JSVM_OpenVMScope(g_vm, &vmScope);
    PostResult(startCallId, true, "started");

    for (;;) {
        std::deque<RuntimeCommand> batch;
        {
            std::unique_lock<std::mutex> lk(g_queueMtx);
            if (g_queue.empty()) {
                g_queueCv.wait_for(lk, std::chrono::milliseconds(20));
            }
            batch.swap(g_queue);
        }
        for (const auto &cmd : batch) {
            if (cmd.type == RuntimeCommand::Type::Load) {
                HandleLoad(cmd);
            } else if (cmd.type == RuntimeCommand::Type::Call) {
                HandleCall(cmd);
            } else if (cmd.type == RuntimeCommand::Type::ResolveHttp) {
                HandleResolveHttp(cmd);
            } else if (cmd.type == RuntimeCommand::Type::DeliverStream) {
                HandleDeliverStream(cmd);
            } else if (cmd.type == RuntimeCommand::Type::WsEvent) {
                HandleWsEvent(cmd);
            }
        }
        if (!batch.empty() || !g_pendings.empty()) {
            PumpAndSweep();
        }
    }

    OH_JSVM_CloseVMScope(g_vm, vmScope);
    OH_JSVM_DestroyVM(g_vm);
}

} // namespace pluginhost
