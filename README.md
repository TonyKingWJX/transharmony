# 鸿译 TransHarmony

> HarmonyOS NEXT 原生 AI 翻译应用：免费通道开箱即翻、12 个翻译服务商可切换、多引擎聚合对比、BYOK 接入大模型、兼容 Bob 插件。

当前版本 **v1.0.1**，真机验证通过，持续迭代中。版本历史见 [docs/CHANGELOG.md](docs/CHANGELOG.md)。

## ✨ 功能特性

- **开箱即翻**：内置微软 Bing、有道两个免费通道，无需注册即可翻译
- **多引擎聚合**：同时并发多个引擎，逐个返回、耗时展示、一键采用
- **12 个服务商适配**：免费通道 2 个 + 传统 API 7 家（腾讯云 / 阿里云 / 百度 / Azure / 有道智云 / 彩云 / 小牛）+ AI 引擎
- **AI 翻译（BYOK）**：DeepSeek / GLM / 通义 / Kimi / Anthropic 预置，支持任意 OpenAI 兼容接口，自动获取模型列表，可自定义翻译 Prompt；译文润色、语法解释、多风格输出
- **语音输入与朗读**：Core Speech Kit ASR（支持暂停 / 继续）+ TTS 朗读
- **拍照翻译**：拍照 / 相册取图 → 端侧 OCR（Core Vision Kit）→ 自动翻译，照片即用即焚
- **Bob 插件系统**：兼容 .bobplugin 插件（JSVM 沙盒运行时），插件即引擎，支持翻译 / OCR / TTS 类插件
- **历史与收藏**：本地存储、搜索、语言对筛选、回收站（30 天软删除）、详情页、批量操作
- **备份恢复**：历史 + 服务商配置 + 偏好整包 AES-256-GCM 加密（.htrans），免存储权限
- **隐私与合规**：凭证存系统关键资产（Asset Store Kit）、敏感词 DFA 检测、AI 内容合规提示、权限最小化（仅 INTERNET / GET_NETWORK_INFO / MICROPHONE）
- **体验**：深色模式、平板 / 宽屏双列工作台、对齐鸿蒙官方设计规范（悬浮胶囊页签、语义色 Token）

## 界面预览

> TODO：补充运行截图（可放 docs/screenshots/）。

## 引擎支持

| 引擎 | 类型 | 说明 |
|---|---|---|
| 微软 Bing 免费通道 | 免费 | **默认引擎**，无需配置 |
| 有道免费通道 | 免费 | 无需配置 |
| 腾讯云 TMT、阿里云 alimt、百度翻译、Azure Translator、有道智云、彩云、小牛翻译 | 传统 BYOK | 用户自备凭证 |
| DeepSeek / GLM / 通义 / Kimi 及任意 OpenAI 兼容接口 | AI BYOK | 预置 + 自定义 |
| Anthropic 协议 | AI BYOK | Claude 系列 |
| 阿里网页通道 | 免费 | 暂缓（风控不稳定，代码保留） |

> ⚠️ 各引擎价格与免费额度随时变动，以官方最新政策为准；签名方式、语言覆盖、合规注意等调研细节见 [docs/translation-providers.md](docs/translation-providers.md)。

## 快速开始

### 环境要求

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) 6.x（内置 HarmonyOS SDK）
- 编译目标：HarmonyOS 6.1.1（API 24），兼容 6.1.1 及以上设备

### 构建运行

1. `git clone` 本仓库后用 DevEco Studio 打开根目录，等待 Sync 自动安装 oh_modules 依赖
2. 配置签名（见下节）
3. 连接真机或启动模拟器，Run 即可

### 签名配置

仓库中的 `build-profile.json5` 不含签名信息。真机运行需要签名，二选一：

- **推荐**：DevEco Studio → File → Project Structure → Signing Configs → 勾选 *Automatically generate signature*，登录华为开发者账号后自动生成调试证书（DevEco 会把签名信息写入本地 `build-profile.json5`，该改动请勿提交）
- **手动**：自备 .p12 / .cer / .p7b 证书，在 `signingConfigs` 中配置 `storeFile` / `storePassword` / `keyAlias` / `profile` / `certpath`

