import { jsonPost, StreamHandle, ChatError } from '../net/HttpClient';
import { trimBaseUrl } from '../providers/Base';

export interface ToolParamSchema {
  type: string;
  description?: string;
}

export interface ToolSchema {
  type: string;
  properties: Record<string, ToolParamSchema>;
  required: string[];
}

export interface ToolDef {
  name: string;
  description: string;
  schema: ToolSchema;
}

export const TOOL_DEFS: ToolDef[] = [
  {
    name: 'search',
    description: '搜索网页。返回结果列表，每条包含标题、链接、短摘要和面向模型的长摘要。适用于查找最新信息、新闻、事实核查等需要联网的场景。',
    schema: {
      type: 'object',
      properties: {
        'query': { type: 'string', description: '搜索词，1~128 个字符，支持 site: 与引号语法' },
        'count': { type: 'integer', description: '返回结果条数，1~10，默认 5' }
      },
      required: ['query']
    }
  },
  {
    name: 'fetch',
    description: '抓取单个网页，返回页面标题与 Markdown 格式正文。适用于阅读搜索结果中的链接或用户给出的网页。',
    schema: {
      type: 'object',
      properties: {
        'url': { type: 'string', description: '要抓取的 HTTP/HTTPS 网页地址' }
      },
      required: ['url']
    }
  }
];

export class ToolExecResult {
  ok: boolean = true;
  result: string = '';
  display: string = '';
  error: string = '';
}

interface SearchArgs {
  query?: string;
  count?: number;
}

interface FetchArgs {
  url?: string;
}

interface SearchResultItem {
  title?: string;
  url?: string;
  snippet?: string;
  summary?: string;
  date?: string;
}

interface SearchResponse {
  results?: SearchResultItem[];
}

interface FetchResponse {
  title?: string;
  content?: string;
}

interface ModelSearchItem {
  title: string;
  url: string;
  snippet: string;
  summary: string;
  date: string;
}

interface ModelSearchResult {
  results: ModelSearchItem[];
}

interface ModelFetchResult {
  title: string;
  content: string;
  truncated: boolean;
}

function toolBaseUrl(deepseekBaseUrl: string): string {
  let u = trimBaseUrl(deepseekBaseUrl);
  if (u.endsWith('/anthropic')) {
    u = u.substring(0, u.length - '/anthropic'.length);
  }
  return u;
}

async function postWithRetry(url: string, key: string, body: string,
  handle: StreamHandle): Promise<string> {
  const headers: Record<string, string> = { 'Authorization': `Bearer ${key}` };
  try {
    return await jsonPost(url, headers, body, handle);
  } catch (e) {
    if (e instanceof ChatError && !e.aborted && (e.status === 408 || e.status === 429 || e.status >= 500)) {
      return await jsonPost(url, headers, body, handle);
    }
    throw e as Error;
  }
}

export class ToolService {
  static async execute(name: string, argsJson: string, deepseekKey: string, deepseekBaseUrl: string,
    handle: StreamHandle): Promise<ToolExecResult> {
    const out = new ToolExecResult();
    if (deepseekKey.length === 0) {
      out.ok = false;
      out.error = '工具服务未配置 DeepSeek API Key';
      out.display = '工具不可用';
      out.result = `{"error":"${name} 工具不可用：用户未配置 DeepSeek API Key。请不要再调用工具，基于已有知识直接回答，并说明信息可能不是最新。"}`;
      return out;
    }
    try {
      if (name === 'search') {
        await ToolService.doSearch(argsJson, deepseekKey, deepseekBaseUrl, handle, out);
      } else if (name === 'fetch') {
        await ToolService.doFetch(argsJson, deepseekKey, deepseekBaseUrl, handle, out);
      } else {
        out.ok = false;
        out.error = `未知工具 ${name}`;
        out.result = `{"error":"未知工具：${name}"}`;
      }
    } catch (e) {
      if (e instanceof ChatError && e.aborted) {
        throw e;
      }
      const msg = e instanceof Error ? e.message : '工具执行失败';
      out.ok = false;
      out.error = msg;
      out.display = '执行失败';
      out.result = JSON.stringify({ 'error': msg });
    }
    return out;
  }

  private static async doSearch(argsJson: string, key: string, baseUrl: string,
    handle: StreamHandle, out: ToolExecResult): Promise<void> {
    let args: SearchArgs;
    try {
      args = JSON.parse(argsJson) as SearchArgs;
    } catch (e) {
      args = {};
    }
    let query = (args.query ?? '').trim();
    if (query.length === 0) {
      out.ok = false;
      out.error = '缺少搜索词';
      out.result = '{"error":"query 不能为空"}';
      return;
    }
    if (query.length > 128) {
      query = query.substring(0, 128);
    }
    let count = args.count ?? 5;
    if (count < 1) {
      count = 1;
    }
    if (count > 10) {
      count = 10;
    }
    const body = JSON.stringify({ 'query': query, 'count': count, 'need_content': false });
    const text = await postWithRetry(`${toolBaseUrl(baseUrl)}/v1/tools/search`, key, body, handle);
    const resp = JSON.parse(text) as SearchResponse;
    const items: ModelSearchItem[] = [];
    const results = resp.results ?? [];
    for (const r of results) {
      items.push({
        title: r.title ?? '',
        url: r.url ?? '',
        snippet: r.snippet ?? '',
        summary: r.summary ?? '',
        date: r.date ?? ''
      });
    }
    const modelResult: ModelSearchResult = { results: items };
    out.result = JSON.stringify(modelResult);
    out.display = items.length > 0 ? `找到 ${items.length} 条结果` : '没有找到结果';
  }

  private static async doFetch(argsJson: string, key: string, baseUrl: string,
    handle: StreamHandle, out: ToolExecResult): Promise<void> {
    let args: FetchArgs;
    try {
      args = JSON.parse(argsJson) as FetchArgs;
    } catch (e) {
      args = {};
    }
    const url = (args.url ?? '').trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      out.ok = false;
      out.error = '无效的网页地址';
      out.result = '{"error":"url 必须是 HTTP/HTTPS 地址"}';
      return;
    }
    const body = JSON.stringify({ 'url': url });
    const text = await postWithRetry(`${toolBaseUrl(baseUrl)}/v1/tools/fetch`, key, body, handle);
    const resp = JSON.parse(text) as FetchResponse;
    let content = resp.content ?? '';
    let truncated = false;
    if (content.length > 12000) {
      content = content.substring(0, 12000);
      truncated = true;
    }
    const modelResult: ModelFetchResult = { title: resp.title ?? '', content: content, truncated: truncated };
    out.result = JSON.stringify(modelResult);
    out.display = (resp.title ?? '').length > 0 ? (resp.title ?? '') : '已读取网页';
  }
}