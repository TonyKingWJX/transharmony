# 鸿译 TransHarmony — 鸿蒙原生翻译应用

> 鸿蒙（HarmonyOS NEXT）上的 AI 翻译应用：基础翻译功能永久免费、多引擎可切换、支持接入 AI 大模型，把「翻译质量」和「好用程度」作为第一目标。
>
> 项目代号「鸿译」为占位名，正式名称待定（见「待决策清单」）。

**当前状态：v1.0.5，功能开发完成（含 Bob + manggo 插件系统、云端语音/识别服务），真机可跑，待上架准备（商店素材、AGC 配置）。** 详见「11. 工程现状」与「12. 版本历史」。

---

## 1. 项目背景与定位

**为什么做：**
- 鸿蒙 NEXT 已进入纯血鸿蒙阶段，原生应用生态仍在补齐，翻译类原生应用数量少、体验参差。
- 手机自带翻译偏「够用即可」，在译文质量、多引擎对比、AI 润色、细分场景（学术、跨境电商、开发者文档）上明显欠缺。
- 大模型翻译质量已显著超过传统机翻（尤其中译英的地道程度），但鸿蒙上缺少把大模型当翻译引擎用的顺手工具。

**产品定位一句话：**
给鸿蒙用户的「翻译瑞士军刀」——普通场景快、准、免费；高阶场景可切换 AI 大模型，做润色、解释、多版本对比。

**差异化策略：**
| 维度 | 系统自带翻译 | 传统翻译 App | 鸿译 |
|---|---|---|---|
| 基础文本翻译 | ✅ 免费 | 广告/会员墙 | ✅ 免费无广告 |
| 多引擎切换对比 | ❌ | 少数有 | ✅ 核心功能 |
| AI 大模型翻译 | 有限 | 个别有 | ✅ 核心功能，支持 BYOK（用户自带 API Key） |
| 译文润色/语法解释 | ❌ | ❌ | ✅ AI 模式专属 |
| 隐私 | 系统级 | 不透明 | 本地优先，BYOK 时数据不过自建服务器 |

---

## 2. 目标（SMART）

**产品目标：**
- 3.5 个月内（2026-12-31 前）完成 MVP 并上架华为应用市场。
- 翻译首字节响应 < 1.5s（传统引擎）/ < 5s（AI 流式输出）。
- 上架 3 个月内应用市场评分 ≥ 4.5，收集 100+ 条真实反馈并迭代 2 个版本。

**个人目标（假设为独立开发）：**
- 跑通「鸿蒙原生应用从 0 到上架」全流程，形成可复用的工程模板。
- 验证工具类应用在鸿蒙生态的商业可行性（会员订阅 + BYOK）。

**北极星指标：** 周翻译会话数（用户带着需求回来的频率，而非下载量）。

---

## 3. 需求分解（按优先级分期）

### P0 — MVP 必须有（上架门槛）
| # | 功能 | 说明 |
|---|---|---|
| 1 | 文本翻译 | 输入即译、自动检测源语言、70+ 语言对 |
| 2 | 多引擎切换 | 至少接入 2 家传统引擎（推荐百度 + 腾讯云），可一键切换对比 |
| 3 | 译文操作 | 一键复制、重新翻译、切换引擎后保留原文 |
| 4 | 历史记录 | 本地存储，按语言对/时间筛选，可清空、可删除单条 |
| 5 | 收藏/生词本 | 收藏常用句子，分类管理 |
| 6 | 设置页 | 默认语言对、默认引擎、深色模式跟随系统 |

### P1 — 竞争力功能（上架后第一个月）
| # | 功能 | 说明 |
|---|---|---|
| 7 | AI 翻译模式 | 接入大模型（DeepSeek/GLM/通义等），流式输出 |
| 8 | BYOK | 用户填自己的 API Key，不限量免费使用（极客人群差异化卖点） |
| 9 | 译文润色与解释 | 「更地道」「正式/口语化」「解释语法点」三种指令 |
| 10 | 双引擎对照 | 同屏对比传统引擎 vs AI 译文 |
| 11 | 语音翻译 | 语音识别 + 朗读译文（TTS） |
| 12 | 拍照翻译 | OCR 识别后整段翻译（依赖系统/HMS OCR 能力） |

### P2 — 想象空间（验证 PMF 后）
| # | 功能 | 说明 |
|---|---|---|
| 13 | 对话翻译 | 双向分屏，跨语言交流场景 |
| 14 | 元服务卡片 | 桌面卡片快速翻译，拉活跃 |
| 15 | 长文分段翻译 | 网页/文档级翻译，保持段落结构 |
| 16 | 离线翻译包 | 端侧小模型，成本高，视用户呼声决定 |
| 17 | 鸿蒙特性 | 折叠屏/平板适配、多端协同流转 |

**明确不做（防止范围蔓延）：**
- 全局取词、屏幕翻译——依赖系统级能力，鸿蒙沙箱内基本不可行，不做。
- 社区/UGC、账号体系——初期完全不需要，本地优先。

---

## 4. 商业模式与免费/付费边界

**原则：基础功能永久免费、无广告；靠 AI 增值付费，成本模型必须自洽。**

| 层级 | 内容 | 定价 |
|---|---|---|
| 免费层 | 传统引擎文本翻译、历史、收藏、基础语音朗读 | 免费，靠服务商免费额度覆盖（见调研文档） |
| BYOK 层 | 用户自带大模型 API Key，AI 翻译不限量 | 免费（0 服务器成本，双赢） |
| 会员层 | 内置 AI 翻译额度（免 Key 开箱即用）、OCR/语音高额度、领域翻译、润色不限量 | 订阅制，价格上架前定 |

**关键架构约束：** BYOK 模式下 App 直连第三方 API（无服务器、零成本）；内置 AI 模式需要自建代理服务器保护 Key（抓包可提取端侧硬编码 Key），意味着成本与备案。**初期策略：只做 BYOK，零服务器起步，验证需求后再上内置额度。**

---

## 5. 技术方案

