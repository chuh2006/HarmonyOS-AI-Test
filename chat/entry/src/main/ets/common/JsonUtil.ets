/**
 * JSON helper utilities that keep dynamic JSON handling ArkTS friendly.
 * All provider payloads travel through the app as JSON strings and are
 * inspected with these accessors instead of untyped indexing.
 */

export function parseObj(text: string): Record<string, Object> {
  if (text.length === 0) {
    return {};
  }
  try {
    const v: Object | null = JSON.parse(text);
    if (v === null || v === undefined) {
      return {};
    }
    return asRecord(v);
  } catch (e) {
    return {};
  }
}

export function asRecord(v: Object): Record<string, Object> {
  return v as Record<string, Object>;
}

export function hasKey(o: Record<string, Object>, key: string): boolean {
  return o[key] !== undefined && o[key] !== null;
}

export function getStr(o: Record<string, Object>, key: string): string {
  const v: Object | undefined = o[key];
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  return '';
}

export function optStr(o: Record<string, Object>, key: string, fallback: string): string {
  const s: string = getStr(o, key);
  return s.length > 0 ? s : fallback;
}

export function getNum(o: Record<string, Object>, key: string): number {
  const v: Object | undefined = o[key];
  if (v === undefined || v === null) {
    return 0;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  return 0;
}

export function getBool(o: Record<string, Object>, key: string): boolean {
  const v: Object | undefined = o[key];
  if (v === undefined || v === null) {
    return false;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return false;
}

export function hasBool(o: Record<string, Object>, key: string): boolean {
  const v: Object | undefined = o[key];
  return v !== undefined && v !== null && typeof v === 'boolean';
}

export function getObj(o: Record<string, Object>, key: string): Record<string, Object> {
  const v: Object | undefined = o[key];
  if (v === undefined || v === null) {
    return {};
  }
  if (typeof v === 'object') {
    return asRecord(v);
  }
  return {};
}

export function hasObj(o: Record<string, Object>, key: string): boolean {
  const v: Object | undefined = o[key];
  return v !== undefined && v !== null && typeof v === 'object';
}

export function getArr(o: Record<string, Object>, key: string): Object[] {
  const v: Object | undefined = o[key];
  if (v === undefined || v === null) {
    return [];
  }
  return asArr(v);
}

export function asArr(v: Object): Object[] {
  if (Array.isArray(v)) {
    return v as Object[];
  }
  return [];
}

export function getStrArr(o: Record<string, Object>, key: string): string[] {
  const out: string[] = [];
  const arr: Object[] = getArr(o, key);
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item === 'string') {
      out.push(item as string);
    }
  }
  return out;
}

/** Convert a value into a JSON string, tolerating plain strings. */
export function toJsonText(v: Object | null | undefined): string {
  if (v === null || v === undefined) {
    return 'null';
  }
  if (typeof v === 'string') {
    return JSON.stringify(v);
  }
  try {
    return JSON.stringify(v);
  } catch (e) {
    return 'null';
  }
}
