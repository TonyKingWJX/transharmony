/**
 * 服务商目录：所有可添加的翻译服务商的静态定义。
 * 「内置翻译服务」页的添加面板、配置页的字段渲染、凭证存储的键名，
 * 全部由这里驱动；新增服务商 = 在此加一项 + 一个 Adapter。
 *
 * 字段说明（ConfigField）：
 * - key：凭证存储键（ServicesStore.config.<字段key>）
 * - link/linkText：配置页小字中的超链接（点击拉起浏览器直达控制台）
 *   linkText 为空表示该字段不带链接。
 */

/** 配置字段定义 */
export interface ConfigField {
  key: string;
  label: string;
  placeholder: string;
  /** 是否密码框 */
  secret: boolean;
  /** 是否可留空 */
  optional: boolean;
  /** 小字说明（带超链接的引导文案） */
  hint: string;
  /** 超链接地址（空串 = 无链接） */
  link: string;
  /** 超链接文字 */
  linkText: string;
}

/** 服务商类别 */
export type ProviderKind = 'builtin-free' | 'trad' | 'ai' | 'ocr-trad' | 'ocr-ai' | 'tts-ai';

/** 服务商静态定义 */
export interface ProviderDef {
  /** 引擎 id（与 Adapter.id 一致；官方预置 = Adapter id，自定义实例 = 'svc-xxx'） */
  id: string;
  /** 显示名 */
  label: string;
  /** 徽标底色 */
  color: string;
  /** 徽标字 */
  badge: string;
  kind: ProviderKind;
  /** 是否 AI 引擎（决定走 OpenAI/Anthropic 协议） */
  isAI: boolean;
  /** AI 协议格式：'openai' | 'anthropic'（传统引擎为空） */
  aiFormat: string;
  /** 默认 API 地址（空 = 需要用户自己填） */
  baseUrl: string;
  /** 默认模型名（AI 引擎用） */
  defaultModel: string;
  /** 列表行副标题（配额/特点一句话） */
  subtitle: string;
  /** 配置页说明文字 */
  note: string;
  /** 凭证字段 */
  fields: ConfigField[];
  /** 是否允许用户改 API 地址（OpenAI/Anthropic 兼容与部分服务商允许） */
  allowBaseUrl: boolean;
  /** 是否允许用户改模型名（AI 引擎允许） */
  allowModel: boolean;
  /** TTS 服务声明的支持语言（内部码，如 'zh'/'en'）；空/未声明 = 放行全部语种 */
  ttsLangs?: string[];
  /** TTS 默认音色（实例未填 voice 时使用；未声明 = 服务端默认） */
  defaultVoice?: string;
  /** TTS 合成 API 形状：'speech'（默认，OpenAI /audio/speech 二进制）| 'mimo'（chat/completions，base64 音频在响应 JSON 内） */
  ttsApi?: string;
  /** TTS 预置音色清单（配置页音色 Select 选项；未声明 = 该服务未公开音色列表，手填） */
  ttsVoices?: string[];
}

/** 内置免费通道（不可配置、不可删除） */
export const FREE_PROVIDERS: ProviderDef[] = [
  {
    id: 'edge',
    label: '微软翻译',
    color: '#0C59A4',
    badge: '微',
    kind: 'builtin-free',
    isAI: false,
    aiFormat: '',
    baseUrl: '',
    defaultModel: '',
    subtitle: '免费 · 无需配置 · 开箱即翻',
    note: 'Bing 网页免费通道，默认引擎。单次最多 1000 字符，接口为非公开契约，可能随网页改版波动。',
    fields: [],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'youdao',
    label: '有道翻译',
    color: '#D43C33',
    badge: '有',
    kind: 'builtin-free',
    isAI: false,
    aiFormat: '',
    baseUrl: '',
    defaultModel: '',
    subtitle: '免费 · 无需配置 · 单次 1000 字符',
    note: '有道 AI 演示页免费通道。单次最多 1000 字符，接口为非公开契约，可能变化。',
    fields: [],
    allowBaseUrl: false,
    allowModel: false
  }
];

