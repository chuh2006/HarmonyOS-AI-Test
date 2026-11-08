/**
 * HTTP layer: streaming POST (SSE) plus a plain JSON POST used by the tools.
 * Built on @ohos.net.http with UTF-8 decoding that survives chunk splits.
 */
import http from '@ohos.net.http';
import util from '@ohos.util';
import type { BusinessError } from '@ohos.base';

export interface StreamListener {
  /** A chunk of decoded UTF-8 text (may contain partial SSE events). */
  onChunk(text: string): void;

  /** Stream finished. stopped=true means the app cancelled it. */
  onEnd(stopped: boolean): void;

  /** Terminal failure. */
  onError(message: string, code: number): void;
}

export class StreamHandle {
  private req: http.HttpRequest | null = null;
  private listener: StreamListener | null = null;
  private decoder: util.TextDecoder | null = null;
  private settled: boolean = false;
  private cancelled: boolean = false;
  private errorMode: boolean = false;
  private errBuf: string = '';
  private httpCode: number = 0;

  bind(req: http.HttpRequest, listener: StreamListener): void {
    this.req = req;
    this.listener = listener;
    this.decoder = util.TextDecoder.create('utf-8', { 'ignoreBOM': true });
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  acceptChunk(buf: ArrayBuffer): void {
    if (this.settled || this.cancelled) {
      return;
    }
    if (this.decoder === null || this.listener === null) {
      return;
    }
    const s: string = this.decoder.decodeToString(new Uint8Array(buf), { 'stream': true });
    if (this.errorMode) {
      this.errBuf += s;
      return;
    }
    if (s.length > 0) {
      this.listener.onChunk(s);
    }
  }

  status(code: number): void {
    this.httpCode = code;
    if (code >= 400) {
      this.errorMode = true;
    }
  }

  finish(): void {
    if (this.settled || this.cancelled) {
      return;
    }
    if (this.decoder !== null) {
      const tail: string = this.decoder.decodeToString(new Uint8Array(0), { 'stream': true });
      if (!this.errorMode && tail.length > 0 && this.listener !== null) {
        this.listener.onChunk(tail);
      }
    }
    if (this.errorMode) {
      const code: number = this.httpCode;
      const msg: string = serverMessage(this.errBuf, code);
      this.settled = true;
      this.destroyReq();
      if (this.listener !== null) {
        this.listener.onError(msg, code);
      }
      return;
    }
    this.settled = true;
    this.destroyReq();
    if (this.listener !== null) {
      this.listener.onEnd(false);
    }
  }

  fail(message: string, code: number): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.destroyReq();
    if (this.listener !== null) {
      this.listener.onError(message, code);
    }
  }

  /** Cancel the request; the listener receives onEnd(true). */
  cancel(): void {
    if (this.settled) {
      this.cancelled = true;
      this.destroyReq();
      return;
    }
    this.cancelled = true;
    this.settled = true;
    this.destroyReq();
    if (this.listener !== null) {
      this.listener.onEnd(true);
    }
  }

  private destroyReq(): void {
    if (this.req !== null) {
      const r: http.HttpRequest = this.req;
      try {
        r.destroy();
      } catch (e) {
        // ignore
      }
      this.req = null;
    }
  }
}

export class HttpResult {
  code: number = 0;
  body: string = '';
  ok: boolean = false;
}

/** Map transport / HTTP failures onto messages a normal user understands. */
export function describeError(code: number, detail: string): string {
  if (code === 401 || code === 403) {
    return '鉴权失败，请检查 API Key 是否正确。';
  }
  if (code === 402) {
    return '账户余额不足，请检查服务商账户。';
  }
  if (code === 404) {
    return '接口不存在，请检查 Base URL 与模型名是否正确。';
  }
  if (code === 408) {
    return '请求超时，请稍后重试。';
  }
  if (code === 429) {
    return '请求太频繁，已被限流，请稍后重试。';
  }
  if (code >= 500) {
    return '服务端暂时不可用（' + code.toString() + '），请稍后重试。';
  }
  if (code >= 2300000 || code <= -1) {
    return '网络连接失败，请检查网络后重试。';
  }
  if (detail.length > 0) {
    return detail;
  }
  return '请求失败（' + code.toString() + '）。';
}

