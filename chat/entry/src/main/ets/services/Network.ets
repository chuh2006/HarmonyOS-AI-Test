import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { J, safeError } from '../core/Json';
import { SseEvent, SseParser } from '../core/Sse';

export class Cancellation {
  cancelled: boolean = false;
  private listeners: Set<() => void> = new Set();
  check(): void { if (this.cancelled) { throw new Error('已停止'); } }
  add(listener: () => void): void {
    if (this.cancelled) { listener(); } else { this.listeners.add(listener); }
  }
  remove(listener: () => void): void { this.listeners.delete(listener); }
  cancel(): void {
    this.cancelled = true;
    const listeners = Array.from(this.listeners); this.listeners.clear();
    listeners.forEach((fn: () => void) => fn());
  }
}

export class RequestSpec {
  url: string;
  headers: Record<string, string>;
  body: string;
  constructor(url: string, headers: Record<string, string>, body: string) {
    this.url = url; this.headers = headers; this.body = body;
  }
}

export interface Transport {
  stream(request: RequestSpec, token: Cancellation, onEvent: (event: SseEvent) => void): Promise<void>;
  json(request: RequestSpec, token: Cancellation): Promise<J>;
}

export function validateBaseUrl(value: string): string {
  const clean = value.trim().replace(/\/+$/, '');
  if (clean.indexOf('://') !== clean.lastIndexOf('://')) { throw new Error('地址中包含多个协议前缀，请替换为完整的服务地址'); }
  if (!/^https:\/\/[^\s/?#@]+(?::\d+)?(?:\/[^\s?#]*)?$/.test(clean) &&
    !/^http:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?(?:\/[^\s?#]*)?$/.test(clean)) {
    throw new Error('请输入完整的 HTTPS 地址，不含密钥、查询参数或片段');
  }
  return clean;
}

function httpError(code: number, body: string): Error {
  let detail = '';
  try { const j = J.parse(body); detail = j.get('error').get('message').str() || j.get('message').str(); } catch (_) {}
  let message = '服务请求失败';
  if (code === 401 || code === 403) { message = '密钥无效或没有访问权限，请检查服务设置'; }
  else if (code === 429) { message = '请求过于频繁或额度不足，请稍后重试'; }
  else if (code === 404) { message = '未找到接口或模型，请检查地址和模型权限'; }
  else if (code >= 500) { message = '服务暂时不可用，请稍后重试'; }
  return new Error(message + '（HTTP ' + code + '）' + (detail ? '\n' + detail.slice(0, 400) : ''));
}

export class HttpTransport implements Transport {
  async stream(request: RequestSpec, token: Cancellation, onEvent: (event: SseEvent) => void): Promise<void> {
    const parser = new SseParser(onEvent);
    await this.read(request, token, (text: string) => parser.push(text), () => parser.finish(), false);
  }
  async json(request: RequestSpec, token: Cancellation): Promise<J> {
    let body = '';
    await this.read(request, token, (text: string) => {
      body += text;
      if (body.length > 4 * 1024 * 1024) { throw new Error('网页内容过大，请尝试其他页面'); }
    }, () => {}, true);
    try { return J.parse(body); } catch (_) { throw new Error('工具服务返回了无法解析的 JSON'); }
  }
  private read(request: RequestSpec, token: Cancellation, onText: (text: string) => void,
    onEnd: () => void, tool: boolean): Promise<void> {
    token.check();
    return new Promise<void>((resolve, reject) => {
      const connection = http.createHttp();
      const decoder = util.TextDecoder.create('utf-8', { fatal: true });
      let settled = false;
      let ended = false;
      let code = 0;
      let sample = '';
      let idle = 0;
      let total = 0;
      const secrets = Object.keys(request.headers).map((key: string) => request.headers[key].replace(/^Bearer /, ''));
      const cleanup = (): void => {
        clearTimeout(idle); clearTimeout(total); token.remove(cancel);
        connection.destroy();
      };
      const fail = (error: Error): void => {
        if (settled) { return; } settled = true; cleanup(); reject(new Error(safeError(error, secrets)));
      };
      const cancel = (): void => fail(new Error('已停止'));
      const finish = (): void => {
        if (settled || !ended || code === 0) { return; }
        if (code < 200 || code >= 300) { fail(httpError(code, sample)); return; }
        try { onEnd(); } catch (error) { fail(error as Error); return; }
        settled = true; cleanup(); resolve();
      };
      const resetIdle = (): void => {
        clearTimeout(idle);
        idle = setTimeout(() => fail(new Error('等待响应超时，已保留收到的内容')), tool ? 45000 : 90000);
      };
      token.add(cancel);
      if (settled) { return; }
      resetIdle();
      total = setTimeout(() => fail(new Error('请求超时，请重试或降低思考强度')), tool ? 60000 : 300000);
      connection.on('dataReceive', (buffer: ArrayBuffer) => {
        if (settled) { return; }
        try {
          token.check(); resetIdle();
          const text = decoder.decodeToString(new Uint8Array(buffer), { stream: true });
          sample += text.slice(0, Math.max(0, 8192 - sample.length));
          onText(text);
        } catch (error) { fail(error as Error); }
      });
      connection.on('dataEnd', () => {
        if (settled || ended) { return; }
        try { onText(decoder.decodeToString(new Uint8Array(0), { stream: false })); }
        catch (error) { fail(error as Error); return; }
        ended = true; finish();
      });
      connection.requestInStream(request.url, {
        method: http.RequestMethod.POST,
        header: request.headers,
        extraData: request.body,
        connectTimeout: 20000,
        readTimeout: tool ? 45000 : 90000,
        usingCache: false,
        usingProxy: !request.url.startsWith('http://127.0.0.1') && !request.url.startsWith('http://localhost')
      }).then((status: number) => { code = status; finish(); })
        .catch((error: BusinessError) => fail(new Error('连接失败，请检查网络或服务地址。' + safeError(error, secrets) +
          (error.code ? '（' + error.code + '）' : ''))));
    });
  }
}
