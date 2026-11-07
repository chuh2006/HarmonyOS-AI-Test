import { httpJsonRequest, extractErrorMessage, JsonResponse, HttpRequestOptions } from './HttpStream';
import { recordOrNull } from './Json';
import { ChatError, ProviderSettings, ToolType } from '../types/Types';

// 工具执行结果
// data 给模型(完整内容)，summary 给用户(一句话，不含搜索结果正文)
export interface ToolResult {
  success: boolean;
  data?: string;
  summary?: string;
  error?: string;
}

// 搜索结果项(给模型看的完整内容)
export interface SearchResultItem {
  title: string;
  url: string;
  snippet: string;
  content?: string;
}

function toRecord(value: Object): Record<string, Object> {
  return value as Record<string, Object>;
}

function isRecord(value: Object | undefined): boolean {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value !== 'object') {
    return false;
  }
  return !Array.isArray(value);
}

function readString(obj: Record<string, Object>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value: Object | undefined = obj[key];
    if (value !== undefined && value !== null && typeof value === 'string') {
      return value as string;
    }
  }
  return undefined;
}

// readString 的空值版本，字段缺失时返回空串
function text(obj: Record<string, Object>, keys: string[]): string {
  const value: string | undefined = readString(obj, keys);
  return value !== undefined ? value : '';
}

function readNumber(obj: Record<string, Object>, key: string): number | undefined {
  const value: Object | undefined = obj[key];
  if (value !== undefined && value !== null && typeof value === 'number') {
    return value as number;
  }
  return undefined;
}

function readArray(obj: Record<string, Object>, keys: string[]): Object[] | undefined {
  for (const key of keys) {
    const value: Object | undefined = obj[key];
    if (value !== undefined && value !== null && Array.isArray(value)) {
      return value as Object[];
    }
  }
  return undefined;
}

// 在响应中定位结果数组(兼容直接返回或包在 data 字段里)
function findResultArray(root: Record<string, Object>): Object[] | undefined {
  const direct: Object[] | undefined = readArray(root, ['results', 'result', 'items', 'search_results']);
  if (direct !== undefined) {
    return direct;
  }
  const dataValue: Object | undefined = root['data'];
  if (dataValue !== undefined && Array.isArray(dataValue)) {
    return dataValue as Object[];
  }
  if (dataValue !== undefined && isRecord(dataValue)) {
    return readArray(toRecord(dataValue), ['results', 'result', 'items', 'search_results']);
  }
  return undefined;
}

function truncate(text: string, limit: number, suffix: string): string {
  if (text.length > limit) {
    return text.substring(0, limit) + suffix;
  }
  return text;
}

// 提取域名(ArkTS环境无URL类，手动解析)
export function extractHostname(url: string): string {
  let rest: string = url.trim();
  const schemeIdx: number = rest.indexOf('://');
  if (schemeIdx !== -1) {
    rest = rest.substring(schemeIdx + 3);
  }
  const slashIdx: number = rest.indexOf('/');
  if (slashIdx !== -1) {
    rest = rest.substring(0, slashIdx);
  }
  const questionIdx: number = rest.indexOf('?');
  if (questionIdx !== -1) {
    rest = rest.substring(0, questionIdx);
  }
  const atIdx: number = rest.indexOf('@');
  if (atIdx !== -1) {
    rest = rest.substring(atIdx + 1);
  }
  return rest.length > 0 ? rest : url;
}

function isWrapChar(char: string): boolean {
  return '<>"\'`()[]{}，。、；'.indexOf(char) !== -1;
}

