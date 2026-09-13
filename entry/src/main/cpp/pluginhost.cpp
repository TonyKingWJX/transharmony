/**
 * pluginhost: JS 插件宿主 native 模块（Bob/Manggo 插件兼容底座）。
 *
 * spike 阶段验证三件事：
 *  1. JSVM(ark_runtime/jsvm.h) 在应用内可创建 VM/Env，native 函数可注册为 JS 全局；
 *  2. JS 侧 async/await + native 提供的 Promise 能被宿主消息泵驱动到完成，结果经 NAPI 异步回传 ArkTS；
 *  3. ESM 语法（export/import）是否被 CompileScript 接受 —— 决定 Manggo 插件(强制 ESM)走 JSVM 还是备选 QuickJS。
 *
 * 线程模型：每次调用创建独立 VM，全部 JSVM 调用约束在 napi 异步工作的 execute 线程上，
 * complete 回调回主线程兑现 ArkTS Promise。
 */
#include "napi/native_api.h"
#include "ark_runtime/jsvm.h"
#include "jsvm_runtime.h"
#include <hilog/log.h>

#include <chrono>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0202
#define LOG_TAG "PluginHost"

// ==================== 常驻 Runtime 的 NAPI 桥 ====================

namespace {

// callId → deferred 登记（仅主线程访问：创建、兑现都在主线程）
std::map<uint64_t, napi_deferred> g_mainDeferred;

// ArkTS 注册的 HTTP handler（主线程创建与调用）
napi_ref g_httpHandlerRef = nullptr;
// ArkTS 注册的日志 handler（接收 {"level","message"} JSON 字符串）
napi_ref g_logHandlerRef = nullptr;
// ArkTS 注册的插件流式输出 handler（接收 {"pluginId","text"} JSON 字符串）
napi_ref g_streamHandlerRef = nullptr;
// ArkTS 注册的 WebSocket 操作 handler（接收操作 JSON：op/id/url/header/__pid/__wsid）
napi_ref g_wsHandlerRef = nullptr;

// 建 Promise 并登记 deferred；callId 带回给调用方投递命令
napi_value BeginRuntimeCall(napi_env env, uint64_t &callId)
{
    callId = pluginhost::Runtime::Instance().NextCallId();
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    napi_create_promise(env, &deferred, &promise);
    g_mainDeferred[callId] = deferred;
    return promise;
}

// 在主线程立即兑现（命令投递失败等同步错误路径）
void CompleteOnMain(napi_env env, uint64_t callId, bool ok, const std::string &payload)
{
    auto it = g_mainDeferred.find(callId);
    if (it == g_mainDeferred.end()) {
        return;
    }
    napi_deferred d = it->second;
    g_mainDeferred.erase(it);
    napi_value result = nullptr;
    napi_create_string_utf8(env, payload.c_str(), payload.size(), &result);
    if (ok) {
        napi_resolve_deferred(env, d, result);
    } else {
        napi_reject_deferred(env, d, result);
    }
}

} // namespace

