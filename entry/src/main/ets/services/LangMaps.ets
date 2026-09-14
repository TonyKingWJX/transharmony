/**
 * 语言代码映射：内部枚举 → 各服务商私有代码。
 * 各 Adapter 持有自己的映射器，UI 层永远只见内部枚举。
 */

export function baiduCode(code: string): string {
  // 百度通用翻译：zh 简体 / en / jp / kor / fra / de / ru / spa / th / vie
  const map: Record<string, string> = {
    'zh': 'zh',
    'en': 'en',
    'ja': 'jp',
    'ko': 'kor',
    'fr': 'fra',
    'de': 'de',
    'ru': 'ru',
    'es': 'spa',
    'th': 'th',
    'vi': 'vie'
  };
  return map[code] ?? code;
}

export function tencentCode(code: string): string {
  // 腾讯云 TMT 文本翻译：zh / en / ja / ko / fr / de / ru / es / th / vi
  const map: Record<string, string> = {
    'zh': 'zh',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'ru': 'ru',
    'es': 'es',
    'th': 'th',
    'vi': 'vi'
  };
  return map[code] ?? code;
}

export function azureCode(code: string): string {
  // Azure Translator v3：简体中文是 zh-Hans（不接受裸 zh），其余首发语言代码一致
  const map: Record<string, string> = {
    'zh': 'zh-Hans'
  };
  return map[code] ?? code;
}

/** Azure 检测到的语言代码 → 内部代码 */
export function azureFromAzure(code: string): string {
  const map: Record<string, string> = {
    'zh-Hans': 'zh',
    'zh-Hant': 'zh'
  };
  return map[code] ?? code;
}

export function youdaoCode(code: string): string {
  // 有道：简体中文是 zh-CHS；en/ja/ko/fr/de/ru/es/th/vi 一致
  const map: Record<string, string> = {
    'zh': 'zh-CHS'
  };
  return map[code] ?? code;
}

/** 有道检测到的语言代码 → 内部代码 */
export function youdaoFromYoudao(code: string): string {
  const map: Record<string, string> = {
    'zh-CHS': 'zh',
    'zh-CHT': 'zh'
  };
  return map[code] ?? code;
}

/** 内部代码 → 给大模型看的语言名 */
export function aiLangName(code: string): string {
  const map: Record<string, string> = {
    'zh': '简体中文',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'fr': '法语',
    'de': '德语',
    'ru': '俄语',
    'es': '西班牙语',
    'th': '泰语',
    'vi': '越南语',
    'id': '印尼语',
    'tet': '德顿语'
  };
  return map[code] ?? code;
}