function toRecord(v: Object): Record<string, Object> {
  return v as Record<string, Object>;
}

function digMessage(o: Record<string, Object>): string {
  const direct: Object | undefined = o['message'];
  if (direct !== undefined && direct !== null && typeof direct === 'string') {
    return direct as string;
  }
  const err: Object | undefined = o['error'];
  if (err !== undefined && err !== null && typeof err === 'string') {
    return err as string;
  }
  if (err !== undefined && err !== null && typeof err === 'object') {
    const inner: Record<string, Object> = toRecord(err);
    const m: Object | undefined = inner['message'];
    if (m !== undefined && m !== null && typeof m === 'string') {
      return m as string;
    }
  }
  const detail: Object | undefined = o['detail'];
  if (detail !== undefined && detail !== null && typeof detail === 'string') {
    return detail as string;
  }
  return '';
}

/** Best-effort message extraction from a failed response body. */
export function serverMessage(body: string, code: number): string {
  let detail: string = '';
  try {
    const v: Object | null = JSON.parse(body);
    if (v !== null && typeof v === 'object') {
      detail = digMessage(toRecord(v));
    }
  } catch (e) {
    detail = '';
  }
  if (detail.length === 0 && body.length > 0 && body.length < 300) {
    detail = body;
  }
  return describeError(code, detail);
}

function headerRecord(headers: Record<string, string>): Object {
  const out: Record<string, string> = {};
  const keys: string[] = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    out[keys[i]] = headers[keys[i]];
  }
  return out as Object;
}

/**
 * Start a streaming POST. Text chunks are decoded incrementally so that
 * multi-byte UTF-8 characters split across packets are reassembled.
 */
export function postStream(url: string, headers: Record<string, string>, bodyJson: string,
  listener: StreamListener, timeoutMs: number = 180000): StreamHandle {
  const handle: StreamHandle = new StreamHandle();
  const req: http.HttpRequest = http.createHttp();
  handle.bind(req, listener);

  const onData = (buf: ArrayBuffer): void => {
    handle.acceptChunk(buf);
  };
  const onEnd = (): void => {
    handle.finish();
  };
  req.on('dataReceive', onData);
  req.on('dataEnd', onEnd);

  const opts: http.HttpRequestOptions = {
    method: http.RequestMethod.POST,
    header: headerRecord(headers),
    extraData: bodyJson,
    connectTimeout: 20000,
    readTimeout: timeoutMs,
    usingCache: false,
    expectDataType: http.HttpDataType.STRING
  };
  req.requestInStream(url, opts, (err: BusinessError, code: number) => {
    if (handle.isCancelled()) {
      return;
    }
    if (err !== null && err !== undefined && err.code !== 0) {
      handle.fail(describeError(err.code, ''), err.code);
      return;
    }
    handle.status(code);
  });
  return handle;
}

/** Plain JSON POST used by the search / fetch tools. */
export function postJson(url: string, headers: Record<string, string>, bodyJson: string,
  timeoutMs: number = 60000): Promise<HttpResult> {
  return new Promise((resolve: (r: HttpResult) => void) => {
    const req: http.HttpRequest = http.createHttp();
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headerRecord(headers),
      extraData: bodyJson,
      connectTimeout: 15000,
      readTimeout: timeoutMs,
      usingCache: false,
      expectDataType: http.HttpDataType.STRING
    };
    req.request(url, opts, (err: BusinessError, resp: http.HttpResponse) => {
      const out: HttpResult = new HttpResult();
      try {
        if (err !== null && err !== undefined && err.code !== 0) {
          out.code = err.code;
          out.body = '';
          out.ok = false;
        } else {
          out.code = resp.responseCode;
          out.body = typeof resp.result === 'string' ? resp.result as string : JSON.stringify(resp.result);
          out.ok = resp.responseCode >= 200 && resp.responseCode < 300;
        }
      } catch (e) {
        out.code = -1;
        out.body = '';
        out.ok = false;
      }
      req.destroy();
      resolve(out);
    });
  });
}
