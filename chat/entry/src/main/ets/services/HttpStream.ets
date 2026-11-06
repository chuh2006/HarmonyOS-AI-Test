import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ChatError, ProviderId } from '../types/Types';

// HTTP请求选项
export interface HttpRequestOptions {
  url: string;
  method: 'GET' | 'POST' | 'PUT' | 'DELETE';
  headers?: Record<string, string>;
  body?: string;
  timeout?: number;
  provider?: ProviderId;
}

// SSE事件
export interface SseEvent {
  event?: string;
  data: string;
  id?: string;
}

// SSE解析器 - 处理跨分片的SSE事件
export class SseParser {
  private buffer: string = '';

  // 处理新的数据块，返回完整的SSE事件
  parse(chunk: string): SseEvent[] {
    this.buffer += chunk;
    const events: SseEvent[] = [];

    // SSE事件由空行(双换行)分隔，兼容LF/CRLF
    let eventEnd: number = this.findEventEnd(this.buffer);
    while (eventEnd !== -1) {
      const eventStr: string = this.buffer.substring(0, eventEnd);
      // 跳过事件分隔符(\n\n 或 \r\n\r\n)
      let skipLen: number = 2;
      if (this.buffer.startsWith('\r\n\r\n', eventEnd)) {
        skipLen = 4;
      }
      this.buffer = this.buffer.substring(eventEnd + skipLen);

      const event: SseEvent | null = this.parseEvent(eventStr);
      if (event !== null) {
        events.push(event);
      }
      eventEnd = this.findEventEnd(this.buffer);
    }

    return events;
  }

  // 查找事件结束位置(第一个空行)
  private findEventEnd(str: string): number {
    const lfLf: number = str.indexOf('\n\n');
    const crlfCrlf: number = str.indexOf('\r\n\r\n');
    if (lfLf === -1) {
      return crlfCrlf;
    }
    if (crlfCrlf === -1) {
      return lfLf;
    }
    return lfLf < crlfCrlf ? lfLf : crlfCrlf;
  }

  // 解析单个SSE事件
  private parseEvent(eventStr: string): SseEvent | null {
    const lines: string[] = eventStr.split('\n');
    let eventName: string | undefined = undefined;
    let eventId: string | undefined = undefined;
    const dataLines: string[] = [];

    for (const rawLine of lines) {
      const line: string = rawLine.endsWith('\r') ? rawLine.substring(0, rawLine.length - 1) : rawLine;
      if (line.length === 0 || line.startsWith(':')) {
        continue; // 空行或注释行
      }

      const colonIdx: number = line.indexOf(':');
      let field: string;
      let value: string;

      if (colonIdx === -1) {
        field = line;
        value = '';
      } else {
        field = line.substring(0, colonIdx);
        // 规范: 冒号后如有一个空格应去掉
        value = line.substring(colonIdx + 1);
        if (value.startsWith(' ')) {
          value = value.substring(1);
        }
      }

      if (field === 'event') {
        eventName = value;
      } else if (field === 'data') {
        dataLines.push(value);
      } else if (field === 'id') {
        eventId = value;
      }
    }

    if (dataLines.length === 0 && eventName === undefined) {
      return null;
    }

    const event: SseEvent = {
      data: dataLines.join('\n'),
      event: eventName,
      id: eventId
    };
    return event;
  }

  // 获取缓冲区剩余内容(连接结束时调用，避免丢失最后一帧)
  flush(): SseEvent | null {
    if (this.buffer.trim().length === 0) {
      this.buffer = '';
      return null;
    }
    const event: SseEvent | null = this.parseEvent(this.buffer);
    this.buffer = '';
    return event;
  }

  reset(): void {
    this.buffer = '';
  }
}

// 流式HTTP请求回调
export interface StreamCallbacks {
  onData: (chunk: string) => void;
  onComplete: () => void;
  onError: (error: ChatError) => void;
}

// 中止信号
export interface AbortSignal {
  aborted: boolean;
}

// 转换HTTP方法
function toRequestMethod(method: string): http.RequestMethod {
  if (method === 'POST') {
    return http.RequestMethod.POST;
  }
  if (method === 'PUT') {
    return http.RequestMethod.PUT;
  }
  if (method === 'DELETE') {
    return http.RequestMethod.DELETE;
  }
  return http.RequestMethod.GET;
}

