/**
 * jsvm_runtime: 常驻 JSVM 运行时（插件宿主核心）。
 *
 * 架构：
 *  - 单 worker 线程独占一个进程级 JSVM VM；每个插件一个独立 Env（全局隔离）。
 *  - ArkTS 通过命令队列（mutex+condvar）向 worker 投递 加载脚本 / 调用函数 / HTTP 应答；
 *    worker 通过 NAPI threadsafe function 把结果回投主线程，兑现 ArkTS Promise。
 *  - 调用模式三种：sync（同步返回）/ promise（返回 Promise，Manggo 风格）/
 *    callback（末参 completion 回调，Bob 风格）。结果统一经 JSON 字符串回传。
 *  - HTTP 桥：插件调用 nativeHttp(requestJson) 得到未决 Promise，请求经 TSFN 送主线程
 *    （主线程再交 ArkTS 注册的 handler 执行真实网络请求），应答经命令队列回 worker 兑现。
 *  - 超时：异步等待型在消息泵里按 deadline 判定并返回 timeout，迟到的完成被丢弃；
 *    同步死循环无法中断（JSVM 无 terminate API），该限制由 ArkTS 侧超时兜底（设计已知项）。
 */
#pragma once

#include "napi/native_api.h"
#include <cstdint>
#include <string>

namespace pluginhost {

struct RuntimeCommand {
    enum Type { Start, Load, Call, ResolveHttp, DeliverStream, WsEvent } type = Start;
    uint64_t callId = 0;
    std::string pluginId;
    std::string code;
    std::string configJson;  // Load: {"info":{...},"option":{...}}（info.json 元数据 + 用户配置）
    std::string modulesJson; // Load: 插件包内全部 .js 模块（路径 → 源码），供 CommonJS require
    std::string pluginDir;   // Load: 插件安装目录（$file 的只读区 /）
    std::string sandboxDir;  // Load: 插件可写沙箱目录（$file 的 $sandbox/）
    std::string bundleName;  // Load: 包名（native 侧虚拟路径→真实路径解析用）
    std::string fnName;
    std::string argsJson;
    int mode = 0; // 0=sync 1=promise 2=callback
    double timeoutMs = 5000.0;
    bool ok = false;
    std::string payload; // ResolveHttp: 应答 JSON（或错误 JSON）
};

// TSFN 回投条目：kind=0 调用结果；kind=1 HTTP 请求转交主线程；kind=2 插件日志；
// kind=3 插件流式输出；kind=4 WebSocket 操作转交主线程（payload=操作 JSON）
struct CallResult {
    uint64_t callId = 0;
    bool ok = false;
    std::string payload;
    int kind = 0;
};

// TSFN 回调主线程入口（实现在 pluginhost.cpp）：按 kind 分发——
// 0: 兑现 ArkTS deferred；1: 调用 ArkTS 注册的 HTTP handler
void RuntimeDispatchOnMain(napi_env env, const CallResult &cr);

// 进程级单例。Start 幂等；worker 与 VM 存活至进程结束。
class Runtime {
public:
    static Runtime &Instance();

    // 主线程调用：初始化 TSFN + worker + VM，完成后经 TSFN 兑现 startCallId 对应的 Promise。
    // 返回错误信息（空串 = 成功）。
    std::string Start(napi_env env, uint64_t startCallId);

    uint64_t NextCallId();

    // 主线程调用：投递命令，结果经 TSFN 兑现对应 callId 的 Promise。
    void PostLoad(uint64_t callId, const std::string &pluginId, const std::string &code,
                  const std::string &configJson, const std::string &modulesJson,
                  const std::string &pluginDir, const std::string &sandboxDir,
                  const std::string &bundleName);
    void PostCall(uint64_t callId, const std::string &pluginId, const std::string &fnName,
                  const std::string &argsJson, int mode, double timeoutMs);

    // worker 线程调用：经 TSFN 把结果回投主线程。
    void PostResult(uint64_t callId, bool ok, const std::string &payload);
    // worker 线程调用：HTTP 请求转交主线程（由 ArkTS 注册的 handler 执行）。
    void PostHttpRequest(uint64_t httpId, const std::string &requestJson);
    // worker 线程调用：插件 $log 输出转投主线程（payload 为 {"level","message"} JSON）。
    void PostLog(const std::string &level, const std::string &message);
    // worker 线程调用：插件 onStream 流式增量转投主线程（payload 为 {"text"} JSON）。
    void PostStreamText(const std::string &pluginId, const std::string &text);
    // worker 线程调用：WebSocket 操作转交主线程（payload=操作 JSON，含 __pid/__wsid）。
    void PostWsRequest(const std::string &requestJson);

    // 主线程调用：ArkTS 完成网络请求后回投应答，worker 兑现 nativeHttp 的 Promise。
    void PostResolveHttp(uint64_t httpId, bool ok, const std::string &responseJson);
    // 主线程调用：把流式 HTTP 增量送回沙盒（worker 调 __phStreamDeliver 回放 streamHandler）。
    void PostDeliverStream(const std::string &pluginId, const std::string &text);
    // 主线程调用：WebSocket 事件（open/message/close/error）送回沙盒回放监听。
    void PostWsEvent(const std::string &pluginId, uint64_t wsId, const std::string &type,
                     const std::string &dataJson);

private:
    Runtime() = default;
    ~Runtime() = default;
    Runtime(const Runtime &) = delete;
    Runtime &operator=(const Runtime &) = delete;

    void WorkerLoop();

    napi_env mainEnv_ = nullptr;
    napi_threadsafe_function tsfn_ = nullptr;
};

} // namespace pluginhost