### 5.1 技术栈
- **语言/UI：** ArkTS + ArkUI（声明式），MVVM
- **SDK：** HarmonyOS NEXT，API 12+（以 DevEco Studio 当前稳定版为准）
- **IDE：** DevEco Studio，模拟器 + 真机调试
- **关键 Kit：**
  - 网络：`@ohos.net.http`（封装重试、超时、流式 SSE）
  - 存储：`@ohos.data.relationalStore`（历史/收藏）、`@ohos.data.preferences`（设置）
  - 密钥：Asset Store Kit（关键资产加密存储 API Key）
  - 语音：Core Speech Kit（TTS），ASR 评估系统/HMS 能力或大模型多模态 API
  - OCR：HMS ML Kit 文字识别（P1 阶段调研）
  - 卡片：Form Kit（P2）

### 5.2 架构分层与核心抽象
```
UI 层（ArkUI @Component / @Builder）
  ↓ 状态管理（AppStorage / @ObservedV2）
领域层（TranslateUseCase、语言检测、限流风控）
  ↓
基础设施层
  ├─ 引擎插件（统一 TranslatorAdapter 接口，可插拔）
  ├─ 网络层（http 封装、SSE 流式解析）
  └─ 数据层（RelationalStore / Preferences / AssetStore）
```

**最重要的设计决策：引擎抽象。** 所有翻译服务（传统引擎 + 大模型）实现同一接口，新增引擎 = 新增一个 Adapter 文件，UI 不动：

```typescript
interface TranslationRequest {
  text: string;
  from: LangCode | 'auto';
  to: LangCode;
  style?: 'plain' | 'polished' | 'formal' | 'casual'; // AI 引擎专用
}

interface TranslationResult {
  text: string;
  providerId: string;
  detectedFrom?: LangCode;
  usage?: { promptTokens?: number; completionTokens?: number };
}

interface TranslatorAdapter {
  readonly id: string;            // 'baidu' | 'tencent' | 'deepseek' | 'glm' ...
  readonly label: ResourceStr;    // UI 显示名
  readonly isAI: boolean;
  readonly supportsStyle: boolean;
  translate(req: TranslationRequest): Promise<TranslationResult>;
  translateStream?(req: TranslationRequest): Promise<SSEStream>; // AI 流式
  supportedLangs(): LangCode[];
}
```

### 5.3 AI 接入方式
- **BYOK 直连：** 设置页填 Base URL + API Key + Model（兼容 OpenAI Chat Completions 格式，DeepSeek/GLM/通义/Kimi 全兼容），Key 存 Asset Store。
- **Prompt 设计：** 翻译指令 + 语言对 + 风格指令 + 「只输出译文」约束，长文分段并发。
- **流式输出：** 解析 SSE，边生成边渲染（体验关键）。

---

## 6. 排期规划

**假设：单人业余开发，每周投入 15~20 小时，全程 AI 辅助编码。全职可将周期压缩约一半。**

| 阶段 | 时间 | 里程碑 | 交付物 |
|---|---|---|---|
| 0 调研设计 | 9/7 – 9/20（2 周） | 方案定稿 | 原型图（已出 6 核心屏，见 [docs/ui-mockup.html](docs/ui-mockup.html)）、引擎选型结论、UI 规范 |
| 1 MVP | 9/21 – 10/18（4 周） | 可用的文本翻译 App | P0 全部：双引擎翻译、历史、收藏、设置 |
| 2 打磨内测 | 10/19 – 11/8（3 周） | 内测版 | P1 前半：AI 模式 + BYOK + 流式输出 |
| 3 首次上架 | 11/9 – 11/22（2 周） | **上架华为应用市场** | 隐私政策、商店素材、审核通过 |
| 4 竞争力迭代 | 11/23 – 12/20（4 周） | v1.1 | 语音翻译、拍照翻译、双引擎对照、润色指令 |
| 5 复盘 | 12/21 – 12/31（1.5 周） | 数据复盘 | 下载/留存/付费数据，决定是否做 P2 |

**里程碑风险缓冲：** 上架审核存在被拒可能，预留 2 次提审缓冲；MVP 若延期 1 周，砍「双引擎」为「单引擎」，保上架时间点。

---

## 7. 引擎选型（简版）

| 引擎 | 免费额度（个人开发者，编写时参考） | 接入难度 | 定位 |
|---|---|---|---|
| **微软 Bing 免费通道** | 无官方额度（按 IP 限流，单次 1000 字符） | 中（页面抓 token） | **默认引擎，开箱即翻**；实测双向可达（2026-09-05） |
| **有道免费通道** | 无官方额度（单次 1000 字符） | 低（无签名，POST 表单） | **已接入**，主页四大免费通道之一 |
| ~~阿里翻译免费通道~~ | — | — | **暂缓**：x5sec 滑块风控端侧无法稳定通过，适配器代码保留，待自建代理后恢复 |
| 腾讯云 TMT | 每月 500 万字符免费 | 中（TC3 签名） | 免费层主力，量大管饱（引擎面板可选） |
| **阿里云机器翻译（alimt）** | 通用版每月 100 万字符免费 | 中（RPC HMAC-SHA1 签名） | **已接入（2026-09-05）**，官方 API，AccessKey 型 BYOK |
| Azure Translator | F0 层每月 200 万字符 | 低（请求头认证） | 已接入，100+ 语言覆盖最广（引擎面板可选） |
| 百度翻译开放平台 | 标准版免费（QPS=1 严格） | 低（MD5 签名） | 备用引擎（引擎面板可选） |
| DeepSeek / GLM / 通义 / Kimi / 小米 MiMo / OpenAI | 无免费额度，按 token 计费 | 低（OpenAI 兼容格式） | BYOK 预置支持 |

详细调研（签名方式、语言覆盖、合规注意）见 [docs/translation-providers.md](docs/translation-providers.md)。
> ⚠️ 价格与免费额度随时变动，接入前以各官网最新政策为准。

---

## 8. 风险与应对