namespace pluginhost {

// TSFN 回调（主线程）：按 kind 分发 —— 0: 兑现 deferred；1: HTTP 请求转交 ArkTS handler
void RuntimeDispatchOnMain(napi_env env, const CallResult &cr)
{
    if (cr.kind == 1) {
        if (g_httpHandlerRef == nullptr) {
            Runtime::Instance().PostResolveHttp(cr.callId, false,
                                                "{\"message\":\"http handler not registered\"}");
            return;
        }
        napi_value fn = nullptr;
        napi_get_reference_value(env, g_httpHandlerRef, &fn);
        napi_value undef = nullptr;
        napi_get_undefined(env, &undef);
        napi_value idVal = nullptr;
        napi_create_double(env, static_cast<double>(cr.callId), &idVal);
        napi_value reqVal = nullptr;
        napi_create_string_utf8(env, cr.payload.c_str(), cr.payload.size(), &reqVal);
        napi_value args[2] = {idVal, reqVal};
        napi_value res = nullptr;
        napi_call_function(env, undef, fn, 2, args, &res);
        return;
    }
    if (cr.kind == 4) {
        // WebSocket 操作：转交 ArkTS handler（若有）
        if (g_wsHandlerRef == nullptr) {
            return;
        }
        napi_value fn = nullptr;
        napi_get_reference_value(env, g_wsHandlerRef, &fn);
        napi_value undef = nullptr;
        napi_get_undefined(env, &undef);
        napi_value reqVal = nullptr;
        napi_create_string_utf8(env, cr.payload.c_str(), cr.payload.size(), &reqVal);
        napi_value res = nullptr;
        napi_call_function(env, undef, fn, 1, &reqVal, &res);
        return;
    }
    if (cr.kind == 3) {
        // 插件流式输出：转交 ArkTS handler（若有）
        if (g_streamHandlerRef == nullptr) {
            return;
        }
        napi_value fn = nullptr;
        napi_get_reference_value(env, g_streamHandlerRef, &fn);
        napi_value undef = nullptr;
        napi_get_undefined(env, &undef);
        napi_value msgVal = nullptr;
        napi_create_string_utf8(env, cr.payload.c_str(), cr.payload.size(), &msgVal);
        napi_value res = nullptr;
        napi_call_function(env, undef, fn, 1, &msgVal, &res);
        return;
    }
    if (cr.kind == 2) {
        // 插件日志：转交 ArkTS handler（若有）
        if (g_logHandlerRef == nullptr) {
            return;
        }
        napi_value fn = nullptr;
        napi_get_reference_value(env, g_logHandlerRef, &fn);
        napi_value undef = nullptr;
        napi_get_undefined(env, &undef);
        napi_value msgVal = nullptr;
        napi_create_string_utf8(env, cr.payload.c_str(), cr.payload.size(), &msgVal);
        napi_value res = nullptr;
        napi_call_function(env, undef, fn, 1, &msgVal, &res);
        return;
    }
    CompleteOnMain(env, cr.callId, cr.ok, cr.payload);
}

} // namespace pluginhost

namespace {

// initRuntime(): Promise<string>
napi_value InitRuntime(napi_env env, napi_callback_info info)
{
    uint64_t callId = 0;
    napi_value promise = BeginRuntimeCall(env, callId);
    std::string err = pluginhost::Runtime::Instance().Start(env, callId);
    if (!err.empty()) {
        CompleteOnMain(env, callId, false, err);
    }
    return promise;
}

// loadPlugin(pluginId, code, configJson?, modulesJson?, pluginDir?, sandboxDir?, bundleName?, kind?): Promise<string>
// kind: 'bob'（默认，Bob shim）| 'manggo'（manggo 启动脚本）
napi_value LoadPlugin(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "loadPlugin requires (pluginId, code, ...)");
        return nullptr;
    }
    auto readStr = [&](napi_value v) -> std::string {
        size_t n = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &n);
        std::vector<char> buf(n + 1, '\0');
        napi_get_value_string_utf8(env, v, buf.data(), n + 1, &n);
        return std::string(buf.data(), n);
    };

    std::string pluginId = readStr(argv[0]);
    std::string code = readStr(argv[1]);
    std::string configJson = argc >= 3 ? readStr(argv[2]) : "";
    std::string modulesJson = argc >= 4 ? readStr(argv[3]) : "";
    std::string pluginDir = argc >= 5 ? readStr(argv[4]) : "";
    std::string sandboxDir = argc >= 6 ? readStr(argv[5]) : "";
    std::string bundleName = argc >= 7 ? readStr(argv[6]) : "";
    std::string kind = argc >= 8 ? readStr(argv[7]) : "";

    uint64_t callId = 0;
    napi_value promise = BeginRuntimeCall(env, callId);
    pluginhost::Runtime::Instance().PostLoad(callId, pluginId, code, configJson, modulesJson,
                                             pluginDir, sandboxDir, bundleName, kind);
    return promise;
}

// unloadPlugin(pluginId): Promise<string> —— 销毁插件 Env（配置变更/重装后的干净重载）
napi_value UnloadPlugin(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "unloadPlugin requires (pluginId)");
        return nullptr;
    }
    size_t n = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &n);
    std::vector<char> buf(n + 1, '\0');
    napi_get_value_string_utf8(env, argv[0], buf.data(), n + 1, &n);
    std::string pluginId(buf.data(), n);

    uint64_t callId = 0;
    napi_value promise = BeginRuntimeCall(env, callId);
    pluginhost::Runtime::Instance().PostUnload(callId, pluginId);
    return promise;
}

