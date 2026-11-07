import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class ChatError extends Error {
  aborted: boolean = false;
  status: number = 0;

  constructor(message: string, aborted: boolean = false) {
    super(message);
    this.name = 'ChatError';
    this.aborted = aborted;
  }
}

export class SseEvent {
  event: string = '';
  data: string = '';
}

export class SseParser {
  private buffer: string = '';
  private eventName: string = '';
  private dataLines: string[] = [];

  feed(chunk: string, onEvent: (e: SseEvent) => void): void {
    this.buffer += chunk;
    let idx = this.buffer.indexOf('\n');
    while (idx >= 0) {
      let line = this.buffer.substring(0, idx);
      this.buffer = this.buffer.substring(idx + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      this.processLine(line, onEvent);
      idx = this.buffer.indexOf('\n');
    }
  }

  flush(onEvent: (e: SseEvent) => void): void {
    if (this.buffer.length > 0) {
      let line = this.buffer;
      this.buffer = '';
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      this.processLine(line, onEvent);
    }
    this.dispatch(onEvent);
  }

  private processLine(line: string, onEvent: (e: SseEvent) => void): void {
    if (line.length === 0) {
      this.dispatch(onEvent);
      return;
    }
    if (line.startsWith(':')) {
      return;
    }
    const colon = line.indexOf(':');
    const field = colon < 0 ? line : line.substring(0, colon);
    let value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) {
      value = value.substring(1);
    }
    if (field === 'event') {
      this.eventName = value;
    } else if (field === 'data') {
      this.dataLines.push(value);
    }
  }

  private dispatch(onEvent: (e: SseEvent) => void): void {
    if (this.dataLines.length === 0) {
      this.eventName = '';
      return;
    }
    const e = new SseEvent();
    e.event = this.eventName;
    e.data = this.dataLines.join('\n');
    this.eventName = '';
    this.dataLines = [];
    onEvent(e);
  }
}

export class StreamHandle {
  req: http.HttpRequest | null = null;
  aborted: boolean = false;
  rejectFn: ((e: ChatError) => void) | null = null;

  abort(): void {
    if (this.aborted) {
      return;
    }
    this.aborted = true;
    const r = this.req;
    if (r !== null) {
      try {
        r.destroy();
      } catch (e) {
        // 忽略销毁异常
      }
    }
    const rej = this.rejectFn;
    if (rej !== null) {
      rej(new ChatError('已停止生成', true));
    }
  }
}

interface ErrorPayload {
  message?: string;
  code?: string;
}

interface ErrorBody {
  error?: ErrorPayload;
  message?: string;
}

export function extractApiError(body: string): string {
  try {
    const parsed = JSON.parse(body) as ErrorBody;
    if (parsed.error !== undefined && parsed.error.message !== undefined) {
      return parsed.error.message;
    }
    if (parsed.message !== undefined) {
      return parsed.message;
    }
  } catch (e) {
    // 非 JSON 错误体
  }
  const trimmed = body.trim();
  return trimmed.length > 160 ? trimmed.substring(0, 160) : trimmed;
}

export function httpError(status: number, body: string): ChatError {
  const detail = extractApiError(body);
  let prefix = '';
  switch (status) {
    case 400: prefix = '请求无效'; break;
    case 401: prefix = 'API Key 无效或已过期'; break;
    case 402: prefix = '账号余额不足'; break;
    case 403: prefix = '没有访问权限'; break;
    case 404: prefix = '接口或资源不存在'; break;
    case 408: prefix = '请求超时'; break;
    case 413: prefix = '内容过长，超出限制'; break;
    case 422: prefix = '请求参数不被接受'; break;
    case 429: prefix = '请求过于频繁，请稍后再试'; break;
    default:
      prefix = status >= 500 ? '服务端暂时出错' : `请求失败（${status}）`;
  }
  const err = new ChatError(detail.length > 0 ? `${prefix}：${detail}` : prefix);
  err.status = status;
  return err;
}

export function networkError(err: BusinessError): ChatError {
  const code = err.code;
  switch (code) {
    case 2300006: return new ChatError('无法解析服务器地址，请检查 Base URL 是否正确');
    case 2300007: return new ChatError('无法连接服务器，请检查网络后重试');
    case 2300028: return new ChatError('网络超时，请重试');
    case 2300023: return new ChatError('安全连接失败，请检查 Base URL');
    case 2300056: return new ChatError('连接被重置，请重试');
    default: return new ChatError(`网络请求失败，请检查网络（${code}）`);
  }
}

