import http from '@ohos.net.http';
import util from '@ohos.util';
import { ChatError } from '../types/Types';

// HTTP请求选项
export interface HttpRequestOptions {
  url: string;
  method: 'GET' | 'POST' | 'PUT' | 'DELETE';
  headers?: Record<string, string>;
  body?: string;
  timeout?: number;
}

// SSE事件
export interface SseEvent {
  event?: string;
  data: string;
  id?: string;
  retry?: number;
}

// SSE解析器 - 处理跨分片的SSE事件
export class SseParser {
  private buffer: string = '';
  
  // 处理新的数据块，返回完整的SSE事件
  parse(chunk: string): SseEvent[] {
    this.buffer += chunk;
    const events: SseEvent[] = [];
    
    // SSE事件由双换行分隔
    let eventEnd: number;
    while ((eventEnd = this.findEventEnd(this.buffer)) !== -1) {
      const eventStr = this.buffer.substring(0, eventEnd);
      this.buffer = this.buffer.substring(eventEnd).replace(/^(\r\n|\n\r|\n|\r){1,2}/, '');
      
      const event = this.parseEvent(eventStr);
      if (event && event.data) {
        events.push(event);
      }
    }
    
    return events;
  }
  
  // 查找事件结束位置(双换行)
  private findEventEnd(str: string): number {
    const patterns = ['\n\n', '\r\n\r\n', '\r\r', '\n\r\n'];
    let minIndex = -1;
    
    for (const pattern of patterns) {
      const idx = str.indexOf(pattern);
      if (idx !== -1 && (minIndex === -1 || idx < minIndex)) {
        minIndex = idx;
      }
    }
    
    return minIndex;
  }
  
  // 解析单个SSE事件
  private parseEvent(eventStr: string): SseEvent | null {
    const lines = eventStr.split(/\r?\n/);
    const event: SseEvent = { data: '' };
    const dataLines: string[] = [];
    
    for (const line of lines) {
      if (line.startsWith(':')) {
        // 注释行，忽略
        continue;
      }
      
      const colonIdx = line.indexOf(':');
      let field: string;
      let value: string;
      
      if (colonIdx === -1) {
        field = line;
        value = '';
      } else {
        field = line.substring(0, colonIdx);
        value = line.substring(colonIdx + 1).trimStart();
      }
      
      switch (field) {
        case 'event':
          event.event = value;
          break;
        case 'data':
          dataLines.push(value);
          break;
        case 'id':
          event.id = value;
          break;
        case 'retry':
          event.retry = parseInt(value, 10);
          break;
      }
    }
    
    if (dataLines.length > 0) {
      event.data = dataLines.join('\n');
    }
    
    return dataLines.length > 0 || event.event ? event : null;
  }
  
  // 获取缓冲区剩余内容(用于连接结束时)
  flush(): SseEvent | null {
    if (this.buffer.trim()) {
      const event = this.parseEvent(this.buffer);
      this.buffer = '';
      return event;
    }
    return null;
  }
  
  // 重置解析器
  reset(): void {
    this.buffer = '';
  }
}

// 流式HTTP请求回调
export interface StreamCallbacks {
  onData: (chunk: string) => void;
  onComplete?: () => void;
  onError?: (error: Error) => void;
}