// callPluginFn(pluginId, fnName, argsJson, mode: 'sync'|'promise'|'callback', timeoutMs): Promise<string>
napi_value CallPluginFn(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_type_error(env, nullptr, "callPluginFn requires (pluginId, fnName, argsJson, mode, timeoutMs)");
        return nullptr;
    }

    auto readStr = [&](napi_value v) -> std::string {
        size_t n = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &n);
        std::vector<char> buf(n + 1, '\0');
        napi_get_value_string_utf8(env, v, buf.data(), n + 1, &n);
        return std::string(buf.data(), n);
    };

    std::string pluginId = readStr(argv[0]);
    std::string fnName = readStr(argv[1]);
    std::string argsJson = readStr(argv[2]);
    std::string mode = readStr(argv[3]);
    double timeoutMs = 5000.0;
    napi_get_value_double(env, argv[4], &timeoutMs);

    int modeInt = 0;
    if (mode == "promise") {
        modeInt = 1;
    } else if (mode == "callback") {
        modeInt = 2;
    }

    uint64_t callId = 0;
    napi_value promise = BeginRuntimeCall(env, callId);
    pluginhost::Runtime::Instance().PostCall(callId, pluginId, fnName, argsJson, modeInt, timeoutMs);
    return promise;
}

// registerHttpHandler(handler: (httpId: number, requestJson: string) => void): void
napi_value RegisterHttpHandler(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype t = napi_undefined;
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "registerHttpHandler requires (handler)");
        return nullptr;
    }
    napi_typeof(env, argv[0], &t);
    if (t != napi_function) {
        napi_throw_type_error(env, nullptr, "handler must be a function");
        return nullptr;
    }
    if (g_httpHandlerRef != nullptr) {
        napi_delete_reference(env, g_httpHandlerRef);
        g_httpHandlerRef = nullptr;
    }
    napi_create_reference(env, argv[0], 1, &g_httpHandlerRef);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

// resolveHttp(httpId: number, ok: number, payload: string): void
napi_value ResolveHttp(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_type_error(env, nullptr, "resolveHttp requires (httpId, ok, payload)");
        return nullptr;
    }
    double httpId = 0;
    double ok = 0;
    napi_get_value_double(env, argv[0], &httpId);
    napi_get_value_double(env, argv[1], &ok);
    size_t n = 0;
    napi_get_value_string_utf8(env, argv[2], nullptr, 0, &n);
    std::vector<char> buf(n + 1, '\0');
    napi_get_value_string_utf8(env, argv[2], buf.data(), n + 1, &n);

    pluginhost::Runtime::Instance().PostResolveHttp(static_cast<uint64_t>(httpId), ok != 0,
                                                    std::string(buf.data(), n));
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

// registerLogHandler(handler: (logJson: string) => void): void
napi_value RegisterLogHandler(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype t = napi_undefined;
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "registerLogHandler requires (handler)");
        return nullptr;
    }
    napi_typeof(env, argv[0], &t);
    if (t != napi_function) {
        napi_throw_type_error(env, nullptr, "handler must be a function");
        return nullptr;
    }
    if (g_logHandlerRef != nullptr) {
        napi_delete_reference(env, g_logHandlerRef);
        g_logHandlerRef = nullptr;
    }
    napi_create_reference(env, argv[0], 1, &g_logHandlerRef);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

// registerStreamHandler(handler: (streamJson: string) => void): void
napi_value RegisterStreamHandler(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype t = napi_undefined;
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "registerStreamHandler requires (handler)");
        return nullptr;
    }
    napi_typeof(env, argv[0], &t);
    if (t != napi_function) {
        napi_throw_type_error(env, nullptr, "handler must be a function");
        return nullptr;
    }
    if (g_streamHandlerRef != nullptr) {
        napi_delete_reference(env, g_streamHandlerRef);
        g_streamHandlerRef = nullptr;
    }
    napi_create_reference(env, argv[0], 1, &g_streamHandlerRef);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