| 风险 | 等级 | 应对 |
|---|---|---|
| **系统自带翻译是最大竞品**（小艺/智慧识屏免费且系统级） | 🔴 高 | 不拼「能不能翻」，拼 AI 质量、多引擎对比、润色解释、细分场景 |
| 免费额度被脚本滥用刷爆 | 🔴 高 | 设备级限流、每日额度、风控埋点；BYOK 用户不占额度 |
| AI 编码时幻觉不存在的鸿蒙 API | 🟡 中 | 所有 `@ohos.*` / Kit 调用对照官方 API 文档逐个验证 |
| 应用市场审核（隐私、第三方数据传输声明） | 🟡 中 | 提前写隐私政策，明示译文上传第三方引擎；个人账号备齐材料 |
| 内置 AI 模式的服务器成本与备案 | 🟡 中 | 初期只做 BYOK 零服务器；验证需求后再上代理 |
| 单人项目烂尾 | 🟡 中 | MVP 范围从紧（6 个功能），先上架再迭代，不追求一步到位 |

---

## 9. 待决策清单（开工前需要定）

- [x] **应用名与品牌**：中文名已定「鸿译」，英文名保留 TransHarmony（2026-09-06）；包名 com.transharmony.app 不变；上架前仍需应用市场重名检测
- [ ] **开发者账号类型**：个人 vs 企业（影响审核类目与部分 API 权限）
- [ ] **首发引擎组合**：当前建议 腾讯云（主力）+ 百度（备用）
- [ ] **首发语言对范围**：建议 中英/中日/中韩 + 自动检测，不追求 70+ 全量
- [ ] **UI 风格**：已出 2 版风格稿，**采用第二版（官方规范版）**：[docs/ui-mockup.html](docs/ui-mockup.html)（对齐 huawei-docs/design-guides 色彩 Token、悬浮式胶囊页签 248×56vp、沉浸光感材质、半模态面板）；第一版风格稿备份于 [docs/ui-mockup-v0.1-directionA.html](docs/ui-mockup-v0.1-directionA.html)，后续可按此细化剩余页面

## 10. 如何开始（环境准备）

```bash
# 1. 安装 DevEco Studio（华为官方，内置 SDK 管理器）
#    https://developer.huawei.com/consumer/cn/deveco-studio/
# 2. 打开本仓库根目录（已是一个完整 hvigor 工程），File → Open 即可
# 3. 申请引擎账号：
#    - 腾讯云 TMT（机器翻译）：console.cloud.tencent.com
#    - 百度翻译开放平台：fanyi-api.baidu.com
#    - AI 引擎（可选其一）：DeepSeek / 智谱开放平台 / 阿里百炼 / Moonshot
```

**首次运行步骤：**
1. DevEco Studio 打开工程 → 等待 Sync 完成（会自动安装 oh_modules 依赖）
2. 在模拟器或真机上运行（compatibleSdkVersion 6.1.1(24)，兼容 HarmonyOS 6.1.1 及以上设备）
3. 进入「我的」Tab 填入引擎凭证（见上）→ 回「翻译」Tab 即可使用

### 10.1 工程目录结构

```
harmony-translator/
├── AppScope/                    # 应用级配置（bundleName、应用名「鸿译」、版本 1.0.5）
├── build-profile.json5          # 工程级构建配置（compatible/target 6.1.1(24)，编译用 DevEco 内置 SDK）
├── hvigor/hvigor-config.json5   # 构建工具版本（hvigor 6.26.4, modelVersion 26.0.0）
├── docs/
│   ├── translation-providers.md          # 引擎调研文档
│   ├── ui-mockup.html                    # UI 设计稿 v0.2（采用稿，对齐鸿蒙官方设计规范）
│   └── ui-mockup-v0.1-directionA.html    # UI 设计稿 v0.1（风格方向 A 备份）
└── entry/src/main/
    ├── module.json5             # 权限声明（仅 INTERNET + GET_NETWORK_INFO + MICROPHONE）
    └── ets/
        ├── entryability/        # EntryAbility（启动时初始化存储与凭证）
        ├── common/              # Ux：沉浸式避让、底部渐隐蒙版等通用 UI 工具
        ├── pages/               # Index(Navigation路由) + 翻译/历史/设置/服务/配置/图片翻译/关于等页面
        ├── components/          # LangSelector、EngineSelector（胶囊+拖拽排序）、AddProviderPanel、PasswordDialog（备份密码弹窗）
        ├── models/              # TranslationTypes：语言枚举、请求/响应类型
        ├── services/            # 核心业务层（引擎插件/编排 + SettingsStore + AssetVault(密钥资产) + BackupService + SensitiveFilter）
        └── utils/               # HttpClient / HashUtil(签名) / JsonUtil / AiModelApi(模型列表) / ImagePickerUtil / TransImageStore
```

**pages 一览**：`TranslatePage`（翻译主页）、`HistoryPage`（历史）、`HistoryDetailPage`（历史详情）、`SettingsPage`（我的）、
`ServicesPage`（翻译服务一级页：翻译/离线/TTS/OCR/插件入口）、`BuiltinServicesPage`（服务商管理：分组/开关/拖拽排序/添加面板）、
`CloudServicesPage`（语音服务TTS / 文字识别服务OCR 管理页，两页共用组件）、
`ServiceConfigPage`（服务商凭证配置+连通测试，路由参数区分翻译/TTS/OCR 列表）、`ImageTranslatePage`（图片翻译二级页）、
`AboutPage`（关于/隐私政策/用户反馈交流）。

### 10.2 核心设计：引擎插件化

所有翻译服务实现 `TranslatorAdapter` 接口（`services/TranslatorAdapter.ets`），
由 `EngineRegistry` 统一注册，`TranslateUseCase` 编排「取凭证 → 调引擎 → 存历史」：

```
UI (TranslatePage)
  → TranslateUseCase.translate(text, from, to, engineId)
      → settingsStore 读凭证 → 注入 adapter
      → adapter.translate(req)         # TencentAdapter / BaiduAdapter / OpenAICompatAdapter
      → historyStore.add(...)          # 写入历史
```

