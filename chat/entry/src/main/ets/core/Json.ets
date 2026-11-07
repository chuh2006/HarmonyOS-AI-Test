// JSON boundary used by the REST protocols. Opaque provider fields stay intact.
export class J {
  value: Object | null;
  constructor(value: Object | null) { this.value = value; }
  static object(): J {
    const value: Record<string, Object | null> = {};
    return new J(value);
  }
  static parse(text: string): J { return new J(JSON.parse(text) as Object | null); }
  get(key: string): J {
    if (!this.isObject()) { return new J(null); }
    const value = (this.value as Record<string, Object | null>)[key];
    return new J(value === undefined ? null : value);
  }
  has(key: string): boolean { return this.isObject() && Object.keys(this.value as Object).includes(key); }
  set(key: string, value: Object | null): J {
    (this.value as Record<string, Object | null>)[key] = value;
    return this;
  }
  str(): string { return typeof this.value === 'string' ? this.value as string : ''; }
  num(): number { return typeof this.value === 'number' ? this.value as number : 0; }
  bool(): boolean { return this.value === true; }
  isObject(): boolean { return this.value !== null && typeof this.value === 'object' && !Array.isArray(this.value); }
  array(): J[] {
    if (!Array.isArray(this.value)) { return []; }
    return (this.value as Object[]).map((v: Object) => new J(v));
  }
  json(): string { return JSON.stringify(this.value); }
}

export function raw(items: J[]): Object[] { return items.map((item: J) => item.value as Object); }

export function safeError(error: Error, secrets: string[] = []): string {
  let text = error.message || '操作失败，请稍后重试';
  secrets.forEach((secret: string) => {
    if (secret.length > 0) { text = text.split(secret).join('[已隐藏]'); }
  });
  return text.replace(/Bearer\s+[^\s"<>]+/gi, 'Bearer [已隐藏]')
    .replace(/sk-[A-Za-z0-9_-]+/g, '[已隐藏]').slice(0, 600);
}