// deliverStream(pluginId: string, text: string): void
napi_value DeliverStream(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "deliverStream requires (pluginId, text)");
        return nullptr;
    }
    auto readStr = [&](napi_value v) -> std::string {
        size_t n = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &n);
        std::vector<char> buf(n + 1, '\0');
        napi_get_value_string_utf8(env, v, buf.data(), n + 1, &n);
        return std::string(buf.data(), n);
    };
    pluginhost::Runtime::Instance().PostDeliverStream(readStr(argv[0]), readStr(argv[1]));
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

// registerWsHandler(handler: (reqJson: string) => void): void
napi_value RegisterWsHandler(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype t = napi_undefined;
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "registerWsHandler requires (handler)");
        return nullptr;
    }
    napi_typeof(env, argv[0], &t);
    if (t != napi_function) {
        napi_throw_type_error(env, nullptr, "handler must be a function");
        return nullptr;
    }
    if (g_wsHandlerRef != nullptr) {
        napi_delete_reference(env, g_wsHandlerRef);
        g_wsHandlerRef = nullptr;
    }
    napi_create_reference(env, argv[0], 1, &g_wsHandlerRef);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

// deliverWsEvent(pid: string, wsId: number, type: string, dataJson: string): void
napi_value DeliverWsEvent(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "deliverWsEvent requires (pid, wsId, type, dataJson)");
        return nullptr;
    }
    auto readStr = [&](napi_value v) -> std::string {
        size_t n = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &n);
        std::vector<char> buf(n + 1, '\0');
        napi_get_value_string_utf8(env, v, buf.data(), n + 1, &n);
        return std::string(buf.data(), n);
    };
    double wsId = 0;
    napi_get_value_double(env, argv[1], &wsId);
    pluginhost::Runtime::Instance().PostWsEvent(readStr(argv[0]),
                                                static_cast<uint64_t>(wsId),
                                                readStr(argv[2]), readStr(argv[3]));
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

} // namespace

namespace {

std::once_flag g_jsvmInitOnce;

// OH_JSVM_Init 进程内只允许一次
void EnsureJsvmInit()
{
    std::call_once(g_jsvmInitOnce, []() {
        JSVM_InitOptions initOptions = {};
        JSVM_Status st = OH_JSVM_Init(&initOptions);
        OH_LOG_INFO(LOG_APP, "JSVM_Init status=%{public}d", st);
    });
}

// 默认探针脚本：同步 native 调用 / await native 异步 Promise / 纯 JS 计算 / 完成回调
const char *kDefaultScript = R"JS(
(async () => {
    const echoed = await nativeEcho('hello');
    const fetched = await nativeFetch('https://example.com/api?probe=1');
    const computed = [1, 2, 3].map(x => x * 2).join('-');
    __complete(echoed + '|' + fetched + '|' + computed + '|js-ok');
})()
)JS";

struct PendingFetch {
    JSVM_Deferred deferred = nullptr;
    std::string payload;
};

struct RunContext {
    bool done = false;
    std::string result;
    std::vector<PendingFetch> pending;
};

std::string JsToString(JSVM_Env env, JSVM_Value value)
{
    size_t len = 0;
    OH_JSVM_GetValueStringUtf8(env, value, nullptr, 0, &len);
    std::vector<char> buf(len + 1, '\0');
    size_t copied = 0;
    OH_JSVM_GetValueStringUtf8(env, value, buf.data(), len + 1, &copied);
    return std::string(buf.data(), copied);
}

JSVM_Value GetUndefined(JSVM_Env env)
{
    JSVM_Value undef = nullptr;
    OH_JSVM_GetUndefined(env, &undef);
    return undef;
}

// ---- 注册给 JS 的 native 函数 ----

// __complete(text)：JS 侧完成信号（真实宿主里对应结果回传）
JSVM_Value CompleteCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    void *data = nullptr;
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &data);
    auto *ctx = static_cast<RunContext *>(data);
    if (argc >= 1 && argv[0] != nullptr) {
        ctx->result = JsToString(env, argv[0]);
    }
    ctx->done = true;
    return GetUndefined(env);
}