// 真正的流式HTTP请求(使用HarmonyOS的requestInStream)
export function httpStreamRequest(
  options: HttpRequestOptions,
  callbacks: StreamCallbacks,
  abortSignal?: { aborted: boolean }
): Promise<void> {
  return new Promise((resolve, reject) => {
    const httpRequest = http.createHttp();
    const parser = new SseParser();
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    
    let hasError = false;
    let completed = false;
    
    // 检查中止
    if (abortSignal?.aborted) {
      httpRequest.destroy();
      reject(ChatError.stopped());
      return;
    }
    
    // 监听数据接收
    httpRequest.on('dataReceive', (data: ArrayBuffer) => {
      if (abortSignal?.aborted || hasError) {
        return;
      }
      
      try {
        // 使用流式解码处理UTF-8跨分片
        const text = decoder.decodeToString(new Uint8Array(data), { stream: true });
        
        // 解析SSE事件
        const events = parser.parse(text);
        
        for (const event of events) {
          if (abortSignal?.aborted) {
            return;
          }
          callbacks.onData(event.data);
        }
      } catch (error) {
        hasError = true;
        const chatError = ChatError.parseError((error as Error).message);
        callbacks.onError?.(chatError);
        httpRequest.destroy();
        reject(chatError);
      }
    });
    
    // 监听数据接收完成
    httpRequest.on('dataEnd', () => {
      if (hasError || completed) {
        return;
      }
      
      completed = true;
      
      try {
        // 处理缓冲区剩余内容
        const remaining = parser.flush();
        if (remaining && remaining.data) {
          callbacks.onData(remaining.data);
        }
        
        callbacks.onComplete?.();
        httpRequest.destroy();
        resolve();
      } catch (error) {
        httpRequest.destroy();
        reject(error);
      }
    });
    
    // 监听错误
    httpRequest.on('error', (error: Error) => {
      if (hasError || completed) {
        return;
      }
      
      hasError = true;
      const chatError = ChatError.networkError(error.message);
      callbacks.onError?.(chatError);
      httpRequest.destroy();
      reject(chatError);
    });
    
    // 发起流式请求
    httpRequest.requestInStream(
      options.url,
      {
        method: options.method === 'POST' ? http.RequestMethod.POST :
                options.method === 'PUT' ? http.RequestMethod.PUT :
                options.method === 'DELETE' ? http.RequestMethod.DELETE :
                http.RequestMethod.GET,
        header: {
          'Accept': 'text/event-stream',
          'Cache-Control': 'no-cache',
          ...(options.headers || {})
        },
        extraData: options.body,
        readTimeout: options.timeout || 300000,
        connectTimeout: 30000
      }
    ).then((responseCode: number) => {
      // 检查HTTP状态码
      if (responseCode !== 200) {
        hasError = true;
        
        // 特殊处理常见错误
        let error: ChatError;
        if (responseCode === 401 || responseCode === 403) {
          error = ChatError.invalidApiKey('deepseek');
        } else if (responseCode === 429) {
          error = ChatError.rateLimited('deepseek');
        } else {
          error = new ChatError(`HTTP ${responseCode}`, 'HTTP_ERROR');
        }
        
        callbacks.onError?.(error);
        httpRequest.destroy();
        reject(error);
      }
    }).catch((error: Error) => {
      if (!hasError && !completed) {
        hasError = true;
        const chatError = ChatError.networkError(error.message);
        callbacks.onError?.(chatError);
        httpRequest.destroy();
        reject(chatError);
      }
    });
  });
}

// 普通JSON请求
export async function httpJsonRequest<T = any>(
  options: HttpRequestOptions
): Promise<T> {
  const httpRequest = http.createHttp();
  
  try {
    const response = await httpRequest.request(
      options.url,
      {
        method: options.method === 'POST' ? http.RequestMethod.POST :
                options.method === 'PUT' ? http.RequestMethod.PUT :
                options.method === 'DELETE' ? http.RequestMethod.DELETE :
                http.RequestMethod.GET,
        header: {
          'Content-Type': 'application/json',
          ...(options.headers || {})
        },
        extraData: options.body,
        readTimeout: options.timeout || 60000,
        connectTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      }
    );
    
    if (response.responseCode !== 200) {
      const errorBody = response.result as string;
      let errorMessage = `HTTP ${response.responseCode}`;
      
      try {
        const errorJson = JSON.parse(errorBody);
        if (errorJson.error?.message) {
          errorMessage = errorJson.error.message;
        } else if (errorJson.message) {
          errorMessage = errorJson.message;
        }
      } catch {
        if (errorBody) {
          errorMessage = errorBody.substring(0, 200);
        }
      }
      
      throw new ChatError(errorMessage, 'HTTP_ERROR');
    }
    
    const responseBody = response.result as string;
    try {
      return JSON.parse(responseBody) as T;
    } catch {
      throw ChatError.parseError('无法解析JSON响应');
    }
    
  } catch (error) {
    if (error instanceof ChatError) {
      throw error;
    }
    throw ChatError.networkError((error as Error).message);
  } finally {
    httpRequest.destroy();
  }
}
