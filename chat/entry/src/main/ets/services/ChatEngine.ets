import { Archive, isBusy, modelSpec, Options, ProviderConfig, Segment, Session, Turn } from '../core/Models';
import { J, safeError } from '../core/Json';
import { buildRequest, ProviderRound, toolReplies, userInput } from '../core/Protocols';
import { SseEvent } from '../core/Sse';
import { Cancellation, HttpTransport, Transport } from './Network';
import { WebTools } from './WebTools';
import { Vault } from './Store';

export interface KeyReader { read(provider: string): Promise<string>; }

class Job {
  token: Cancellation = new Cancellation();
  turn: Turn;
  constructor(turn: Turn) { this.turn = turn; }
}

export class ChatEngine {
  private jobs: Map<string, Job> = new Map();
  private transport: Transport;
  private vault: KeyReader;
  private update: () => void;
  private persist: (immediate: boolean) => void;
  constructor(update: () => void, persist: (immediate: boolean) => void, transport: Transport = new HttpTransport(), vault: KeyReader = new Vault()) {
    this.update = update; this.persist = persist; this.transport = transport; this.vault = vault;
  }
  busy(session: Session): boolean { return this.jobs.has(session.id); }
  stop(session: Session): void {
    const job = this.jobs.get(session.id);
    if (!job) { return; }
    job.token.cancel(); job.turn.status = 'stopped';
    job.turn.segments.forEach((segment: Segment) => {
      if (segment.kind === 'tool' && ['pending', 'running'].includes(segment.state)) { segment.state = 'stopped'; }
    });
    this.update(); this.persist(true);
  }
  stopAll(): void { this.jobs.forEach((job: Job) => job.token.cancel()); }
  async send(archive: Archive, session: Session, text: string, retry: boolean = false): Promise<void> {
    if (this.busy(session) || (!text.trim() && !retry)) { return; }
    const options = JSON.parse(JSON.stringify(session.options)) as Options;
    const provider = modelSpec(options.model).provider;
    let turn: Turn;
    if (retry) {
      const previous = session.turns[session.turns.length - 1];
      if (!previous || !['failed', 'stopped'].includes(previous.status)) { return; }
      turn = previous; turn.segments = []; turn.replay = []; turn.draft = []; turn.usage = []; turn.error = ''; turn.status = 'requesting';
      options.model = turn.model;
    } else {
      turn = new Turn(); turn.user = text.trim(); turn.model = options.model; session.turns.push(turn);
      if (session.turns.length === 1) { session.title = turn.user.slice(0, 24); }
    }
    const job = new Job(turn); this.jobs.set(session.id, job);
    const token = job.token;
    session.updated = Date.now(); this.update(); this.persist(true);
    const secrets: string[] = [];
    try {
      const config = archive.providers.find((p: ProviderConfig) => p.id === provider);
      const deepseek = archive.providers.find((p: ProviderConfig) => p.id === 'deepseek');
      if (!config || !deepseek) { throw new Error('服务配置缺失，请重新保存服务设置'); }
      // Capture URLs and credentials for this generation; settings edits affect future requests.
      const requestConfig = new ProviderConfig(config.id, config.name, config.baseUrl);
      const key = await this.vault.read(provider); secrets.push(key); token.check();
      if (!key) { throw new Error('请先在服务设置中填写 ' + config.name + ' API Key'); }
      let toolKey = provider === 'deepseek' ? key : '';
      if (options.tools && provider !== 'deepseek') { toolKey = await this.vault.read('deepseek'); }
      secrets.push(toolKey); token.check();
      const toolsEnabled = options.tools && toolKey.length > 0;
      if (options.tools && !toolKey) {
        const notice = new Segment(); notice.kind = 'notice'; notice.text = '联网未启用：请在服务设置中配置 DeepSeek 密钥'; turn.segments.push(notice);
      }
      const history: J[] = [];
      session.turns.forEach((previous: Turn) => {
        if (previous.id !== turn.id && previous.model === options.model) {
          previous.replay.forEach((item: string) => history.push(J.parse(item)));
        }
      });
      const replay: J[] = [userInput(provider, turn.user)]; history.push(replay[0]);
      const changed = (): void => {
        if (token.cancelled) { return; }
        session.updated = Date.now(); this.update(); this.persist(false);
      };
      const tools = new WebTools(this.transport, toolKey, deepseek.baseUrl, token, changed);
      for (let roundIndex = 0; roundIndex < 9; roundIndex++) {
        token.check(); turn.status = 'requesting'; turn.draft = []; changed();
        const round = new ProviderRound(options, turn, changed);
        await this.transport.stream(buildRequest(options, requestConfig, key, history, toolsEnabled && roundIndex < 8), token, (event: SseEvent) => {
          token.check(); round.event(event);
        });
        token.check();
        const calls = round.finish();
        const output = round.output();
        if (calls.length > 16) { throw new Error('本轮工具调用过多，请缩小问题范围后重试'); }
        if (calls.length === 0) {
          replay.push(...output); turn.replay = replay.map((item: J) => item.json()); turn.draft = [];
          turn.status = 'completed'; break;
        }
        if (roundIndex === 8) { throw new Error('已达到 8 轮联网查询上限，请缩小问题范围后重试'); }
        turn.status = 'tools'; changed();
        const results = await tools.run(calls, roundIndex); token.check();
        const replies = toolReplies(provider, results);
        history.push(...output, ...replies); replay.push(...output, ...replies);
        turn.replay = replay.map((item: J) => item.json()); turn.draft = []; this.persist(true);
      }
    } catch (error) {
      turn.status = token.cancelled ? 'stopped' : 'failed';
      if (!token.cancelled) { turn.error = safeError(error as Error, secrets); }
      turn.segments.forEach((segment: Segment) => {
        if (segment.kind === 'tool' && ['pending', 'running'].includes(segment.state)) { segment.state = token.cancelled ? 'stopped' : 'failed'; }
      });
    } finally {
      if (this.jobs.get(session.id) === job) { this.jobs.delete(session.id); }
      if (isBusy(turn.status)) { turn.status = 'failed'; turn.error = '生成意外结束，请重试'; }
      session.updated = Date.now(); this.update(); this.persist(true);
    }
  }
}