// nativeEcho(text)：同步 native 调用往返
JSVM_Value EchoCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    void *data = nullptr;
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &data);
    if (argc < 1 || argv[0] == nullptr) {
        return GetUndefined(env);
    }
    std::string out = "echo(" + JsToString(env, argv[0]) + ")";
    JSVM_Value result = nullptr;
    OH_JSVM_CreateStringUtf8(env, out.c_str(), out.size(), &result);
    return result;
}

// nativeFetch(url)：模拟异步 HTTP —— 立即返回未决 Promise，宿主在消息泵里兑现
// （真实实现里由 @ohos.net.http 回调线程投递结果后兑现，机制相同）
JSVM_Value FetchCb(JSVM_Env env, JSVM_CallbackInfo info)
{
    void *data = nullptr;
    size_t argc = 1;
    JSVM_Value argv[1] = {nullptr};
    OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &data);
    auto *ctx = static_cast<RunContext *>(data);

    std::string url = "(no-url)";
    if (argc >= 1 && argv[0] != nullptr) {
        url = JsToString(env, argv[0]);
    }

    JSVM_Deferred deferred = nullptr;
    JSVM_Value promise = nullptr;
    OH_JSVM_CreatePromise(env, &deferred, &promise);
    ctx->pending.push_back({deferred, "http-200(" + url + ")"});
    return promise;
}

// ---- 一次运行的载体 ----

struct RunRequest {
    int mode = 0; // 0=runTest 1=esmProbe
    std::string script;
    double timeoutMs = 5000.0;
    bool ok = false;
    std::string result;
};

void FailReq(RunRequest &req, const std::string &what, JSVM_Env env = nullptr)
{
    req.result = what;
    if (env != nullptr) {
        const JSVM_ExtendedErrorInfo *err = nullptr;
        OH_JSVM_GetLastErrorInfo(env, &err);
        if (err != nullptr && err->errorMessage != nullptr) {
            req.result += ": ";
            req.result += err->errorMessage;
        }
    }
}