**新增引擎三步**：实现 `TranslatorAdapter` → 在 `EngineRegistry.init()` 注册 → UI（引擎胶囊、设置页）自动出现，零改动。

---

## 11. 工程现状（截至 2026-09-15，v1.0.5）

### 11.1 已实现 ✅

**插件系统（Bob 插件兼容，v1.0.1 新增）**
- ✅ **插件导入**：从文件管理器导入 .bobplugin（zip：info.json + main.js），info.json 按官方 schema 校验；本期支持翻译类，导入 OCR/TTS 插件时识别类型并提示后续开放
- ✅ **插件服务管理页**（我的 → 翻译服务 → 插件服务）：已装插件列表，行内开关（参与引擎行/聚合）、删除（二次确认，连带清理沙箱目录与 ASSET 密钥）、点击进插件配置页
- ✅ **插件即引擎**：自动出现在主页引擎行，支持拖拽排序、管理态停用、聚合并发、单引擎翻译、历史记录——全部复用现有引擎体系
- ✅ **插件配置页**：表单由 info.json 的 options 动态渲染（text 单行 / menu 下拉 / textConfig.secure 密码框 / 多行 / placeholder / defaultValue）；**显示名可编辑**（同步引擎行与插件列表）；secure 选项存 Asset Store Kit（与官方服务商同安全等级）；保存后下次翻译自动带新配置重载
- ✅ **测试连通**：优先调用插件自定义 pluginValidate(completion)，未实现自动回退标准试译
- ✅ **插件沙盒运行时**：JSVM 内嵌标准 JS 引擎（native 同步桥 + 消息泵），每插件独立 Env 全局隔离；异步超时回收、废弃调用隔离、重复初始化幂等
- ✅ **Bob API 全套按官方语义实现**：$http（request/get/post、handler+Promise 双形态、data 自动 JSON 解析、body 按 Content-Type 编码）、$log、$info、$option、$env、$timer、$signal、$data（全套字节编解码）、$file（/ 只读 + $sandbox 可写，9 函数）
- ✅ **CommonJS 多文件插件**：包内 require/exports/module + 宿主内置 crypto-js 模块（MD5/编码器）；浏览器/Node 习惯全局 polyfill（btoa/atob/console/setTimeout 家族/TextEncoder）
- ✅ **词典结果（toDict）**：查词类插件按词头/音标/词性释义拼可读文本
- ✅ **HTTP 桥**：插件网络经应用统一发起（复用应用 HTTP 客户端），任何 HTTP 响应回 envelope 由插件判断（Bob 语义），仅传输层失败 reject
- ✅ **真实验证**：彩云小译 / 有道 / DeepL / 火山 等 akl 系免费插件导入即用，聚合并发正常

**插件系统（manggo 插件兼容，v1.0.2 新增）**
- ✅ **.mplugin 导入**：manggo.plugin.json 清单校验（manifestVersion 1 / runtime manggo.plugin.v1），多服务插件（translation/ocr/speech；wordbook/action 暂不支持并明确提示）
- ✅ **多服务模型**：一包多服务逐服务建实例（id=plugin-<pid>#<sid>）；配置页统一服务列表（勾选启用 + 点行切换逐服务配置，config 表单 text/select/password/textarea/integer/decimal/boolean，password 存 Asset Store Kit）；翻译服务勾选制进引擎行
- ✅ **ESM 转换层**：export 剥离 / import 重写为沙盒 require（node:crypto 内置 md5/sha1/sha256，相对导入走既有 CommonJS）
- ✅ **fetch 完整语义**：Headers.get 大小写不敏感、body.getReader SSE 真流式（增量经桥回放）/非流式分块回放、text/json/arrayBuffer；node:crypto、fetch 挂全局
- ✅ **语言码**：内部 zh/en ↔ manggo zh_CN/en_US 双向映射 + 清单 language 映射（manggo 码→第三方码）；词典（resultType=dictionary）结果展开
- ✅ **生命周期加固**：ensureLoaded 并发去重；配置重载先销毁 Env 再全新加载（native unloadPlugin，Env 忙时拒绝销毁；修复 V8 "Cannot exit non-entered context" SIGTRAP 闪退）；启动时存量勾选归一化
- ✅ **引擎卡死看门狗**：非流式 60s 总上限 / 流式 30s 无增量判死；聚合逐引擎 60s；测试连通不永久转圈；转圈中切换引擎即刻作废旧轮次并用新引擎重翻
- ✅ **真实验证**：free-pack（5 翻译服务含有道词典流式/MD5 签名）与百炼（翻译+OCR，双服务独立配置）导入即用；Bob 插件全量回归通过

**云端语音/识别服务（v1.0.5 新增）**
- ✅ **语音服务TTS 管理页**（服务 → 语音服务TTS）：小米 MiMo / OpenAI 官方 / OpenAI 兼容 / Anthropic 兼容四类云端语音合成服务商，分组开关、删除（二次确认）、长按拖拽排序、添加面板；配置页含**预置音色 Select（即取即用）+ 自定义音色手填**（MiMo 9 官方音色、OpenAI 11 音色）、自动获取模型、连通测试（真实合成一句不播放）
- ✅ **文字识别服务OCR 管理页**（服务 → 文字识别服务OCR）：传统 OCR（腾讯 OCR / 百度 OCR）+ AI 视觉服务商（与翻译 AI 目录同套，程序化派生）；「自动获取模型」按**视觉模型过滤**（已知视觉系列名匹配，无命中回退全量）；连通测试用内置文字测试图（「鸿译OCR 123」JPEG）实测识别
- ✅ **云端 TTS 执行器**（TtsEngine）：OpenAI `/audio/speech` 二进制协议 + MiMo `chat/completions` 音频协议（官方文档形状：api-key 鉴权、音频 base64 随响应返回）；音频落沙箱临时文件 → AVPlayer 播放，暂停/继续/停止与系统 TTS 通道同接口；朗读三级分发（云端实例/插件/系统，偏好设置选择）
- ✅ **云端 OCR 执行器**（OcrEngine）：腾讯 GeneralBasicOCR（TC3 签名，同翻译适配器规格）+ 百度通用文字识别（access_token 内存缓存）+ AI 视觉多模态（OpenAI 图片消息 / Anthropic messages）；拍照翻译三级分发（云端实例/插件/系统端侧）
- ✅ **全局备份**：备份载荷覆盖翻译/TTS/OCR 三个服务列表（含密钥）+ TTS/OCR 服务选择与离线翻译偏好；已安装插件默认包含（可取消勾选）；恢复缺密钥的旧备份不误删本机密钥
- ✅ **持久化加固**：启动时密钥 ASSET 回填覆盖全部三个服务列表（修复重启/升级后 TTS·OCR 密钥读取丢失）；TTS 失败日志含密钥配置诊断（区分本机未配密钥与服务端 401）

