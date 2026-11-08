/**
 * Client side tools: web search and page fetch, powered by DeepSeek's
 * /v1/tools endpoints. Tool results are formatted twice - rich enough for
 * the model, compact enough for the chat UI (the user sees titles and links,
 * never the full scraped text).
 */
import { postJson, serverMessage } from './HttpStream';
import { getArr, getNum, getStr, parseObj } from '../common/JsonUtil';
import { hostOf, truncate, oneLine, compactCount } from '../common/Util';
import { TOOL_FETCH, TOOL_SEARCH } from './Types';

export class ToolOutcome {
  ok: boolean = false;
  /** JSON string handed back to the model. */
  resultJson: string = '';
  /** One line status for the tool card. */
  summary: string = '';
  /** Compact human facing detail for the tool card. */
  detail: string = '';
}

const OPENAI_TOOLS_JSON: string = `[{"type":"function","name":"search","description":"搜索互联网网页，返回与查询相关的结构化搜索结果（标题、链接、摘要）。当你需要查找实时信息、新闻、事实核对或不了解的内容时使用该工具。","parameters":{"type":"object","properties":{"query":{"type":"string","description":"搜索关键词，1-128 个字符"},"count":{"type":"integer","description":"返回结果条数，默认 5，最多 10"}},"required":["query"]}},{"type":"function","name":"fetch","description":"抓取一个网页并返回其正文的 Markdown 文本。当你已经知道具体网址、或需要阅读某篇搜索结果的全文时使用该工具。","parameters":{"type":"object","properties":{"url":{"type":"string","description":"要抓取的 HTTP/HTTPS 网页地址"}},"required":["url"]}}]`;

const ANTHROPIC_TOOLS_JSON: string = `[{"name":"search","description":"搜索互联网网页，返回与查询相关的结构化搜索结果（标题、链接、摘要）。当你需要查找实时信息、新闻、事实核对或不了解的内容时使用该工具。","input_schema":{"type":"object","properties":{"query":{"type":"string","description":"搜索关键词，1-128 个字符"},"count":{"type":"integer","description":"返回结果条数，默认 5，最多 10"}},"required":["query"]}},{"name":"fetch","description":"抓取一个网页并返回其正文的 Markdown 文本。当你已经知道具体网址、或需要阅读某篇搜索结果的全文时使用该工具。","input_schema":{"type":"object","properties":{"url":{"type":"string","description":"要抓取的 HTTP/HTTPS 网页地址"}},"required":["url"]}}]`;

const GEMINI_TOOLS_JSON: string = `[{"functionDeclarations":[{"name":"search","description":"搜索互联网网页，返回与查询相关的结构化搜索结果（标题、链接、摘要）。当你需要查找实时信息、新闻、事实核对或不了解的内容时使用该工具。","parameters":{"type":"object","properties":{"query":{"type":"string","description":"搜索关键词，1-128 个字符"},"count":{"type":"integer","description":"返回结果条数，默认 5，最多 10"}},"required":["query"]}},{"name":"fetch","description":"抓取一个网页并返回其正文的 Markdown 文本。当你已经知道具体网址、或需要阅读某篇搜索结果的全文时使用该工具。","parameters":{"type":"object","properties":{"url":{"type":"string","description":"要抓取的 HTTP/HTTPS 网页地址"}},"required":["url"]}}]}]`;

function errorJson(message: string): string {
  const rec: Record<string, Object> = { 'error': message };
  return JSON.stringify(rec);
}

function authHeaders(apiKey: string): Record<string, string> {
  return {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ' + apiKey.trim()
  };
}

export class ToolRunner {
  static available(apiKey: string): boolean {
    return apiKey.trim().length > 0;
  }

  /** OpenAI function style tool list (also used by Mercury). */
  static openaiToolsJson(): string {
    return OPENAI_TOOLS_JSON;
  }

  /** Anthropic style tool list for the DeepSeek Messages API. */
  static anthropicToolsJson(): string {
    return ANTHROPIC_TOOLS_JSON;
  }

  /** Gemini functionDeclarations style tool list. */
  static geminiToolsJson(): string {
    return GEMINI_TOOLS_JSON;
  }

  static run(name: string, argsJson: string, apiKey: string): Promise<ToolOutcome> {
    if (!ToolRunner.available(apiKey)) {
      return Promise.resolve(ToolRunner.unavailable(name));
    }
    const args: Record<string, Object> = parseObj(argsJson);
    if (name === TOOL_SEARCH) {
      return ToolRunner.search(args, apiKey);
    }
    if (name === TOOL_FETCH) {
      return ToolRunner.fetch(args, apiKey);
    }
    const out: ToolOutcome = new ToolOutcome();
    out.ok = false;
    out.resultJson = errorJson('未知的工具：' + name);
    out.summary = '未知工具';
    out.detail = name;
    return Promise.resolve(out);
  }

  private static unavailable(name: string): ToolOutcome {
    const out: ToolOutcome = new ToolOutcome();
    out.ok = false;
    const label: string = name === TOOL_SEARCH ? '联网搜索' : '网页抓取';
    out.resultJson = errorJson(label + '暂不可用：本机未配置 DeepSeek API Key，无法调用联网工具。请告知用户在设置中填写后重试。');
    out.summary = '工具不可用';
    out.detail = '未配置 DeepSeek API Key';
    return out;
  }

