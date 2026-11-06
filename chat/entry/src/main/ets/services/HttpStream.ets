import http from '@ohos.net.http';
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

// HTTP流式请求回调
export interface StreamCallbacks {
  onData: (chunk: string) => void;
  onComplete?: () => void;
  onError?: (error: Error) => void;
}

// 流式HTTP请求(用于SSE)
export async function httpStreamRequest(
  options: HttpRequestOptions,
  callbacks: StreamCallbacks,
  abortSignal?: { aborted: boolean }
): Promise<void> {
  const httpRequest = http.createHttp();
  
  try {
    // 检查是否已中止
    if (abortSignal?.aborted) {
      throw ChatError.stopped();
    }
    
    const response = await httpRequest.request(
      options.url,
      {
        method: options.method === 'POST' ? http.RequestMethod.POST :
                options.method === 'PUT' ? http.RequestMethod.PUT :
                options.method === 'DELETE' ? http.RequestMethod.DELETE :
                http.RequestMethod.GET,
        header: options.headers || {},
        extraData: options.body,
        readTimeout: options.timeout || 300000,
        connectTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      }
    );
    
    if (abortSignal?.aborted) {
      throw ChatError.stopped();
    }
    
    // 检查HTTP状态码
    if (response.responseCode !== 200) {
      const errorBody = response.result as string;
      let errorMessage = `HTTP ${response.responseCode}`;
      
      try {
        const errorJson = JSON.parse(errorBody);
        if (errorJson.error?.message) {
          errorMessage = errorJson.error.message;
        }
      } catch {
        if (errorBody) {
          errorMessage = errorBody.substring(0, 200);
        }
      }
      
      // 特殊处理常见错误
      if (response.responseCode === 401 || response.responseCode === 403) {
        throw ChatError.invalidApiKey('deepseek'); // 会在provider中被覆盖
      } else if (response.responseCode === 429) {
        throw ChatError.rateLimited('deepseek');
      } else {
        throw new ChatError(errorMessage, 'HTTP_ERROR');
      }
    }
    
    // HarmonyOS的http模块不支持真正的流式读取
    // 我们需要使用on('dataReceive')事件或分段读取
    // 这里简化处理，直接返回完整响应
    const fullResponse = response.result as string;
    
    // 按SSE格式分割并逐个处理
    const parser = new SseParser();
    const events = parser.parse(fullResponse);
    
    for (const event of events) {
      if (abortSignal?.aborted) {
        throw ChatError.stopped();
      }
      callbacks.onData(event.data);
    }
    
    // 处理缓冲区剩余内容
    const remaining = parser.flush();
    if (remaining && remaining.data) {
      callbacks.onData(remaining.data);
    }
    
    callbacks.onComplete?.();
    
  } catch (error) {
    if (error instanceof ChatError) {
      callbacks.onError?.(error);
      throw error;
    }
    
    const chatError = ChatError.networkError((error as Error).message);
    callbacks.onError?.(chatError);
    throw chatError;
    
  } finally {
    httpRequest.destroy();
  }
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