// 构建请求头(合并默认SSE头)
function buildHeaders(custom: Record<string, string> | undefined): Record<string, string> {
  const headers: Record<string, string> = {
    'Accept': 'text/event-stream',
    'Cache-Control': 'no-cache'
  };
  if (custom !== undefined) {
    const keys: string[] = Object.keys(custom);
    for (const key of keys) {
      headers[key] = custom[key];
    }
  }
  return headers;
}

// 构建请求选项
function buildRequestOptions(options: HttpRequestOptions): http.HttpRequestOptions {
  const reqOptions: http.HttpRequestOptions = {
    method: toRequestMethod(options.method),
    header: buildHeaders(options.headers),
    readTimeout: options.timeout !== undefined ? options.timeout : 300000,
    connectTimeout: 30000,
    expectDataType: http.HttpDataType.ARRAY_BUFFER
  };
  if (options.body !== undefined) {
    reqOptions.extraData = options.body;
  }
  return reqOptions;
}

// 抛出物不一定是Error实例，统一取可读文本
export function thrownMessage(value: Object, fallback: string): string {
  if (value instanceof Error && value.message.length > 0) {
    return value.message;
  }
  if (typeof value === 'string' && (value as string).length > 0) {
    return value as string;
  }
  return fallback;
}

// 真正的流式HTTP请求：
// 使用 requestInStream + on('dataReceive') 实时接收数据块，
// 用 TextDecoder(stream:true) 处理UTF-8跨分片，SseParser处理SSE事件跨分片。
//
// 非200响应的响应体不是SSE，必须整体缓冲后解析出服务端错误信息；
// 状态码(dataReceive之前或之后到达都可能)与 dataEnd 两者齐备才能收尾，
// 否则错误会被当成正常结束而静默丢失。
export function httpStreamRequest(
  options: HttpRequestOptions,
  callbacks: StreamCallbacks,
  abortSignal?: AbortSignal
): void {
  const httpRequest: http.HttpRequest = http.createHttp();
  const parser: SseParser = new SseParser();
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });

  let settled: boolean = false;
  let statusCode: number = 0; // 0表示状态码尚未到达
  let ended: boolean = false;
  let pendingRaw: string = ''; // 状态码未知前先原样暂存
  let errorBody: string = '';
  const provider: ProviderId | undefined = options.provider;

  const cleanup = (): void => {
    try {
      httpRequest.off('dataReceive');
      httpRequest.off('dataEnd');
    } catch (e) {
      // 忽略off失败
    }
    httpRequest.destroy();
  };

  const failWith = (err: ChatError): void => {
    if (settled) {
      return;
    }
    settled = true;
    cleanup();
    callbacks.onError(err);
  };

  // 按当前状态码分发一段已解码文本
  const handleText = (text: string): void => {
    if (settled) {
      return;
    }
    if (statusCode === 0) {
      pendingRaw += text;
      return;
    }
    if (statusCode !== 200) {
      errorBody += text;
      return;
    }
    try {
      const events: SseEvent[] = parser.parse(text);
      for (const event of events) {
        if (settled) {
          return;
        }
        callbacks.onData(event.data);
      }
    } catch (e) {
      failWith(ChatError.parseError(thrownMessage(e as Object, '数据解析失败')));
    }
  };

  // 状态码与数据流都到位后才能决定成功或失败
  const finish = (): void => {
    if (settled || !ended || statusCode === 0) {
      return;
    }
    if (statusCode !== 200) {
      settled = true;
      cleanup();
      callbacks.onError(ChatError.httpError(statusCode, extractErrorMessage(errorBody), provider));
      return;
    }
    settled = true;
    try {
      const remaining: SseEvent | null = parser.flush();
      if (remaining !== null && remaining.data.length > 0) {
        callbacks.onData(remaining.data);
      }
    } catch (e) {
      // 忽略flush错误
    }
    cleanup();
    callbacks.onComplete();
  };

  if (abortSignal !== undefined && abortSignal.aborted) {
    callbacks.onError(ChatError.stopped());
    httpRequest.destroy();
    return;
  }

  // 实时接收数据块
  httpRequest.on('dataReceive', (data: ArrayBuffer) => {
    if (settled) {
      return;
    }
    if (abortSignal !== undefined && abortSignal.aborted) {
      failWith(ChatError.stopped());
      return;
    }
    let text: string = '';
    try {
      // stream:true 保证多字节UTF-8字符跨分片时不产生乱码
      const decodeOptions: util.DecodeToStringOptions = { stream: true };
      text = decoder.decodeToString(new Uint8Array(data), decodeOptions);
    } catch (e) {
      failWith(ChatError.parseError(thrownMessage(e as Object, '数据解码失败')));
      return;
    }
    handleText(text);
  });

  httpRequest.on('dataEnd', () => {
    if (settled) {
      return;
    }
    ended = true;
    finish();
  });

  // 发起流式请求；错误通过Promise rejection处理(SDK无'error'事件)
  httpRequest.requestInStream(options.url, buildRequestOptions(options))
    .then((responseCode: number) => {
      statusCode = responseCode;
      if (pendingRaw.length > 0) {
        const raw: string = pendingRaw;
        pendingRaw = '';
        handleText(raw);
      }
      finish();
    })
    .catch((err: Error) => {
      if (abortSignal !== undefined && abortSignal.aborted) {
        failWith(ChatError.stopped());
        return;
      }
      failWith(ChatError.networkError(thrownMessage(err as Object, '连接失败')));
    });
}