  private static search(args: Record<string, Object>, apiKey: string): Promise<ToolOutcome> {
    const query: string = getStr(args, 'query').trim();
    const out: ToolOutcome = new ToolOutcome();
    if (query.length === 0) {
      out.ok = false;
      out.resultJson = errorJson('缺少 query 参数');
      out.summary = '参数缺失';
      out.detail = '缺少搜索关键词';
      return Promise.resolve(out);
    }
    let count: number = getNum(args, 'count');
    if (count <= 0) {
      count = 5;
    }
    if (count > 10) {
      count = 10;
    }
    const body: Record<string, Object> = {
      'query': query,
      'count': count,
      'need_content': false
    };
    return postJson('https://api.deepseek.com/v1/tools/search',
      authHeaders(apiKey), JSON.stringify(body), 45000).then((res) => {
      if (!res.ok) {
        out.ok = false;
        const msg: string = serverMessage(res.body, res.code);
        out.resultJson = errorJson(msg);
        out.summary = '搜索失败';
        out.detail = truncate(msg, 60);
        return out;
      }
      const root: Record<string, Object> = parseObj(res.body);
      const rows: Object[] = getArr(root, 'results');
      const modelResults: Object[] = [];
      const titles: string[] = [];
      for (let i = 0; i < rows.length; i++) {
        const r: Record<string, Object> = parseObj(JSON.stringify(rows[i]));
        const title: string = oneLine(getStr(r, 'title'));
        const url: string = getStr(r, 'url');
        const item: Record<string, Object> = {
          'title': title,
          'url': url,
          'site': getStr(r, 'site_name'),
          'date': getStr(r, 'date'),
          'summary': truncate(getStr(r, 'summary'), 900)
        };
        modelResults.push(item as Object);
        const line: string = title.length > 0 ? title : hostOf(url);
        if (titles.length < 3) {
          titles.push(line);
        }
      }
      const payload: Record<string, Object> = {
        'query': query,
        'count': modelResults.length
      };
      payload['results'] = modelResults;
      out.ok = true;
      out.resultJson = JSON.stringify(payload);
      out.summary = '搜索“' + truncate(query, 24) + '” · ' + rows.length.toString() + ' 条结果';
      if (titles.length === 0) {
        out.detail = '没有找到相关结果';
      } else {
        let d: string = titles.join('\n');
        if (rows.length > titles.length) {
          d += '\n… 等 ' + rows.length.toString() + ' 条';
        }
        out.detail = d;
      }
      return out;
    });
  }

  private static fetch(args: Record<string, Object>, apiKey: string): Promise<ToolOutcome> {
    const url: string = getStr(args, 'url').trim();
    const out: ToolOutcome = new ToolOutcome();
    if (url.length === 0) {
      out.ok = false;
      out.resultJson = errorJson('缺少 url 参数');
      out.summary = '参数缺失';
      out.detail = '缺少网页地址';
      return Promise.resolve(out);
    }
    const body: Record<string, Object> = { 'url': url };
    return postJson('https://api.deepseek.com/v1/tools/fetch',
      authHeaders(apiKey), JSON.stringify(body), 60000).then((res) => {
      if (!res.ok) {
        out.ok = false;
        const msg: string = serverMessage(res.body, res.code);
        out.resultJson = errorJson(msg);
        out.summary = '抓取失败';
        out.detail = truncate(msg, 60);
        return out;
      }
      const root: Record<string, Object> = parseObj(res.body);
      let title: string = oneLine(getStr(root, 'title'));
      const content: string = getStr(root, 'content');
      if (title.length === 0) {
        title = hostOf(url);
      }
      const payload: Record<string, Object> = {
        'title': title,
        'url': url,
        'content': content.length > 30000 ? content.substring(0, 30000) + '\n…(内容过长已截断)' : content
      };
      out.ok = true;
      out.resultJson = JSON.stringify(payload);
      out.summary = '已抓取《' + truncate(title, 24) + '》';
      out.detail = hostOf(url) + ' · ' + compactCount(content.length) + ' 字';
      return out;
    });
  }
}

/** Friendly label for tool cards. */
export function toolDisplayName(name: string): string {
  if (name === TOOL_SEARCH) {
    return '联网搜索';
  }
  if (name === TOOL_FETCH) {
    return '网页抓取';
  }
  return name;
}

/** Short argument line shown on the tool card. */
export function toolArgsPreview(name: string, argsJson: string): string {
  const args: Record<string, Object> = parseObj(argsJson);
  if (name === TOOL_SEARCH) {
    const q: string = getStr(args, 'query');
    return q.length > 0 ? '“' + truncate(oneLine(q), 40) + '”' : '（缺少关键词）';
  }
  if (name === TOOL_FETCH) {
    const u: string = getStr(args, 'url');
    return u.length > 0 ? truncate(u, 52) : '（缺少地址）';
  }
  return truncate(argsJson, 52);
}
