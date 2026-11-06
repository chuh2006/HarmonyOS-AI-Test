// 服务端返回的 JSON 里，字段经常是显式 null 而不是缺失
// (OpenAI 的 "error": null、Mercury 的 "content": null、"param": null)。
// 只判 !== undefined 会漏掉 null，取值时直接抛 TypeError，
// 而这类异常会被流式回调捕获后伪装成"响应解析失败"。
// 统一用下面的helper读取，null 与 undefined 同等对待。

export function textOr(value: string | undefined | null): string {
  return value === undefined || value === null ? '' : value;
}

export function hasText(value: string | undefined | null): boolean {
  return value !== undefined && value !== null && value.length > 0;
}

export function listOr<T>(value: T[] | undefined | null): T[] {
  return value === undefined || value === null ? [] : value;
}

export function hasItems<T>(value: T[] | undefined | null): boolean {
  return value !== undefined && value !== null && value.length > 0;
}

export function numberOr(value: number | undefined | null): number | undefined {
  return value === undefined || value === null ? undefined : value;
}

export function present(value: Object | undefined | null): boolean {
  return value !== undefined && value !== null;
}

export function recordOrNull(value: Object | undefined | null): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

// 读取 Record 里的字符串字段，缺失/为null/类型不符都返回空串
export function stringField(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key];
  if (value !== undefined && value !== null && typeof value === 'string') {
    return value as string;
  }
  return '';
}

// 工具参数以JSON字符串保存，回传时还原为对象
export function parseJsonObject(text: string): Record<string, Object> {
  const empty: Record<string, Object> = {};
  if (text.length === 0) {
    return empty;
  }
  try {
    const parsed: Object = JSON.parse(text) as Object;
    const record: Record<string, Object> | null = recordOrNull(parsed);
    return record !== null ? record : empty;
  } catch (e) {
    return empty;
  }
}