// 模型给出的地址常带引号/括号/Markdown 包裹或缺协议。
// 官方要求: 必须是含 host 的 HTTP/HTTPS 地址，不能携带用户名或密码，长度不超过 8192。
export function normalizeFetchUrl(raw: string): string {
  let value: string = raw.trim();
  if (value.length === 0) {
    return '';
  }

  // Markdown 链接 [文本](地址)
  const openIdx: number = value.indexOf('](');
  if (openIdx !== -1) {
    const rest: string = value.substring(openIdx + 2);
    const closeIdx: number = rest.indexOf(')');
    value = closeIdx !== -1 ? rest.substring(0, closeIdx) : rest;
  }

  // 截到第一个空白处
  for (let i = 0; i < value.length; i++) {
    const char: string = value.charAt(i);
    if (char === ' ' || char === '\n' || char === '\r' || char === '\t') {
      value = value.substring(0, i);
      break;
    }
  }

  while (value.length > 0 && isWrapChar(value.charAt(0))) {
    value = value.substring(1);
  }
  while (value.length > 0 && isWrapChar(value.charAt(value.length - 1))) {
    value = value.substring(0, value.length - 1);
  }
  if (value.length === 0) {
    return '';
  }

  const lower: string = value.toLowerCase();
  if (lower.startsWith('//')) {
    value = `https:${value}`;
  } else if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    value = `https://${value}`;
  }

  // 校验 authority: 必须有 host 且不能带用户名密码
  const schemeIdx: number = value.indexOf('://');
  let authority: string = value.substring(schemeIdx + 3);
  const slashIdx: number = authority.indexOf('/');
  if (slashIdx !== -1) {
    authority = authority.substring(0, slashIdx);
  }
  if (authority.length === 0 || authority.indexOf('@') !== -1 || authority.indexOf('.') === -1) {
    return '';
  }
  if (value.length > 8192) {
    return '';
  }
  return value;
}

// DeepSeek 的 search / fetch 工具，四个服务商共用
export class DeepSeekTools {
  private apiKey: string;
  private baseUrl: string;

  constructor(settings?: ProviderSettings) {
    this.apiKey = settings !== undefined && settings.apiKey !== undefined ? settings.apiKey : '';
    let base: string = settings !== undefined && settings.baseUrl !== undefined && settings.baseUrl.length > 0
      ? settings.baseUrl : 'https://api.deepseek.com';
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    // 对话用的是 /anthropic 子路径，而 search/fetch 在根路径的 /v1/tools 下，
    // 用户按官方文档填了带 /anthropic 的地址时要去掉，否则会 404
    if (base.endsWith('/anthropic')) {
      base = base.substring(0, base.length - '/anthropic'.length);
    }
    this.baseUrl = base;
  }

  isAvailable(): boolean {
    return this.apiKey.trim().length > 0;
  }

  private static fail(message: string): ToolResult {
    const result: ToolResult = { success: false, error: message, summary: message };
    return result;
  }

  private static ok(data: string, summary: string): ToolResult {
    const result: ToolResult = { success: true, data: data, summary: summary };
    return result;
  }