**翻译引擎（12 个适配器：2 个免费通道开箱即翻 + 7 家 BYOK 传统 API + 2 类 AI 格式 / 9 个 AI 预置）**
- ✅ `EdgeTranslatorAdapter` — **微软 Bing 免费通道（默认引擎）**：页面抓 token（缓存 30 分钟自动刷新）；已修 HTTP/2 下 411 问题（强制 HTTP/1.1），真机验证可用
- ✅ `YoudaoAdapter` — **有道免费通道**，无签名开箱即翻，真机验证可用
- ✅ `TencentAdapter`（腾讯云 TMT，TC3 签名）/ `AliyunAdapter`（阿里云，HMAC-SHA1）/ `BaiduAdapter`（MD5）/ `AzureAdapter`（请求头认证）/ `YoudaoZhiyunAdapter`（智云签名）/ `CaiyunAdapter`（彩云）/ `NiutransAdapter`（小牛）
- ✅ `AlibabaAdapter` — 阿里网页通道**暂缓**（x5sec 风控端侧无法稳定通过，代码保留）；火山引擎适配器已移除（2026-09-10）
- ✅ AI：`OpenAICompatAdapter`（DeepSeek/GLM/通义/Kimi/小米 MiMo/OpenAI 官方预置 + 任意 OpenAI 兼容自定义）+ `AnthropicAdapter`（Anthropic 协议预置 + 兼容自定义）；支持自定义 API 地址、模型名（**自动获取模型列表，Select 下拉选择**）、自定义翻译 Prompt
- ✅ **连通测试**：配置页填好凭证一键试译验证，无需先保存

**核心功能**
- ✅ 文本翻译：自动检测源语言、智能语言对（中文→英/外文→中）、单引擎/聚合模式（并发所有引擎、逐个返回、耗时展示、一键采用）
- ✅ 译文操作：复制 / 重译 / **朗读（TTS，支持暂停/继续）**
- ✅ 服务商管理：免费通道 / 传统 / AI 三类独立分组，行内开关、删除（二次确认）、**组内长按拖拽排序**（顺序传导到聚合并发顺序与引擎 chips）；「添加服务商」面板（已组件化，翻译页与图片翻译页共用，**bindSheet 半模态**：页面级蒙层盖住底部页签，返回键/蒙层点击关闭不退出应用）
- ✅ 历史记录：RelationalStore 存储、@ObservedV2 + 数据版本号广播（三页签实时同步）、搜索、全部/收藏分段、语言对筛选 chips、星标、**回收站（软删除保留 30 天：恢复/彻底删除/一键清空，左滑操作）**、多选批量删除（长按进多选，悬浮胶囊操作条）、**详情页**（重译/朗读/收藏）、清空二次确认
- ✅ 语音输入：Core Speech Kit ASR（recognitionMode 0 引擎内部录音），**支持暂停/继续**（暂停即收尾出文本并自动翻译，继续开新会话接续识别），识别完成自动翻译；收音/暂停按钮三态高亮
- ✅ 图片翻译：拍照（cameraPicker，照片进沙箱**不进相册**）或相册选图 → **独立二级页**（上半屏图片预览可保存/重选/重拍，下半屏 bindSheet 三档拖拽半模态翻译面板）→ OCR 自动翻译（**三级分发：云端实例（腾讯/百度/AI 视觉）/插件/系统端侧**，偏好设置选择）→ 自动翻译；页面销毁照片即焚；拍照可选「保存到相册」（**SaveButton 安全控件**临时授权，不申请任何权限）
- ✅ 朗读 TTS：Core Speech Kit（中/英）+ **云端 TTS 服务商**（v1.0.5，其他语种按服务商能力）；**播放/暂停/继续**（系统 TTS 走 `playType:0` 官方 speakOnData 模式 + PCM 按 sequence 排序 + AudioRenderer 自播；云端 TTS 走沙箱临时文件 + AVPlayer）；语音服务三级分发（系统/云端实例/插件，偏好设置选择）；输入框朗读只读输入、译文朗读只读译文，互相独立
- ✅ AI 合规提示：AI 引擎译文卡与译文框下方展示「内容由AI生成，请仔细甄别」
- ✅ 应用内备份与恢复（**全局**）：全部历史（含回收站）+ 服务商配置（**翻译/TTS/OCR 三列表**，含密钥）+ 偏好设置 + **已安装插件（默认包含，文件/凭证/配置）**，**密码可选**（v2 格式 THBK2：有密码 PBKDF2 派生 AES-256-GCM 整包加密，无密码固定常量派生仅保完整性、弹窗醒目警示），落 Download/<包名>/ 免权限；无密码备份恢复免输密码、旧 THBK1 备份兼容；图片原图不再随备份携带（详情页回退 meta 缩略图）；恢复支持历史合并去重/覆盖、文件选择器拉起；恢复预览计数含语音/识别/插件
- ✅ 敏感词合规检测：DFA 字典树（rawfile 词库按类别分组），命中硬拦截类拒译——不发网络请求、不写历史、不回显命中词；归一化防简单绕过，词库懒加载不阻断主流程
- ✅ 交互状态：朗读/语音/拍照按钮均为独立 @Builder 三态高亮（修复 @Builder 值参数不刷新问题）；切语言/引擎自动停止朗读与识别；等待动画改原生 LoadingProgress 按钮

