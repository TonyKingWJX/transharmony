/**
 * JSON 安全解析工具。
 * ArkTS 严格模式不允许 any/unknown 随意访问属性，
 * 这里提供类型守卫式的取值函数，引擎层用它做响应解析。
 */

export function isObject(v: object | null): boolean {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

export function getStr(obj: Record<string, Object | null>, key: string): string {
  const v = obj[key];
  return typeof v === 'string' ? v : '';
}

export function getNum(obj: Record<string, Object | null>, key: string): number {
  const v = obj[key];
  return typeof v === 'number' ? v : 0;
}

export function getObj(obj: Record<string, Object | null>, key: string): Record<string, Object | null> | null {
  const v = obj[key];
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
    return v as Record<string, Object | null>;
  }
  return null;
}

export function getArr(obj: Record<string, Object | null>, key: string): Record<string, Object | null>[] {
  const v = obj[key];
  if (Array.isArray(v)) {
    const out: Record<string, Object | null>[] = [];
    for (let i = 0; i < v.length; i++) {
      const it: Object = v[i];
      if (typeof it === 'object' && it !== null && !Array.isArray(it)) {
        out.push(it as Record<string, Object | null>);
      }
    }
    return out;
  }
  return [];
}

/** 顶层元素为字符串的 JSON 数组取值（如有道响应的 translation 字段） */
export function getStrArr(obj: Record<string, Object | null>, key: string): string[] {
  const v = obj[key];
  if (Array.isArray(v)) {
    const out: string[] = [];
    for (let i = 0; i < v.length; i++) {
      const it: Object = v[i];
      if (typeof it === 'string') {
        out.push(it);
      }
    }
    return out;
  }
  return [];
}

export function safeParse(text: string): Record<string, Object | null> | null {
  try {
    const v: Object = JSON.parse(text);
    if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
      return v as Record<string, Object | null>;
    }
    return null;
  } catch (e) {
    return null;
  }
}

/** 顶层是数组的 JSON 安全解析（如 Azure Translator 响应） */
export function safeParseArray(text: string): Record<string, Object | null>[] {
  try {
    const v: Object = JSON.parse(text);
    if (Array.isArray(v)) {
      return getArr({ 'items': v }, 'items');
    }
    return [];
  } catch (e) {
    return [];
  }
}