/**
 * 离线翻译（端侧内置模型，中英双向）。
 * 刻意不进 FREE_PROVIDERS：它不在「服务商管理页」的免费通道分组里出现，
 * 有独立管理页（OfflineTranslatePage），只在「添加服务商」面板与引擎行中出现。
 */
export const OFFLINE_PROVIDER: ProviderDef = {
  id: 'offline',
  label: '离线翻译',
  color: '#0BB36B',
  badge: '离',
  kind: 'builtin-free',
  isAI: false,
  aiFormat: '',
  baseUrl: '',
  defaultModel: '',
  subtitle: '端侧模型 · 中英双向 · 无需联网',
  note: '内置端侧神经翻译模型（OPUS-MT），翻译完全在本机完成，内容不出设备。仅支持中英互译。',
  fields: [],
  allowBaseUrl: false,
  allowModel: false
};

/** 传统机器翻译服务商（用户可添加，官方 API + BYOK） */
export const TRAD_PROVIDERS: ProviderDef[] = [
  {
    id: 'tencent',
    label: '腾讯翻译',
    color: '#0A9BFF',
    badge: '讯',
    kind: 'trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://tmt.tencentcloudapi.com',
    defaultModel: '',
    subtitle: '每月 500 万字符免费',
    note: '腾讯云机器翻译 TMT（TextTranslate 接口），每月 500 万字符免费额度，超出部分按量计费。凭证为腾讯云账号的访问密钥，请勿外泄。',
    fields: [
      {
        key: 'secretId', label: 'SecretId', placeholder: 'AKID…', secret: false, optional: false,
        hint: '在腾讯云控制台「访问管理 → API 密钥管理」创建并复制 SecretId。',
        link: 'https://console.cloud.tencent.com/cam/capi', linkText: '前往腾讯云密钥管理'
      },
      {
        key: 'secretKey', label: 'SecretKey', placeholder: '密钥', secret: true, optional: false,
        hint: '与 SecretId 配套的密钥，同一页面创建后复制。',
        link: 'https://console.cloud.tencent.com/cam/capi', linkText: '前往腾讯云密钥管理'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'aliyun',
    label: '阿里云翻译',
    color: '#FF7300',
    badge: '云',
    kind: 'trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://mt.aliyuncs.com',
    defaultModel: '',
    subtitle: '通用版每月 100 万字符免费',
    note: '阿里云机器翻译 alimt（TranslateGeneral 通用版），每月 100 万字符免费，超出自动停用。需先开通机器翻译服务，再创建 AccessKey（建议使用子账号并仅授予翻译权限）。',
    fields: [
      {
        key: 'accessKeyId', label: 'AccessKey ID', placeholder: 'AccessKey ID', secret: false, optional: false,
        hint: '在阿里云 RAM 控制台创建 AccessKey（建议子账号 + alimt 权限）。',
        link: 'https://ram.console.aliyun.com/manage/ak', linkText: '前往阿里云 AccessKey 管理'
      },
      {
        key: 'accessKeySecret', label: 'AccessKey Secret', placeholder: 'AccessKey Secret', secret: true, optional: false,
        hint: '与 AccessKey ID 配套的密钥，创建时只显示一次，请妥善保存。',
        link: 'https://ram.console.aliyun.com/manage/ak', linkText: '前往阿里云 AccessKey 管理'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'baidu',
    label: '百度翻译',
    color: '#2932E1',
    badge: '百',
    kind: 'trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://fanyi-api.baidu.com/api/trans/vip/translate',
    defaultModel: '',
    subtitle: '标准版免费 · QPS 限制 1',
    note: '百度翻译开放平台通用翻译 API。标准版免费但每秒限 1 次请求，仅适合轻量使用；高级版需认证开发者。凭证为创建应用后获得的 AppID 和密钥。',
    fields: [
      {
        key: 'appId', label: 'AppID', placeholder: 'AppID', secret: false, optional: false,
        hint: '在百度翻译开放平台控制台「我的应用」中查看。',
        link: 'https://fanyi-api.baidu.com/console/declaration', linkText: '前往百度翻译开放平台'
      },
      {
        key: 'secret', label: '密钥', placeholder: '密钥', secret: true, optional: false,
        hint: '与 AppID 同页显示，创建应用时生成。',
        link: 'https://fanyi-api.baidu.com/console/declaration', linkText: '前往百度翻译开放平台'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'youdao-zhiyun',
    label: '有道翻译',
    color: '#D43C33',
    badge: '道',
    kind: 'trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://openapi.youdao.com/api',
    defaultModel: '',
    subtitle: '新用户赠送 50 元体验金',
    note: '有道智云文本翻译 API（openapi.youdao.com）。注册后在「自然语言翻译」服务下创建应用，获得应用 ID 和应用密钥；新用户赠送体验金，按字符计费。',
    fields: [
      {
        key: 'appKey', label: '应用 ID（appKey）', placeholder: '应用 ID', secret: false, optional: false,
        hint: '在有道智云控制台「应用管理」中查看。',
        link: 'https://ai.youdao.com/appmgr.s', linkText: '前往有道智云应用管理'
      },
      {
        key: 'appSecret', label: '应用密钥（appSecret）', placeholder: '应用密钥', secret: true, optional: false,
        hint: '创建应用时生成的密钥，与应用 ID 配套使用。',
        link: 'https://ai.youdao.com/appmgr.s', linkText: '前往有道智云应用管理'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'caiyun',
    label: '彩云小译',
    color: '#2BB749',
    badge: '彩',
    kind: 'trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://api.interpreter.caiyunai.com/v1/translator',
    defaultModel: '',
    subtitle: '每月 100 万字符免费',
    note: '彩云科技小译 API。注册彩云小译开放平台后获取 API 令牌（Token），通用翻译每月 100 万字符免费额度。',
    fields: [
      {
        key: 'token', label: '令牌（Token）', placeholder: '令牌', secret: true, optional: false,
        hint: '在彩云小译开放平台控制台「我的令牌」中获取。',
        link: 'https://open.caiyunai.com/user/dashboard', linkText: '前往彩云小译开放平台'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'niutrans',
    label: '小牛翻译',
    color: '#E84026',
    badge: '牛',
    kind: 'trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://api.niutrans.com/NiuTransServer/translation',
    defaultModel: '',
    subtitle: '注册赠送 100 万字符',
    note: '小牛翻译开放平台文本翻译 API（NiuTransServer）。注册后获取 API Key，新用户赠送免费字符额度；支持 300+ 语种。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'API Key', secret: true, optional: false,
        hint: '在小牛翻译开放平台控制台「API Key 管理」中获取。',
        link: 'https://niutrans.com/console', linkText: '前往小牛翻译开放平台'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'azure',
    label: 'Azure 翻译',
    color: '#0078D4',
    badge: 'A',
    kind: 'trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://api.cognitive.microsofttranslator.com',
    defaultModel: '',
    subtitle: 'F0 免费层每月 200 万字符',
    note: '微软 Azure AI 翻译（Translator v3）。F0 免费层每月 200 万字符，超额自动停用不扣费。需在 Azure 门户创建「翻译器」资源，复制密钥；全球资源的区域可留空。',
    fields: [
      {
        key: 'apiKey', label: '订阅密钥（Key 1）', placeholder: '密钥', secret: true, optional: false,
        hint: '在 Azure 门户翻译器资源的「密钥和终结点」页复制。',
        link: 'https://portal.azure.com/', linkText: '前往 Azure 门户'
      },
      {
        key: 'region', label: '区域（Region）', placeholder: '如 southeastasia（全球资源留空）', secret: false, optional: true,
        hint: '区域资源的终结点页标明的区域名；使用全球站终结点时留空。',
        link: 'https://portal.azure.com/', linkText: '前往 Azure 门户'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  }
];

/** AI 翻译服务商（预置主流官方 + 兼容格式） */
export const AI_PROVIDERS: ProviderDef[] = [
  {
    id: 'ai-deepseek',
    label: 'DeepSeek',
    color: '#4D6BFE',
    badge: 'D',
    kind: 'ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://api.deepseek.com',
    defaultModel: 'deepseek-chat',
    subtitle: '官方 API · OpenAI 兼容',
    note: 'DeepSeek 官方 API，天然兼容 OpenAI Chat Completions 协议。在开放平台创建 API Key，按 token 计费。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在 DeepSeek 开放平台「API Keys」页创建。',
        link: 'https://platform.deepseek.com/api_keys', linkText: '前往 DeepSeek 开放平台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-glm',
    label: '智谱 GLM',
    color: '#3859FF',
    badge: '智',
    kind: 'ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4-flash',
    subtitle: '官方 API · OpenAI 兼容',
    note: '智谱 GLM 官方 API（bigmodel.cn），OpenAI 兼容模式。glm-4-flash 模型免费；在开放平台「API 密钥」页创建 Key。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在智谱开放平台「API 密钥」页创建。',
        link: 'https://open.bigmodel.cn/usercenter/apikeys', linkText: '前往智谱开放平台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-qwen',
    label: '通义千问',
    color: '#615CED',
    badge: '通',
    kind: 'ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    subtitle: '官方 API · OpenAI 兼容',
    note: '阿里云百炼（DashScope）通义千问，OpenAI 兼容模式端点。在百炼控制台「API-KEY 管理」创建 Key，新用户有免费额度。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在阿里云百炼控制台「API-KEY 管理」创建。',
        link: 'https://bailian.console.aliyun.com/?apiKey=1', linkText: '前往阿里云百炼控制台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-kimi',
    label: 'Kimi',
    color: '#1C1C1C',
    badge: 'K',
    kind: 'ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
    subtitle: '官方 API · OpenAI 兼容',
    note: 'Moonshot AI（月之暗面）Kimi 官方 API，OpenAI 兼容协议。在开放平台「API Key 管理」创建 Key。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在 Kimi 开放平台「API Key 管理」页创建。',
        link: 'https://platform.moonshot.cn/console/api-keys', linkText: '前往 Kimi 开放平台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-mimo',
    label: '小米 MiMo',
    color: '#FF6900',
    badge: '米',
    kind: 'ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'mimo-v2.5-pro',
    subtitle: '官方 API · OpenAI 兼容',
    note: '小米 MiMo 官方 API（MiMo-V2.5 系列），兼容 OpenAI Chat Completions 协议，按 token 计费。在开放平台控制台创建 API Key（sk- 开头）。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在小米 MiMo 开放平台控制台「API Keys」页创建。',
        link: 'https://platform.xiaomimimo.com/#/console/api-keys', linkText: '前往小米 MiMo 开放平台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-openai',
    label: 'OpenAI 官方',
    color: '#111111',
    badge: 'O',
    kind: 'ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-5-mini',
    subtitle: '官方 API · GPT 系列',
    note: 'OpenAI 官方 API（Chat Completions 协议），按 token 计费。在 platform.openai.com 创建 API Key；配置页可自动获取模型列表后切换。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在 OpenAI 平台「API Keys」页创建。',
        link: 'https://platform.openai.com/api-keys', linkText: '前往 OpenAI 平台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-anthropic',
    label: 'Claude',
    color: '#D97757',
    badge: '✦',
    kind: 'ai',
    isAI: true,
    aiFormat: 'anthropic',
    baseUrl: 'https://api.anthropic.com',
    defaultModel: 'claude-sonnet-4-5-20250929',
    subtitle: '官方 API · Anthropic 协议',
    note: 'Anthropic Claude 官方 API（/v1/messages，Anthropic 私有协议）。在控制台「API Keys」创建 Key；不同套餐每月有免费调用额度。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-ant-…', secret: true, optional: false,
        hint: '在 Anthropic 控制台「API Keys」页创建。',
        link: 'https://console.anthropic.com/settings/keys', linkText: '前往 Anthropic 控制台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-openai-compat',
    label: 'OpenAI 兼容服务',
    color: '#10A37F',
    badge: 'O',
    kind: 'ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: '',
    defaultModel: '',
    subtitle: '自定义 API 地址 · OpenAI 协议',
    note: '任何兼容 OpenAI Chat Completions 协议的服务：Ollama 本地模型、OpenRouter、硅基流动、各类中转站等。API 地址填写到 /v1 这一级（应用自动拼接 /chat/completions）。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…（本地服务可留空）', secret: true, optional: true,
        hint: '在服务提供方的后台创建；如需 OpenAI 官方，请添加「OpenAI 官方」预置。',
        link: '', linkText: ''
      },
      {
        key: 'baseUrl', label: 'API 地址', placeholder: 'https://api.example.com/v1', secret: false, optional: false,
        hint: '填到 /v1 这一级，如 https://api.openai.com/v1',
        link: '', linkText: ''
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'ai-anthropic-compat',
    label: 'Anthropic 兼容服务',
    color: '#B8926A',
    badge: 'C',
    kind: 'ai',
    isAI: true,
    aiFormat: 'anthropic',
    baseUrl: '',
    defaultModel: '',
    subtitle: '自定义 API 地址 · Anthropic 协议',
    note: '任何兼容 Anthropic Messages 协议（/v1/messages）的服务。鉴权使用 x-api-key 头。API 地址留空时默认官方 https://api.anthropic.com（应用自动拼接 /v1/messages）。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-ant-…', secret: true, optional: false,
        hint: '在服务提供方的后台创建；如需 Anthropic 官方，请添加「Claude」预置。',
        link: '', linkText: ''
      },
      {
        key: 'baseUrl', label: 'API 地址', placeholder: 'https://api.anthropic.com（留空用官方）', secret: false, optional: true,
        hint: '填到域名根（不带 /v1/messages），留空使用官方地址',
        link: '', linkText: ''
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  }
];

/** 传统 + AI 合并的完整可添加目录 */
export function allAddable(): ProviderDef[] {
  const list: ProviderDef[] = [];
  for (const p of TRAD_PROVIDERS) {
    list.push(p);
  }
  for (const p of AI_PROVIDERS) {
    list.push(p);
  }
  return list;
}

// ---- 文字识别服务 OCR（独立目录：不进翻译添加面板，由 OcrServicesPage 驱动）----

/** OCR 传统服务商（官方 OCR API + BYOK） */
export const OCR_TRAD_PROVIDERS: ProviderDef[] = [
  {
    id: 'tencent-ocr',
    label: '腾讯OCR',
    color: '#0A9BFF',
    badge: '讯',
    kind: 'ocr-trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://ocr.tencentcloudapi.com',
    defaultModel: '',
    subtitle: '通用印刷体识别 · 每月 1000 次免费',
    note: '腾讯云文字识别 GeneralBasicOCR（通用印刷体识别），每月 1000 次免费额度，超出部分按量计费。凭证与腾讯云其他服务共用同一套访问密钥，请勿外泄。',
    fields: [
      {
        key: 'secretId', label: 'SecretId', placeholder: 'AKID…', secret: false, optional: false,
        hint: '在腾讯云控制台「访问管理 → API 密钥管理」创建并复制 SecretId。',
        link: 'https://console.cloud.tencent.com/cam/capi', linkText: '前往腾讯云密钥管理'
      },
      {
        key: 'secretKey', label: 'SecretKey', placeholder: '密钥', secret: true, optional: false,
        hint: '与 SecretId 配套的密钥，同一页面创建后复制；需先开通文字识别服务。',
        link: 'https://console.cloud.tencent.com/ocr', linkText: '前往腾讯云文字识别控制台'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  },
  {
    id: 'baidu-ocr',
    label: '百度OCR',
    color: '#2932E1',
    badge: '百',
    kind: 'ocr-trad',
    isAI: false,
    aiFormat: '',
    baseUrl: 'https://aip.baidubce.com',
    defaultModel: '',
    subtitle: '通用文字识别标准版 · 每月 1000 次免费',
    note: '百度智能云通用文字识别（标准版），每月 1000 次免费额度，超出部分按量计费。凭证为千帆平台创建应用后获得的 API Key 与 Secret Key。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'API Key', secret: false, optional: false,
        hint: '在百度智能云控制台「应用列表」创建文字识别应用后查看。',
        link: 'https://console.bce.baidu.com/ai/#/ai/ocr/app/list', linkText: '前往百度智能云控制台'
      },
      {
        key: 'secretKey', label: 'Secret Key', placeholder: 'Secret Key', secret: true, optional: false,
        hint: '与 API Key 同页显示，创建应用时生成。',
        link: 'https://console.bce.baidu.com/ai/#/ai/ocr/app/list', linkText: '前往百度智能云控制台'
      }
    ],
    allowBaseUrl: false,
    allowModel: false
  }
];

/**
 * OCR AI 服务商：程序化从 AI_PROVIDERS 派生（id 加 ocr- 前缀、kind 改 ocr-ai），
 * 与翻译 AI 目录永不失同步；用于 OCR 时通过视觉（多模态）模型识别图片文字。
 */
function deriveOcrAiProviders(): ProviderDef[] {
  const out: ProviderDef[] = [];
  for (const p of AI_PROVIDERS) {
    const q: ProviderDef = {
      id: 'ocr-' + p.id,
      label: p.label,
      color: p.color,
      badge: p.badge,
      kind: 'ocr-ai',
      isAI: p.isAI,
      aiFormat: p.aiFormat,
      baseUrl: p.baseUrl,
      defaultModel: p.defaultModel,
      subtitle: p.subtitle,
      note: p.note + '　本实例用于文字识别（OCR）：发送图片给视觉模型提取图中文字，请选择支持视觉/多模态的模型。',
      fields: p.fields,
      allowBaseUrl: p.allowBaseUrl,
      allowModel: p.allowModel
    };
    out.push(q);
  }
  return out;
}

/** OCR AI 服务商（视觉模型识别图片文字） */
export const OCR_AI_PROVIDERS: ProviderDef[] = deriveOcrAiProviders();

// ---- 语音服务 TTS（独立目录：不进翻译添加面板，由 TtsServicesPage 驱动）----
// 合成协议统一为 OpenAI /audio/speech 形状（模型/文本/音色 → mp3 音频）；
// Anthropic 兼容仅改变鉴权方式（x-api-key），用于兼容中转站。

/** TTS 服务商（云端语音合成） */
export const TTS_PROVIDERS: ProviderDef[] = [
  {
    id: 'tts-mimo',
    label: '小米 MiMo',
    color: '#FF6900',
    badge: '米',
    kind: 'tts-ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'mimo-v2.5-tts',
    defaultVoice: 'mimo_default',
    ttsApi: 'mimo',
    ttsVoices: ['mimo_default', '冰糖', '茉莉', '苏打', '白桦', 'Mia', 'Chloe', 'Milo', 'Dean'],
    subtitle: '官方 API · chat 接口音频输出',
    note: '小米 MiMo 语音合成（官方文档：POST /v1/chat/completions，音频以 base64 随响应返回，非 /audio/speech）。模型可选 mimo-v2.5-tts（预置音色）/ tts-voicedesign（音色设计）/ tts-voiceclone（音色克隆，音色填音频样本 base64）。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在小米 MiMo 开放平台控制台「API Keys」页创建。',
        link: 'https://platform.xiaomimimo.com/#/console/api-keys', linkText: '前往小米 MiMo 开放平台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'tts-openai',
    label: 'OpenAI 官方',
    color: '#111111',
    badge: 'O',
    kind: 'tts-ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini-tts',
    defaultVoice: 'alloy',
    ttsVoices: ['alloy', 'ash', 'ballad', 'coral', 'echo', 'fable', 'onyx', 'nova', 'sage', 'shimmer', 'verse'],
    subtitle: '官方 API · TTS 模型',
    note: 'OpenAI 语音合成（/v1/audio/speech），按字符计费。模型可选 tts-1 / tts-1-hd / gpt-4o-mini-tts；音色 alloy、echo、fable、onyx、nova、shimmer 等。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…', secret: true, optional: false,
        hint: '在 OpenAI 平台「API Keys」页创建。',
        link: 'https://platform.openai.com/api-keys', linkText: '前往 OpenAI 平台'
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'tts-openai-compat',
    label: 'OpenAI 兼容服务',
    color: '#10A37F',
    badge: 'O',
    kind: 'tts-ai',
    isAI: true,
    aiFormat: 'openai',
    baseUrl: '',
    defaultModel: '',
    subtitle: '自定义 API 地址 · /audio/speech',
    note: '任何兼容 OpenAI /audio/speech 协议的语音合成服务（本地推理、中转站等）。API 地址填写到 /v1 这一级（应用自动拼接 /audio/speech）。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-…（本地服务可留空）', secret: true, optional: true,
        hint: '在服务提供方的后台创建；如需 OpenAI 官方，请添加「OpenAI 官方」预置。',
        link: '', linkText: ''
      },
      {
        key: 'baseUrl', label: 'API 地址', placeholder: 'https://api.example.com/v1', secret: false, optional: false,
        hint: '填到 /v1 这一级，应用自动拼接 /audio/speech。',
        link: '', linkText: ''
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  },
  {
    id: 'tts-anthropic-compat',
    label: 'Anthropic 兼容服务',
    color: '#B8926A',
    badge: 'C',
    kind: 'tts-ai',
    isAI: true,
    aiFormat: 'anthropic',
    baseUrl: '',
    defaultModel: '',
    subtitle: '自定义 API 地址 · 兼容中转',
    note: '用于兼容中转站的语音合成：请求形状与 OpenAI /audio/speech 一致，鉴权使用 x-api-key 头（Anthropic 风格）。API 地址留空时默认官方域名；官方 Anthropic 暂无 TTS 接口，此项供自建/中转兼容服务使用。',
    fields: [
      {
        key: 'apiKey', label: 'API Key', placeholder: 'sk-ant-…', secret: true, optional: false,
        hint: '在服务提供方的后台创建；如需 Claude 翻译，请添加「Claude」预置。',
        link: '', linkText: ''
      },
      {
        key: 'baseUrl', label: 'API 地址', placeholder: 'https://api.example.com（留空用官方域名）', secret: false, optional: true,
        hint: '填到域名根，应用自动拼接 /v1/audio/speech。',
        link: '', linkText: ''
      }
    ],
    allowBaseUrl: true,
    allowModel: true
  }
];

export function findDef(id: string): ProviderDef | undefined {
  for (const p of FREE_PROVIDERS) {
    if (p.id === id) {
      return p;
    }
  }
  for (const p of TRAD_PROVIDERS) {
    if (p.id === id) {
      return p;
    }
  }
  for (const p of AI_PROVIDERS) {
    if (p.id === id) {
      return p;
    }
  }
  for (const p of OCR_TRAD_PROVIDERS) {
    if (p.id === id) {
      return p;
    }
  }
  for (const p of OCR_AI_PROVIDERS) {
    if (p.id === id) {
      return p;
    }
  }
  for (const p of TTS_PROVIDERS) {
    if (p.id === id) {
      return p;
    }
  }
  return undefined;
}