**UI / 体验**
- ✅ v0.2 设计稿落地：悬浮胶囊页签（248×56vp）、官方语义色 Token（base+dark 双资源）、沉浸光感
- ✅ 宽屏适配：≥600vp（平板/横屏/自由多窗）翻译页切**双列工作台**（输入卡左列、译文右列），内容限宽居中
- ✅ 深色模式全面适配（含开屏背景色 `start_window_background` 深色变体）
- ✅ 沉浸式：全屏布局 + 避让收口（Ux.ets）；底部渐隐蒙版按官方规范校准（页签顶 +16vp）；添加服务商面板蒙层正确覆盖状态栏（修复 expandSafeArea 因父 padding 失效问题）
- ✅ 应用图标：1024×1024 官方分层图标（背景层无透明像素合规）；开屏图标 512×512 圆角（官方蒙版比例）
- ✅ 「我的」页：隐私政策二级页（完整条款）、关于二级页（版本更新日志）、用户反馈交流页（QQ 群号可复制 + 群二维码）、拍照保存开关、**备份/恢复入口（上次备份时间 + 备份选项弹窗：密码可选 + 插件备份开关）**
- ✅ 服务商配置页含免责声明（费用与本应用无关）
- ✅ 权限最小化：INTERNET + GET_NETWORK_INFO + MICROPHONE（语音输入），无相册/存储权限（保存走安全控件）

### 11.2 已知限制与待办（按优先级）

- [x] ~~**凭证明文存 Preferences**~~ ✅ 已迁移 Asset Store Kit（2026-09-11）：密钥类字段（ConfigField.secret）落系统关键资产加密存储，services_list JSON 不再含明文；云备份恢复不携带凭证（系统 ASSET 限制），跨设备迁移走应用内加密备份 / 手机克隆
- [x] ~~**AI 引擎无流式输出**~~ ✅ 已实现：OpenAICompat / Anthropic / 插件 translateStream（SSE），逐字输出
- [x] ~~「插件翻译服务」入口已预留，暂未开放~~ ✅ 已上线（v1.0.1）：Bob 插件系统全量落地
- [x] ~~**插件：流式**~~ ✅ 已实现：$http.streamRequest/streamHandler（SSE 经桥逐块回放）+ query.onStream（Bob）/ options.setResult（manggo）；~~取消~~ cancelSignal 为占位（JSVM 无法中断在途调用，由轮次守卫 + 看门狗丢弃迟到结果替代）
- [x] ~~**插件：$websocket 桥接**~~ ✅ 已实现：WsBridge（@ohos.net.websocket，open/send/close + 事件命令队列回放）
- [x] ~~**插件：OCR 类支持**~~ ✅ 已完成：PluginOcrEngine（imageB64→$data.image、texts/regionInfos 解析、拍照翻译接入）；设置页可选 OCR 服务（仅启用的插件）
- [x] ~~**插件：TTS 类支持**~~ ✅ 已完成：PluginTtsPlayback（url 直连 / base64 临时文件 → AVPlayer 状态机驱动）；朗读按钮语言支持按当前服务判定（系统仅中英，插件按声明）
- [x] ~~**插件：语言选择器动态扩展**~~ ✅ 已完成（v1.0.2）：LangCatalog 扩展语言注册表（智能过滤：仅显示可解析出中文名的语言码，KNOWN_EXTRA 表 + 系统 ICU 兜底），Bob/manggo 声明的未收录语言（粤语/文言文等）动态进入选择器，插件卸载/停用后自动移除并自愈当前选择；内置语言新增**印尼语(id)**（AI 引擎 + 微软通道）与**德顿语(tet)**（仅 AI 引擎，主流 MT 厂商不支持）；聚合按 supportedLangs 过滤、单引擎预检提示，聚合空名单给出明确报错
- [x] ~~**插件：ESM 规范（Manggo）加载层**~~ ✅ 已完成（v1.0.2）：ESM 转换层（export 剥离 / import 重写为沙盒 require + node:crypto）+ .mplugin 多服务模型 + source=manggo 标识。约束已遵守：不触碰用户桌面安装的 Manggo 程序，测试样本由用户提供
- [ ] **插件：manggo wordbook（生词本）/ action（划词动作）服务**：宿主暂无生词本/划词助手承载功能，导入时明确提示不支持
- [ ] **插件：manggo 服务级 main 专用脚本 / 服务图标**：当前仅用 runtime.main 主脚本，列表用首字头像
- [ ] **插件：包内多文件 ESM 相对导入**：附加 .js 按 CommonJS 处理，若模块文件也是 ESM 会报错（主流插件均单文件自包含，暂无实际样本）
- [x] ~~**插件：同插件双翻译服务同时流式会互相串流**~~ ✅ 已修复（v1.0.2）：manggo 流式增量携带 __manggoSvc 服务标识，监听器按本服务 serviceId 过滤；监听器注册/清除改为按回调引用精确匹配
- [x] ~~**插件：fetch 二进制请求体**~~ ✅ 已实现（v1.0.2）：HttpClient 增 bodyB64（base64 解码为 ArrayBuffer 原样发送），插件图片/音频二进制上传可用
- [x] ~~**插件：info.json 多图标/isKeyOption**~~ ✅ 已完成（v1.0.2）：icon 支持字符串 / {universal:...} 对象格式；isKeyOption===true 选项按密钥类落 Asset Store Kit
- [ ] **插件：Bob appcast 自动更新** 未做
- [ ] **插件：插件市场 / 在线安装** 未做（当前均为本地文件导入）
- [ ] **插件：诊断日志降级**：实验室调试页（PluginLabPage）与内置 mock（rawfile mock.bobplugin / tools mock-manggo）上架前移除/隐藏
- [ ] 聚合模式未做「按质量排序」（需译文质量评估，P2 再议）
- [ ] **云端 TTS 已知限制**：Anthropic 官方无 TTS 接口（「Anthropic 兼容服务」项供中转/自建使用）；OpenAI/MiMo 均无音色列表 API，音色采用目录预置清单 + 手填；MiMo voicedesign/voiceclone 为音色设计/克隆特殊形态（音色字段不适用 voicedesign）
- [ ] 历史页语言对筛选仅中英/中日/中韩三组，其余走「全部」+ 搜索
- [ ] 单元测试未搭建（hypium 随后续配置）
- [ ] 上架材料：应用内隐私政策页 ✅ 已完成；商店截图/简介、AGC 应用信息配置待办
- [ ] 待决策：开发者账号类型（个人 vs 企业）

