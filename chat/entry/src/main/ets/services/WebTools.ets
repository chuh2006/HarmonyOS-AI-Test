import { J, raw, safeError } from '../core/Json';
import { ToolCall, ToolResult } from '../core/Protocols';
import { Cancellation, RequestSpec, Transport, validateBaseUrl } from './Network';

export class WebTools {
  private transport: Transport;
  private key: string;
  private base: string;
  private token: Cancellation;
  private update: () => void;
  private cache: Map<string, Promise<ToolResult>> = new Map();
  private identities: Map<string, string> = new Map();
  constructor(transport: Transport, key: string, base: string, token: Cancellation, update: () => void) {
    this.transport = transport; this.key = key; this.token = token; this.update = update;
    this.base = validateBaseUrl(base).replace(/\/anthropic(?:\/v1\/messages)?$/, '')
      .replace(/\/v1\/messages$/, '').replace(/\/messages$/, '').replace(/\/v1$/, '') + '/v1/tools/';
  }
  async run(calls: ToolCall[], round: number): Promise<ToolResult[]> {
    const results: ToolResult[] = [];
    // Bounded parallelism, while result order always follows the model's call order.
    for (let offset = 0; offset < calls.length; offset += 4) {
      this.token.check();
      const batch = calls.slice(offset, offset + 4).map((call: ToolCall, index: number) => {
        const id = call.id || 'gemini:' + round + ':' + (offset + index);
        const identity = call.name + '\n' + call.arguments;
        if (this.identities.has(id) && this.identities.get(id) !== identity) {
          throw new Error('同一工具调用标识出现了不同参数');
        }
        this.identities.set(id, identity);
        let pending = this.cache.get(id);
        if (!pending) { pending = this.execute(call); this.cache.set(id, pending); }
        return pending.then((result: ToolResult) => {
          if (result.call !== call) {
            call.segment.text = result.call.segment.text; call.segment.detail = result.call.segment.detail;
            call.segment.state = result.call.segment.state; call.segment.links = result.call.segment.links;
            call.segment.titles = result.call.segment.titles;
          }
          return new ToolResult(call, result.output, result.failed);
        });
      });
      const completed = await Promise.all(batch); this.token.check(); results.push(...completed);
    }
    return results;
  }
  private async execute(call: ToolCall): Promise<ToolResult> {
    this.token.check(); call.segment.state = 'running'; this.update();
    try {
      if (!this.key) { throw new Error('未配置 DeepSeek 密钥，联网工具暂不可用'); }
      if (call.name !== 'search' && call.name !== 'fetch') { throw new Error('不支持的工具：' + call.name); }
      let args: J;
      try { args = J.parse(call.arguments); } catch (_) { throw new Error('工具参数不是完整 JSON'); }
      const body = J.object();
      if (call.name === 'search') {
        const query = args.get('query').str().trim();
        if (Array.from(query).length < 1 || Array.from(query).length > 128) { throw new Error('搜索词需为 1～128 个字符'); }
        body.set('query', query).set('count', 5).set('need_content', true); call.segment.text = query;
      } else {
        const url = args.get('url').str().trim();
        if (url.length > 8192 || !/^https?:\/\/[^\s/@]+(?:[/?#][^\s]*)?$/.test(url)) { throw new Error('抓取地址需为不含账户密码的 HTTP 或 HTTPS 网页'); }
        body.set('url', url); call.segment.text = url;
      }
      this.update();
      const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + this.key, 'Accept': 'application/json' };
      const response = await this.transport.json(new RequestSpec(this.base + call.name, headers, body.json()), this.token);
      this.token.check();
      if (response.has('error')) { throw new Error(response.get('error').get('message').str() || '网页工具执行失败'); }
      if (call.name === 'search') {
        if (!Array.isArray(response.get('results').value)) { throw new Error('搜索服务返回格式不完整'); }
        const results = response.get('results').array().slice(0, 5);
        call.segment.links = results.map((item: J) => item.get('url').str());
        call.segment.titles = results.map((item: J) => item.get('title').str() || item.get('url').str());
        call.segment.detail = results.length === 0 ? '未找到相关资料' : '已查阅 ' + results.length + ' 个来源';
        results.forEach((item: J) => {
          const content = item.get('content').str();
          if (content.length > 16000) { item.set('content', content.slice(0, 16000)).set('content_truncated', true); }
        });
        response.set('results', raw(results));
      } else {
        if (!response.has('content')) { throw new Error('抓取服务返回格式不完整'); }
        call.segment.detail = response.get('title').str() || '已读取网页';
        call.segment.links = [args.get('url').str()]; call.segment.titles = [call.segment.detail];
        const content = response.get('content').str();
        if (content.length > 64000) { response.set('content', content.slice(0, 64000)).set('content_truncated', true); }
      }
      call.segment.state = 'completed'; this.update();
      return new ToolResult(call, response.json(), false);
    } catch (error) {
      this.token.check();
      const message = safeError(error as Error, [this.key]);
      call.segment.state = 'failed'; call.segment.detail = message; this.update();
      return new ToolResult(call, J.object().set('error', J.object().set('message', message).value).json(), true);
    }
  }
}