function mergeHeaders(headers: Record<string, string>): Object {
  const h: Record<string, string> = {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream'
  };
  const keys = Object.keys(headers);
  for (const k of keys) {
    h[k] = headers[k];
  }
  return h;
}

export async function streamPost(url: string, headers: Record<string, string>, body: string,
  onEvent: (e: SseEvent) => void, handle: StreamHandle): Promise<void> {
  if (handle.aborted) {
    throw new ChatError('已停止生成', true);
  }
  const req = http.createHttp();
  handle.req = req;
  const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  const parser = new SseParser();
  let statusKnown = false;
  let statusOk = false;
  let statusCode = 0;
  let ended = false;
  let errorText = '';
  const pending: string[] = [];

  try {
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      handle.rejectFn = reject;
      const fail = (e: ChatError): void => {
        if (!settled) {
          settled = true;
          reject(e);
        }
      };
      const succeed = (): void => {
        if (!settled) {
          settled = true;
          resolve();
        }
      };
      const feedText = (text: string): void => {
        parser.feed(text, onEvent);
      };
      const tryFinish = (): void => {
        if (!statusKnown || !ended) {
          return;
        }
        try {
          if (statusOk) {
            const tail = decoder.decodeToString(new Uint8Array(0), { stream: false });
            if (tail.length > 0) {
              feedText(tail);
            }
            parser.flush(onEvent);
            succeed();
          } else {
            fail(httpError(statusCode, errorText));
          }
        } catch (e) {
          fail(e instanceof ChatError ? e : new ChatError('响应解析失败'));
        }
      };

      req.on('dataReceive', (data: ArrayBuffer) => {
        if (handle.aborted || settled) {
          return;
        }
        try {
          const text = decoder.decodeToString(new Uint8Array(data), { stream: true });
          if (!statusKnown) {
            pending.push(text);
          } else if (statusOk) {
            feedText(text);
          } else {
            errorText += text;
          }
        } catch (e) {
          fail(e instanceof ChatError ? e : new ChatError('响应解码失败'));
        }
      });
      req.on('dataEnd', () => {
        ended = true;
        tryFinish();
      });

      req.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: mergeHeaders(headers),
        extraData: body,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000,
        readTimeout: 180000
      }).then((code: number) => {
        if (settled) {
          return;
        }
        statusCode = code;
        statusKnown = true;
        statusOk = code >= 200 && code < 300;
        if (statusOk) {
          for (const t of pending) {
            try {
              feedText(t);
            } catch (e) {
              fail(e instanceof ChatError ? e : new ChatError('响应解析失败'));
              return;
            }
          }
        } else {
          errorText = pending.join('');
        }
        pending.length = 0;
        if (ended) {
          tryFinish();
        }
      }).catch((err: BusinessError) => {
        if (handle.aborted) {
          fail(new ChatError('已停止生成', true));
        } else {
          fail(networkError(err));
        }
      });
    });
  } finally {
    handle.rejectFn = null;
    handle.req = null;
    try {
      req.off('dataReceive');
      req.off('dataEnd');
      req.destroy();
    } catch (e) {
      // 忽略清理异常
    }
  }
}

export async function jsonPost(url: string, headers: Record<string, string>, body: string,
  handle: StreamHandle): Promise<string> {
  if (handle.aborted) {
    throw new ChatError('已停止生成', true);
  }
  const req = http.createHttp();
  handle.req = req;
  try {
    const resp = await req.request(url, {
      method: http.RequestMethod.POST,
      header: mergeHeaders(headers),
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 30000,
      readTimeout: 60000
    });
    if (handle.aborted) {
      throw new ChatError('已停止生成', true);
    }
    const text = typeof resp.result === 'string' ? resp.result as string : JSON.stringify(resp.result);
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw httpError(resp.responseCode, text);
    }
    return text;
  } catch (e) {
    if (handle.aborted) {
      throw new ChatError('已停止生成', true);
    }
    if (e instanceof ChatError) {
      throw e;
    }
    throw networkError(e as BusinessError);
  } finally {
    handle.req = null;
    try {
      req.destroy();
    } catch (e2) {
      // 忽略清理异常
    }
  }
}