### 11.3 P1/P2 规划对照

| 规划项 | 状态 |
|---|---|
| P0 文本翻译 / 多引擎 / 译文操作 / 历史 / 收藏 / 设置 | ✅ 全部完成 |
| P1 AI 翻译 + BYOK | ✅ 完成（含流式输出） |
| P1 插件生态（Bob + manggo 兼容） | ✅ 完成（Bob 翻译/OCR/TTS；manggo 三类服务、多服务勾选制；稳定性加固） |
| P1 译文润色/解释 | ✅ 完成（AI 风格指令 chips） |
| P1 双引擎对照 | ✅ 完成（聚合模式） |
| P1 语音翻译 | ✅ 完成（v1.0.5 起支持云端 TTS 服务商：MiMo/OpenAI/兼容格式） |
| P1 拍照翻译 | ✅ 完成（独立二级页；v1.0.5 起支持云端 OCR 服务商：腾讯/百度/AI 视觉） |
| P1 插件系统（Bob .bobplugin 翻译类） | ✅ 完成（流式/取消/$websocket/OCR/TTS/ESM 见 11.2 待办） |
| P2 折叠屏/平板适配 | 🟡 部分（≥600vp 宽屏双列工作台已做；折叠屏展开态/多端协同未做） |
| P2 对话翻译 / 元服务卡片 / 长文分段 / 离线包 | ❌ 未开始（按规划待 PMF 验证后） |

## 12. 版本历史

### v1.0.5（2026-09-15，真机迭代中）
- **新增「语音服务TTS」**：服务页新增入口；支持小米 MiMo（官方 chat 音频协议，默认模型 mimo-v2.5-tts，预置音色 9 种）、OpenAI 官方、OpenAI 兼容、Anthropic 兼容；配置页音色改 Select（预置即选即用）+ 自定义手填，自动获取模型、连通测试（真实合成短句不播放）
- **新增「文字识别服务OCR」**：传统服务商腾讯 OCR（TC3 签名）/ 百度 OCR（token 缓存）+ AI 视觉服务商（与翻译 AI 目录同套，程序化派生）；「自动获取模型」按视觉模型过滤（无命中回退全量）；连通测试用内置文字测试图实测识别
- **云端执行器接入主流程**：朗读三级分发（云端实例/插件/系统，偏好设置选择，暂停/继续对齐）；拍照翻译三级分发（云端/插件/系统端侧）
- **服务管理页**：TTS/OCR 两页共用组件（分组展示、行内开关、删除二次确认、长按拖拽排序、添加面板），翻译服务列表与存储完全隔离、对翻译链路零侵入
- **备份全局化**：载荷覆盖翻译/TTS/OCR 三列表（含密钥）+ TTS/OCR 服务选择与离线翻译偏好；已安装插件默认包含（可取消）；恢复预览计数含语音/识别数量
- **持久化加固**：启动时密钥 ASSET 回填覆盖全部三个服务列表（修复重启/升级后 TTS·OCR 密钥读取丢失）；恢复缺密钥的旧备份不再误删本机密钥（区分「清空密钥」与「字段缺失」）；TTS 失败日志含密钥配置诊断
- **插件列表改名即时生效**：ForEach 键补显示名与启用态，改名/开关后返回列表立即刷新

### v1.0.4（2026-09-15，真机迭代中）
- **新增 AI 服务商**：小米 MiMo（官方 OpenAI 兼容端点，默认模型 mimo-v2.5-pro）与 OpenAI 官方，均插入 Kimi 之后，走现有 OpenAI 兼容适配器零新增代码；配置页支持自动获取模型列表切换
- **兼容服务配置页去官方引导**：「OpenAI 兼容服务」「Anthropic 兼容服务」不再显示官方 Key 获取链接，改为引导向服务提供方获取 Key 或直接添加对应官方预置
- 隐私政策第三方服务商清单补充小米 MiMo、OpenAI

### v1.0.3（2026-09-14，真机迭代中）
- **备份/恢复增强**：备份密码改为可选（无密码备份不加密仅保完整性，弹窗醒目警示；恢复端免输密码）；新增可选「包含已安装插件」（插件文件+配置+凭证随备份携带，恢复免重新导入，先于服务恢复自动点亮引擎行）；备份格式升级 THBK2（flags 标记密码位，旧 THBK1 备份完全兼容）；图片原图不再随备份携带（跨设备恢复详情页回退 meta 内嵌缩略图）
- **内置新增印尼语/德顿语**：语言表扩展至 12 种；引擎分级声明支持（AI 引擎全支持，微软通道支持印尼语，其余云引擎维持核心 10 语言待逐家验证）；选择器动态扩展落地（插件声明语言可达）

