import { httpJsonRequest } from './HttpStream';
import { ProviderSettings, ChatError } from '../types/Types';

// 搜索结果项
export interface SearchResultItem {
  title: string;
  url: string;
  snippet: string;
  content?: string;
}

// 搜索响应
interface SearchResponse {
  results: SearchResultItem[];
  total?: number;
}

// 抓取响应
interface FetchResponse {
  content: string;
  title?: string;
  url?: string;
}

// 工具执行结果
export interface ToolResult {
  success: boolean;
  data?: string;
  error?: string;
}

export class DeepSeekTools {
  private apiKey?: string;
  private baseUrl: string;
  
  constructor(settings?: ProviderSettings) {
    this.apiKey = settings?.apiKey;
    this.baseUrl = settings?.baseUrl || 'https://api.deepseek.com';
  }
  
  // 检查是否配置了DeepSeek API Key
  isAvailable(): boolean {
    return !!this.apiKey && this.apiKey.trim().length > 0;
  }
  
  // 执行搜索
  async search(query: string, count: number = 5): Promise<ToolResult> {
    if (!this.isAvailable()) {
      return {
        success: false,
        error: '未配置 DeepSeek API Key，无法使用搜索功能'
      };
    }
    
    try {
      const response = await httpJsonRequest<SearchResponse>({
        url: `${this.baseUrl}/v1/tools/search`,
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          query,
          count,
          need_content: true
        }),
        timeout: 30000
      });
      
      if (!response.results || response.results.length === 0) {
        return {
          success: true,
          data: '未找到相关结果'
        };
      }
      
      // 格式化搜索结果(给模型看的完整版本)
      const formatted = response.results.map((item, idx) => {
        let text = `${idx + 1}. ${item.title}\n   URL: ${item.url}\n   摘要: ${item.snippet}`;
        if (item.content) {
          // 限制内容长度，避免token过多
          const content = item.content.length > 2000 
            ? item.content.substring(0, 2000) + '...' 
            : item.content;
          text += `\n   内容:\n${content}`;
        }
        return text;
      }).join('\n\n');
      
      return {
        success: true,
        data: formatted
      };
      
    } catch (error) {
      if (error instanceof ChatError) {
        return {
          success: false,
          error: error.message
        };
      }
      return {
        success: false,
        error: `搜索失败: ${(error as Error).message}`
      };
    }
  }
  
  // 抓取网页内容
  async fetch(url: string): Promise<ToolResult> {
    if (!this.isAvailable()) {
      return {
        success: false,
        error: '未配置 DeepSeek API Key，无法使用抓取功能'
      };
    }
    
    try {
      const response = await httpJsonRequest<FetchResponse>({
        url: `${this.baseUrl}/v1/tools/fetch`,
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ url }),
        timeout: 60000
      });
      
      if (!response.content) {
        return {
          success: true,
          data: '页面内容为空'
        };
      }
      
      // 限制内容长度
      let content = response.content;
      if (content.length > 8000) {
        content = content.substring(0, 8000) + '\n\n[内容已截断]';
      }
      
      const formatted = response.title 
        ? `标题: ${response.title}\nURL: ${url}\n\n${content}`
        : `URL: ${url}\n\n${content}`;
      
      return {
        success: true,
        data: formatted
      };
      
    } catch (error) {
      if (error instanceof ChatError) {
        return {
          success: false,
          error: error.message
        };
      }
      return {
        success: false,
        error: `抓取失败: ${(error as Error).message}`
      };
    }
  }
  
  // 执行工具调用
  async executeTool(type: 'search' | 'fetch', args: string): Promise<ToolResult> {
    try {
      const parsedArgs = JSON.parse(args);
      
      if (type === 'search') {
        const query = parsedArgs.query;
        if (!query) {
          return {
            success: false,
            error: '搜索缺少 query 参数'
          };
        }
        return await this.search(query, parsedArgs.count || 5);
        
      } else if (type === 'fetch') {
        const url = parsedArgs.url;
        if (!url) {
          return {
            success: false,
            error: '抓取缺少 url 参数'
          };
        }
        return await this.fetch(url);
        
      } else {
        return {
          success: false,
          error: `未知工具类型: ${type}`
        };
      }
      
    } catch (error) {
      return {
        success: false,
        error: `参数解析失败: ${(error as Error).message}`
      };
    }
  }
  
  // 生成工具调用的用户友好摘要(显示在UI上)
  static getToolCallSummary(type: 'search' | 'fetch', args: string): string {
    try {
      const parsedArgs = JSON.parse(args);
      
      if (type === 'search') {
        return `搜索: ${parsedArgs.query || '(无关键词)'}`;
      } else if (type === 'fetch') {
        const url = parsedArgs.url || '';
        // 只显示域名
        try {
          const urlObj = new URL(url);
          return `抓取: ${urlObj.hostname}`;
        } catch {
          return `抓取: ${url.substring(0, 50)}`;
        }
      }
      
      return `执行工具: ${type}`;
      
    } catch {
      return `执行工具: ${type}`;
    }
  }
  
  // 生成工具结果的简短摘要(显示在UI上)
  static getResultSummary(result: ToolResult): string {
    if (!result.success) {
      return `失败: ${result.error || '未知错误'}`;
    }
    
    if (!result.data) {
      return '完成';
    }
    
    // 显示前100个字符
    const preview = result.data.length > 100 
      ? result.data.substring(0, 100) + '...' 
      : result.data;
    
    return preview.replace(/\n/g, ' ');
  }
}