// 普通JSON请求
export interface JsonResponse {
  statusCode: number;
  body: string;
}

export function httpJsonRequest(
  options: HttpRequestOptions,
  onResult: (response: JsonResponse) => void,
  onError: (error: ChatError) => void
): void {
  const httpRequest: http.HttpRequest = http.createHttp();
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (options.headers !== undefined) {
    const keys: string[] = Object.keys(options.headers);
    for (const key of keys) {
      headers[key] = options.headers[key];
    }
  }

  const reqOptions: http.HttpRequestOptions = {
    method: toRequestMethod(options.method),
    header: headers,
    readTimeout: options.timeout !== undefined ? options.timeout : 60000,
    connectTimeout: 30000,
    expectDataType: http.HttpDataType.STRING
  };
  if (options.body !== undefined) {
    reqOptions.extraData = options.body;
  }

  httpRequest.request(options.url, reqOptions)
    .then((response: http.HttpResponse) => {
      httpRequest.destroy();
      const body: string = typeof response.result === 'string' ? response.result : '';
      const result: JsonResponse = { statusCode: response.responseCode, body: body };
      onResult(result);
    })
    .catch((err: Error) => {
      httpRequest.destroy();
      onError(ChatError.networkError(thrownMessage(err as Object, '连接失败')));
    });
}

// 从错误响应体提取错误信息
// 各家服务端字段形状不同(error对象/error字符串/message/detail)，
// 且常带显式 null(如 OpenAI 的 "error": null、Mercury 的 "param": null)，
// 只判 undefined 会直接抛 TypeError。
export function extractErrorMessage(body: string): string {
  const trimmed: string = body.trim();
  if (trimmed.length === 0) {
    return '服务端未返回错误详情';
  }
  try {
    const parsed: Object = JSON.parse(trimmed) as Object;
    const message: string = readErrorText(parsed);
    if (message.length > 0) {
      return message;
    }
  } catch (e) {
    // 非JSON响应体
  }
  return truncateText(trimmed, 300);
}

function truncateText(text: string, limit: number): string {
  return text.length > limit ? `${text.substring(0, limit)}...` : text;
}

function isRecordValue(value: Object | undefined | null): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function readStringField(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key];
  if (value !== undefined && value !== null && typeof value === 'string') {
    return value as string;
  }
  return '';
}

// 逐层查找 message：{error:{message}} / {error:"..."} / {message} / {detail}
function readErrorText(parsed: Object | undefined | null): string {
  if (!isRecordValue(parsed)) {
    return '';
  }
  const root: Record<string, Object> = parsed as Record<string, Object>;
  const errorValue: Object | undefined = root['error'];

  if (errorValue !== undefined && errorValue !== null && typeof errorValue === 'string') {
    return errorValue as string;
  }
  if (isRecordValue(errorValue)) {
    const errorRecord: Record<string, Object> = errorValue as Record<string, Object>;
    const message: string = readStringField(errorRecord, 'message');
    if (message.length > 0) {
      const code: string = readStringField(errorRecord, 'code');
      return code.length > 0 ? `${message} (${code})` : message;
    }
  }

  const directMessage: string = readStringField(root, 'message');
  if (directMessage.length > 0) {
    return directMessage;
  }
  const detailValue: Object | undefined = root['detail'];
  if (detailValue !== undefined && detailValue !== null && typeof detailValue === 'string') {
    return detailValue as string;
  }
  return '';
}