### v1.0.2（2026-09-13，真机迭代中）
- **新增 manggo 插件兼容**：.mplugin 导入即用，翻译 / OCR / TTS 三类服务全覆盖；多服务插件（一包多服务/翻译+OCR 混合）配置页统一勾选启用、逐服务独立配置
- **manggo 插件沙盒**：ES Module 转换层（import 重写 + node:crypto md5/sha1/sha256 内置）、fetch 完整语义（SSE 真流式 getReader、Headers.get）、语言码双向映射、词典结果展开
- **插件生命周期加固**：加载并发去重；配置重载先销毁 Env 再全新加载（修复 V8 "Cannot exit non-entered context" SIGTRAP 闪退）
- **引擎卡死看门狗**：非流式 60s 总上限、流式 30s 无增量判死；聚合逐引擎 60s；测试连通不永久转圈；转圈中切换引擎即刻作废旧轮次并用新引擎重翻
- **多服务插件引擎行勾选制**：默认不铺满主页引擎行，勾选才显示并参与聚合并发
- **界面修复**：输入框光标顶部被圆角裁剪区截断（官方说明：显式 borderRadius(0)）

### v1.0.1（2026-09-12，真机迭代中）
- **新增 Bob 插件系统**：文件管理器导入 .bobplugin 翻译插件，即装即用；插件即引擎（主页引擎行、拖拽排序、开关、删除、聚合并发、历史记录全支持）
- **插件服务管理页**：我的 → 翻译服务 → 插件服务，已装插件统一管理；点击进插件配置页
- **插件配置页**：表单由 info.json options 动态渲染（文本/下拉/密码框/多行/placeholder/默认值）；显示名可编辑并同步引擎行；secure 选项存 Asset Store Kit；测试连通优先插件自定义 pluginValidate、回退标准试译
- **插件沙盒运行时**：JSVM 内嵌标准 JS 引擎，每插件独立 Env 全局隔离；CommonJS 多文件 require（内置 crypto-js）；$http/$log/$info/$option/$env/$timer/$signal/$data/$file 全套 API 按官方语义实现
- **词典结果（toDict）**：查词类插件输出词头/音标/词性释义
- **插件网络经应用统一发起**：复用应用 HTTP 客户端（含超时），HTTP 响应完整回传插件判断（Bob 语义）
- 真机适配与修复：冷启动引擎列表竞态（ready 门 + 广播）、插件加载/调用超时兜底、错误原因透传、原生 LoadingProgress 等待动画
- 真实验证：彩云小译/有道/DeepL/火山等免费插件导入即用，聚合并发正常

### v1.0.0（2026-09-11，真机迭代中）
- **凭证加密存储**：服务商密钥类字段迁移 Asset Store Kit（AES256-GCM + 可信执行环境），Preferences 中不再落明文；应用内备份/恢复接口不变，手机克隆可携带凭证
- **应用内备份与恢复**：历史+服务商+偏好整包 AES-256-GCM 加密（.htrans），密码弹窗设置/输入，恢复支持合并去重/覆盖；图片翻译原图可选携带
- **敏感词合规检测**：DFA 字典树，命中硬拦截类拒译（不发网络请求、不写历史、不回显命中词）
- **平板/折叠屏适配**：官方四级断点（sm/md/lg/xl），翻译页 md/lg 双列工作台（等高对齐、内容区分级限宽）、历史/详情页限宽分级、半模态大屏自动居中跟手弹窗（SheetType.POPUP）
- 历史记录新增**回收站**：删除走软删除保留 30 天，支持恢复 / 彻底删除 / 一键清空；回收站左滑操作
- 历史记录新增**详情页**：点击记录进二级页（重译/朗读/收藏）；多选批量删除（长按进多选）
- 「添加服务商」面板改 **bindSheet 半模态**：页面级蒙层盖住底部页签，返回键/蒙层点击关闭不退出应用；`$$` 双向绑定修复关闭后再次弹出无响应
- 真机修复：页签切换整页转场动画在真机上抽搐/角落飞入（去掉整页转场，官方页签即切）；多选批量删除无响应（V2 `@Local` 代理数组直接传 RDB `in()` 抛异常，store 层 `slice()` 剥离 + 失败 toast）；多选悬浮操作条改 FAB 模式（列表底部留滚动余量，最后一张卡不再被遮挡）；列表边缘渐隐与底部留白平衡（卡片滚动进出边缘柔和渐隐、静止完整显示）
- 服务商体系重构：免费通道/传统/AI 三类独立分组管理，行内开关、删除、组内拖拽排序；「添加服务商」面板组件化
- 图片翻译升级为独立二级页：拍照/相册取图 → 上半屏预览（保存/重选/重拍）+ 下半屏三档拖拽半模态翻译面板，页面销毁照片即焚
- 历史记录页重构：@ObservedV2 + 数据版本号广播，三页签实时同步；存储 schema 增强
- 宽屏适配：≥600vp 平板/横屏切双列工作台
- AI 合规提示（「内容由AI生成」）、模型选择改 Select 下拉、设置页卡片布局优化
- 关于页完善：完整隐私政策二级页、用户反馈交流页（QQ 群号 + 群二维码）
- 移除火山引擎适配器；HTTP 客户端与配置页优化；签名配置更新

### v0.2.0（2026-09-09，真机迭代中）
- 新增 AI 翻译服务商：OpenAI 兼容（DeepSeek/GLM/通义/Kimi）+ Anthropic 协议，自动获取模型列表，自定义翻译 Prompt
- 新增拍照翻译（端侧 OCR）与语音输入（ASR），照片默认不进相册，可选 SaveButton 安全控件保存
- 新增译文/输入朗读（TTS 暂停/继续）、语言不支持置灰提示
- 新增连通测试、配置页免责声明、隐私说明与关于页（含更新日志）
- 修复：微软通道 411（强制 HTTP/1.1）、ASR 会话残留、相机沙箱文件读取、面板状态栏沉浸、内置服务页面板布局、@Builder 状态刷新等十余项真机问题
- 图标：官方规范分层图标 + 圆角开屏图标 + 开屏深色背景

### v0.1.0（2026-09-04）
- 首版：聚合并发多引擎翻译、内置免费通道开箱即翻、BYOK 服务商管理、历史记录、悬浮胶囊页签、深浅色主题

---

*最后更新：2026-09-15 · 项目状态：v1.0.5 功能开发完成，真机验证通过，待上架准备（商店素材、AGC 配置）*