// 在 worker 线程上完整跑一次脚本：VM/Env 的所有 JSVM 调用都约束在本线程
void ExecuteRun(RunRequest &req)
{
    EnsureJsvmInit();

    JSVM_VM vm = nullptr;
    JSVM_CreateVMOptions vmOptions = {};
    if (OH_JSVM_CreateVM(&vmOptions, &vm) != JSVM_OK) {
        FailReq(req, "CreateVM failed");
        return;
    }
    JSVM_VMScope vmScope;
    OH_JSVM_OpenVMScope(vm, &vmScope);

    JSVM_Env env = nullptr;
    if (OH_JSVM_CreateEnv(vm, 0, nullptr, &env) != JSVM_OK) {
        FailReq(req, "CreateEnv failed");
        OH_JSVM_CloseVMScope(vm, vmScope);
        OH_JSVM_DestroyVM(vm);
        return;
    }
    JSVM_EnvScope envScope;
    OH_JSVM_OpenEnvScope(env, &envScope);

    JSVM_HandleScope handleScope;
    OH_JSVM_OpenHandleScope(env, &handleScope);

    RunContext ctx;

    JSVM_Value global = nullptr;
    OH_JSVM_GetGlobal(env, &global);
    JSVM_CallbackStruct completeCb = {CompleteCb, &ctx};
    JSVM_CallbackStruct echoCb = {EchoCb, &ctx};
    JSVM_CallbackStruct fetchCb = {FetchCb, &ctx};
    JSVM_Value fnComplete = nullptr;
    JSVM_Value fnEcho = nullptr;
    JSVM_Value fnFetch = nullptr;
    OH_JSVM_CreateFunction(env, "__complete", JSVM_AUTO_LENGTH, &completeCb, &fnComplete);
    OH_JSVM_CreateFunction(env, "nativeEcho", JSVM_AUTO_LENGTH, &echoCb, &fnEcho);
    OH_JSVM_CreateFunction(env, "nativeFetch", JSVM_AUTO_LENGTH, &fetchCb, &fnFetch);
    OH_JSVM_SetNamedProperty(env, global, "__complete", fnComplete);
    OH_JSVM_SetNamedProperty(env, global, "nativeEcho", fnEcho);
    OH_JSVM_SetNamedProperty(env, global, "nativeFetch", fnFetch);

    JSVM_Value src = nullptr;
    OH_JSVM_CreateStringUtf8(env, req.script.c_str(), req.script.size(), &src);
    JSVM_Script script = nullptr;
    if (OH_JSVM_CompileScript(env, src, nullptr, 0, true, nullptr, &script) != JSVM_OK) {
        FailReq(req, "compile failed", env);
    } else {
        JSVM_Value scriptResult = nullptr;
        if (OH_JSVM_RunScript(env, script, &scriptResult) != JSVM_OK) {
            FailReq(req, "run failed", env);
        } else {
            // 消息泵：兑现挂起 Promise → 微任务（await 续体）→ 宏任务，直到完成信号或超时
            auto deadline = std::chrono::steady_clock::now() +
                            std::chrono::milliseconds(static_cast<long long>(req.timeoutMs));
            while (!ctx.done) {
                std::vector<PendingFetch> ready;
                ready.swap(ctx.pending);
                for (auto &p : ready) {
                    JSVM_Value payload = nullptr;
                    OH_JSVM_CreateStringUtf8(env, p.payload.c_str(), p.payload.size(), &payload);
                    OH_JSVM_ResolveDeferred(env, p.deferred, payload);
                }
                OH_JSVM_PerformMicrotaskCheckpoint(vm);
                bool more = false;
                OH_JSVM_PumpMessageLoop(vm, &more);
                if (ctx.done) {
                    break;
                }
                if (!more) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                }
                if (std::chrono::steady_clock::now() > deadline) {
                    req.result = "timeout: __complete not called within " +
                                 std::to_string(static_cast<int>(req.timeoutMs)) + "ms";
                    break;
                }
            }
            if (ctx.done) {
                req.ok = true;
                req.result = ctx.result;
            }
        }
    }

    OH_JSVM_CloseHandleScope(env, handleScope);
    OH_JSVM_CloseEnvScope(env, envScope);
    OH_JSVM_DestroyEnv(env);
    OH_JSVM_CloseVMScope(vm, vmScope);
    OH_JSVM_DestroyVM(vm);
}

// ESM 语法探针：分别编译普通脚本与带 export/import 的代码，报告接受情况
void ExecuteEsmProbe(RunRequest &req)
{
    EnsureJsvmInit();

    const char *kPlain = "var x = 1; x + 1;";
    const char *kEsm = "export const a = 1; export default function f() { return 2; }";
    const char *kEsmImport = "import { a } from './other.js'; a;";

    JSVM_VM vm = nullptr;
    JSVM_CreateVMOptions vmOptions = {};
    if (OH_JSVM_CreateVM(&vmOptions, &vm) != JSVM_OK) {
        FailReq(req, "CreateVM failed");
        return;
    }
    JSVM_VMScope vmScope;
    OH_JSVM_OpenVMScope(vm, &vmScope);
    JSVM_Env env = nullptr;
    if (OH_JSVM_CreateEnv(vm, 0, nullptr, &env) != JSVM_OK) {
        FailReq(req, "CreateEnv failed");
        OH_JSVM_CloseVMScope(vm, vmScope);
        OH_JSVM_DestroyVM(vm);
        return;
    }
    JSVM_EnvScope envScope;
    OH_JSVM_OpenEnvScope(env, &envScope);
    JSVM_HandleScope handleScope;
    OH_JSVM_OpenHandleScope(env, &handleScope);

    auto tryCompile = [&](const char *code) -> std::string {
        JSVM_Value src = nullptr;
        OH_JSVM_CreateStringUtf8(env, code, strlen(code), &src);
        JSVM_Script script = nullptr;
        if (OH_JSVM_CompileScript(env, src, nullptr, 0, true, nullptr, &script) == JSVM_OK) {
            JSVM_Value result = nullptr;
            if (OH_JSVM_RunScript(env, script, &result) != JSVM_OK) {
                const JSVM_ExtendedErrorInfo *err = nullptr;
                OH_JSVM_GetLastErrorInfo(env, &err);
                return std::string("run-error(") +
                       (err && err->errorMessage ? err->errorMessage : "?") + ")";
            }
            return "ok";
        }
        const JSVM_ExtendedErrorInfo *err = nullptr;
        OH_JSVM_GetLastErrorInfo(env, &err);
        return std::string("compile-error(") +
               (err && err->errorMessage ? err->errorMessage : "?") + ")";
    };

    req.ok = true;
    req.result = "plain=" + tryCompile(kPlain) + "; esmExport=" + tryCompile(kEsm) +
                 "; esmImport=" + tryCompile(kEsmImport);

    OH_JSVM_CloseHandleScope(env, handleScope);
    OH_JSVM_CloseEnvScope(env, envScope);
    OH_JSVM_DestroyEnv(env);
    OH_JSVM_CloseVMScope(vm, vmScope);
    OH_JSVM_DestroyVM(vm);
}