  private request(endpoint: string, body: string, timeout: number): Promise<JsonResponse> {
    return new Promise<JsonResponse>((resolve: (value: JsonResponse) => void, reject: (reason: ChatError) => void) => {
      const headers: Record<string, string> = {
        'Authorization': `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json'
      };
      const options: HttpRequestOptions = {
        url: `${this.baseUrl}${endpoint}`,
        method: 'POST',
        headers: headers,
        body: body,
        timeout: timeout
      };
      httpJsonRequest(options, resolve, (error: ChatError) => {
        reject(error);
      });
    });
  }

  // 搜索：给模型返回标题/链接/来源/长摘要/正文，正文限制长度避免token爆炸
  search(query: string, count: number): Promise<ToolResult> {
    if (!this.isAvailable()) {
      return Promise.resolve(DeepSeekTools.fail('未配置 DeepSeek API Key，搜索与抓取工具不可用'));
    }

    // 官方限制: query 为 1~128 个字符，count 取值 1~50
    const safeQuery: string = query.trim().substring(0, Math.min(query.trim().length, 128));
    if (safeQuery.length === 0) {
      return Promise.resolve(DeepSeekTools.fail('搜索词为空'));
    }
    let safeCount: number = Math.round(count);
    if (!(safeCount >= 1)) {
      safeCount = 1;
    }
    if (safeCount > 50) {
      safeCount = 50;
    }

    const payload: Record<string, Object> = {
      'query': safeQuery,
      'count': safeCount,
      'need_content': true
    };

    return this.request('/v1/tools/search', JSON.stringify(payload), 30000)
      .then((response: JsonResponse) => {
        if (response.statusCode !== 200) {
          return DeepSeekTools.fail(`搜索请求失败: ${extractErrorMessage(response.body)}`);
        }
        return this.parseSearchResponse(response.body);
      })
      .catch((error: Error) => DeepSeekTools.fail(`搜索失败: ${error.message}`));
  }

  // 官方字段语义: snippet 是 100~200 字给前端展示，summary 是 600~800 字给模型阅读，
  // rerank_score>=1.5 为优质结果，authority>=3 为极权威来源。给模型的必须是后者，
  // 只给 snippet 会让模型认为拿不到有效信息而反复重搜。
  private parseSearchResponse(body: string): ToolResult {
    let root: Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(body) as Object;
      const record: Record<string, Object> | null = recordOrNull(parsed);
      if (record === null) {
        return DeepSeekTools.fail('搜索结果格式异常');
      }
      root = record;
    } catch (e) {
      return DeepSeekTools.fail('搜索结果解析失败');
    }

    const rawItems: Object[] | undefined = findResultArray(root);
    if (rawItems === undefined || rawItems.length === 0) {
      return DeepSeekTools.ok('未找到相关结果', '没有找到相关结果');
    }

    const sections: string[] = [];
    let index: number = 1;

    for (const raw of rawItems) {
      const obj: Record<string, Object> | null = recordOrNull(raw);
      if (obj === null) {
        continue;
      }
      const title: string = text(obj, ['title', 'name']).length > 0 ? text(obj, ['title', 'name']) : '(无标题)';
      const url: string = text(obj, ['url', 'link', 'href']);
      // summary 是给模型读的长摘要(600~800字)，缺失时才退回给前端用的短摘要
      const summary: string = text(obj, ['summary']).length > 0
        ? text(obj, ['summary'])
        : text(obj, ['snippet', 'description', 'abstract']);
      const content: string = text(obj, ['content', 'text', 'page_content', 'markdown']);

      let section: string = `${index}. ${title}\n   URL: ${url}`;

      const meta: string[] = [];
      const siteName: string = text(obj, ['site_name']);
      if (siteName.length > 0) {
        meta.push(`来源: ${siteName}`);
      }
      const date: string = text(obj, ['date']);
      if (date.length > 0) {
        meta.push(`发布: ${date}`);
      }
      const score: number | undefined = readNumber(obj, 'rerank_score');
      if (score !== undefined) {
        meta.push(`相关性: ${score.toFixed(1)}`);
      }
      const authority: number | undefined = readNumber(obj, 'authority');
      if (authority !== undefined && authority >= 0) {
        meta.push(`权威性: ${authority}`);
      }
      if (meta.length > 0) {
        section += `\n   ${meta.join('  ')}`;
      }

      if (summary.length > 0) {
        section += `\n   摘要: ${summary}`;
      }
      if (content.length > 0) {
        section += `\n   正文:\n${truncate(content, 2000, '...')}`;
      }
      sections.push(section);
      index++;
    }

    if (sections.length === 0) {
      return DeepSeekTools.ok('未找到相关结果', '没有找到相关结果');
    }
    return DeepSeekTools.ok(sections.join('\n\n'), `找到 ${sections.length} 条结果`);
  }

  // 抓取网页：给模型返回标题+正文，超长截断
  fetch(url: string): Promise<ToolResult> {
    if (!this.isAvailable()) {
      return Promise.resolve(DeepSeekTools.fail('未配置 DeepSeek API Key，搜索与抓取工具不可用'));
    }

    const target: string = normalizeFetchUrl(url);
    if (target.length === 0) {
      return Promise.resolve(DeepSeekTools.fail(`抓取地址无效: ${url}`));
    }

    const payload: Record<string, Object> = { 'url': target };

    return this.request('/v1/tools/fetch', JSON.stringify(payload), 60000)
      .then((response: JsonResponse) => {
        if (response.statusCode !== 200) {
          return DeepSeekTools.fail(`抓取请求失败: ${extractErrorMessage(response.body)}`);
        }
        return this.parseFetchResponse(response.body, target);
      })
      .catch((error: Error) => DeepSeekTools.fail(`抓取失败: ${error.message}`));
  }

  private parseFetchResponse(body: string, url: string): ToolResult {
    let root: Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(body) as Object;
      root = toRecord(parsed);
    } catch (e) {
      return DeepSeekTools.fail('抓取结果解析失败');
    }

    let source: Record<string, Object> = root;
    const dataValue: Object | undefined = root['data'];
    if (readString(root, ['content', 'text', 'markdown', 'html']) === undefined
      && dataValue !== undefined && isRecord(dataValue)) {
      source = toRecord(dataValue);
    }

    const content: string | undefined = readString(source, ['content', 'text', 'markdown', 'html', 'page_content']);
    if (content === undefined || content.trim().length === 0) {
      return DeepSeekTools.ok('页面内容为空', '页面内容为空');
    }

    const title: string | undefined = readString(source, ['title', 'page_title']);
    const finalUrl: string = readString(source, ['url', 'link']) || url;

    let text: string = title !== undefined && title.length > 0 ? `标题: ${title}\n` : '';
    text += `URL: ${finalUrl}\n\n`;
    text += truncate(content, 8000, '\n\n[内容已截断]');

    return DeepSeekTools.ok(text, `已抓取 ${extractHostname(finalUrl)}`);
  }

  // 执行工具调用，返回给模型的结果
  executeTool(type: ToolType, args: string): Promise<ToolResult> {
    let parsed: Record<string, Object>;
    try {
      const obj: Object = JSON.parse(args) as Object;
      parsed = toRecord(obj);
    } catch (e) {
      return Promise.resolve(DeepSeekTools.fail('工具参数解析失败'));
    }

    if (type === 'search') {
      const query: string | undefined = readString(parsed, ['query', 'q', 'keyword']);
      if (query === undefined || query.trim().length === 0) {
        return Promise.resolve(DeepSeekTools.fail('搜索缺少 query 参数'));
      }
      const count: number = readNumber(parsed, 'count') || 5;
      return this.search(query, count);
    }

    if (type === 'fetch') {
      const url: string | undefined = readString(parsed, ['url', 'link', 'href']);
      if (url === undefined || url.trim().length === 0) {
        return Promise.resolve(DeepSeekTools.fail('抓取缺少 url 参数'));
      }
      return this.fetch(url);
    }

    return Promise.resolve(DeepSeekTools.fail(`不支持的工具类型: ${type}`));
  }

  // 给用户看的工具调用摘要
  static getToolCallSummary(type: ToolType, args: string): string {
    let parsed: Record<string, Object> | null = null;
    try {
      const obj: Object = JSON.parse(args) as Object;
      parsed = toRecord(obj);
    } catch (e) {
      parsed = null;
    }

    if (parsed === null) {
      return type === 'search' ? '搜索' : '抓取网页';
    }

    if (type === 'search') {
      const query: string | undefined = readString(parsed, ['query', 'q', 'keyword']);
      return `搜索: ${query !== undefined ? query : '(无关键词)'}`;
    }

    const url: string | undefined = readString(parsed, ['url', 'link', 'href']);
    if (url === undefined || url.length === 0) {
      return '抓取网页';
    }
    return `抓取: ${extractHostname(url)}`;
  }
}