> ⚠️ 请勿将证书文件或密钥密码提交到公开仓库。

### 配置翻译引擎

- 微软 Bing、有道两个免费通道默认启用，装完即翻
- 其他引擎：应用内 **我的 → 翻译服务 → 添加服务商**，填入你在对应平台申请的凭证（BYOK，仅存本机，可先「测试连通」验证）
- AI 引擎：选择预置模型或任意 OpenAI 兼容地址，填 Base URL + API Key + 模型名

## 工程结构

```
transharmony/
├── AppScope/                    # 应用级配置（bundleName、应用名、版本）
├── build-profile.json5          # 工程级构建配置（签名配置不入库）
├── hvigor/hvigor-config.json5   # hvigor 构建工具版本
├── tools/
│   ├── mock-bob-plugin/         # 插件系统调试用 mock 翻译插件
│   └── mock-ocr-plugin/         # 插件系统调试用 mock OCR 插件
├── docs/
│   ├── translation-providers.md          # 翻译引擎调研（签名方式 / 语言覆盖 / 合规）
│   ├── PROJECT_PLAN.md                   # 项目内部规划与开发记录
│   ├── CHANGELOG.md                      # 版本历史
│   ├── ui-mockup.html                    # UI 设计稿 v0.2（采用稿）
│   └── ui-mockup-v0.1-directionA.html    # UI 设计稿 v0.1（备份）
└── entry/src/main/
    ├── module.json5             # 权限声明（仅 INTERNET + GET_NETWORK_INFO + MICROPHONE）
    ├── cpp/                     # 插件宿主 native 模块（JSVM 沙盒运行时）
    └── ets/
        ├── entryability/        # EntryAbility（启动时初始化存储与凭证）
        ├── common/              # 通用 UI 工具（沉浸式避让等）
        ├── pages/               # 翻译 / 历史 / 设置 / 服务商 / 图片翻译 / 插件实验室 / 关于等页面
        ├── components/          # LangSelector、EngineSelector、AddProviderPanel 等
        ├── models/              # 语言枚举、请求 / 响应类型
        ├── services/            # 引擎适配器、插件系统、备份、敏感词过滤等核心业务
        └── utils/               # HttpClient / HashUtil(签名) / JsonUtil 等工具
```

## 架构：引擎插件化

所有翻译服务（传统引擎、AI 模型、Bob 插件）实现统一的 `TranslatorAdapter` 接口，由 `EngineRegistry` 统一注册、`TranslateUseCase` 编排「取凭证 → 调引擎 → 存历史」，新增引擎 UI 零改动：

```typescript
interface TranslatorAdapter {
  readonly id: string;            // 'baidu' | 'azure' | 'openai-compat' | ...
  readonly label: ResourceStr;    // UI 显示名
  readonly isAI: boolean;
  translate(req: TranslationRequest): Promise<TranslationResult>;
  supportedLangs(): LangCode[];
}
```

**新增引擎三步**：实现 `TranslatorAdapter` → 在 `EngineRegistry.init()` 注册 → 引擎胶囊与设置页自动出现。

插件系统：JSVM 沙盒运行时（每插件独立全局隔离）、Bob API 兼容（$http / $data / $file 等按官方语义实现）、CommonJS 多文件 require、插件网络统一经应用 HTTP 客户端桥接。详见 [docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md)。

## 开发

- 路线图、已知限制与待办：[docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md)
- 欢迎提交 Issue 与 PR

## 免责声明

- 本应用不内置任何服务商密钥；除两个免费通道外，所有引擎均需用户自行注册并配置凭证（BYOK），相关费用与本应用无关
- 微软 Bing、有道「免费通道」为非官方公开接口，仅供学习研究使用，不保证稳定性，请自行遵守相关服务条款
- AI 生成内容请注意甄别；译文质量因引擎而异

## License

[Apache-2.0](LICENSE) © 2026 TonyKingWJX