// ---- NAPI 异步桥 ----

struct WorkData {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    RunRequest req;
};

void ExecuteWork(napi_env env, void *data)
{
    auto *wd = static_cast<WorkData *>(data);
    if (wd->req.mode == 1) {
        ExecuteEsmProbe(wd->req);
    } else {
        ExecuteRun(wd->req);
    }
}

void CompleteWork(napi_env env, napi_status status, void *data)
{
    auto *wd = static_cast<WorkData *>(data);
    napi_value result = nullptr;
    napi_create_string_utf8(env, wd->req.result.c_str(), wd->req.result.size(), &result);
    if (wd->req.ok) {
        napi_resolve_deferred(env, wd->deferred, result);
    } else {
        napi_reject_deferred(env, wd->deferred, result);
    }
    napi_delete_async_work(env, wd->work);
    delete wd;
}

// runTest(script?: string, timeoutMs?: number): Promise<string>
napi_value RunTest(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    auto *wd = new WorkData();
    wd->env = env;
    wd->req.mode = 0;

    if (argc >= 1) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, argv[0], &t);
        if (t == napi_string) {
            size_t n = 0;
            napi_get_value_string_utf8(env, argv[0], nullptr, 0, &n);
            std::vector<char> buf(n + 1, '\0');
            napi_get_value_string_utf8(env, argv[0], buf.data(), n + 1, &n);
            wd->req.script.assign(buf.data(), n);
        }
    }
    if (wd->req.script.empty()) {
        wd->req.script = kDefaultScript;
    }
    if (argc >= 2) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, argv[1], &t);
        if (t == napi_number) {
            napi_get_value_double(env, argv[1], &wd->req.timeoutMs);
        }
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &wd->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "jsvmRunTest", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteWork, CompleteWork, wd, &wd->work);
    napi_queue_async_work(env, wd->work);
    return promise;
}

// esmProbe(): Promise<string>
napi_value EsmProbe(napi_env env, napi_callback_info info)
{
    auto *wd = new WorkData();
    wd->env = env;
    wd->req.mode = 1;

    napi_value promise = nullptr;
    napi_create_promise(env, &wd->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "jsvmEsmProbe", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, ExecuteWork, CompleteWork, wd, &wd->work);
    napi_queue_async_work(env, wd->work);
    return promise;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"runTest", nullptr, RunTest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"esmProbe", nullptr, EsmProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initRuntime", nullptr, InitRuntime, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadPlugin", nullptr, LoadPlugin, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unloadPlugin", nullptr, UnloadPlugin, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"callPluginFn", nullptr, CallPluginFn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerHttpHandler", nullptr, RegisterHttpHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resolveHttp", nullptr, ResolveHttp, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerLogHandler", nullptr, RegisterLogHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerStreamHandler", nullptr, RegisterStreamHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deliverStream", nullptr, DeliverStream, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerWsHandler", nullptr, RegisterWsHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deliverWsEvent", nullptr, DeliverWsEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module pluginhostModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "pluginhost",
    .nm_priv = static_cast<void *>(nullptr),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterPluginHostModule(void)
{
    napi_module_register(&pluginhostModule);
}
