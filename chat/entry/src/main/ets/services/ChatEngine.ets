/**
 * Chat engine: drives one conversation turn.
 *
 *  - streams a provider response into the assistant message (blocks)
 *  - executes tool calls as soon as their arguments are complete, in parallel
 *  - feeds tool results back and continues until the model answers or the
 *    round limit is reached
 *  - guarantees that late network data is only written to the session it
 *    belongs to and that stopping aborts the request and the tool loop
 */
import { ProviderAdapter, RequestSpec, TurnHandler, TurnSink } from './Adapter';
import { postStream, StreamHandle, StreamListener } from './HttpStream';
import { SseParser } from './SseParser';
import { ToolOutcome, ToolRunner } from './Tools';
import {
  Block, Msg, Session,
  BLOCK_TEXT, BLOCK_THINKING, BLOCK_TOOL,
  MSG_ASSISTANT, MSG_USER,
  PHASE_ANSWERING, PHASE_DONE, PHASE_ERROR, PHASE_IDLE, PHASE_REQUESTING, PHASE_STOPPED,
  PHASE_THINKING, PHASE_TOOL,
  ST_DONE, ST_ERROR, ST_STOPPED, ST_STREAMING,
  TOOL_DONE, TOOL_FAILED, TOOL_PENDING, TOOL_RUNNING
} from './Types';
import { DeepSeekAdapter } from './DeepSeekAdapter';
import { OpenAIAdapter } from './OpenAIAdapter';
import { MercuryAdapter } from './MercuryAdapter';
import { GeminiAdapter } from './GeminiAdapter';
import { SecureStore } from './SecureStore';
import { SessionStore } from './SessionStore';
import { normalizeOptions, providerInfo } from './Providers';
import { newId } from '../common/Util';

const MAX_ROUNDS: number = 8;

const ADAPTER_DEEPSEEK: DeepSeekAdapter = new DeepSeekAdapter();
const ADAPTER_OPENAI: OpenAIAdapter = new OpenAIAdapter();
const ADAPTER_MERCURY: MercuryAdapter = new MercuryAdapter();
const ADAPTER_GEMINI: GeminiAdapter = new GeminiAdapter();

function adapterFor(providerId: string): ProviderAdapter {
  if (providerId === 'openai') {
    return ADAPTER_OPENAI;
  }
  if (providerId === 'mercury') {
    return ADAPTER_MERCURY;
  }
  if (providerId === 'gemini') {
    return ADAPTER_GEMINI;
  }
  return ADAPTER_DEEPSEEK;
}

class EngineSink implements TurnSink {
  private engine: ChatEngine;
  private session: Session;
  private msg: Msg;
  private settled: boolean = false;
  private curThink: Block | null = null;
  private curText: Block | null = null;
  private toolBlocks: Map<string, Block> = new Map();
  onFinish: (kind: string, message: string) => void = (kind: string, message: string) => {
  };

  constructor(engine: ChatEngine, session: Session, msg: Msg) {
    this.engine = engine;
    this.session = session;
    this.msg = msg;
  }

  thinking(text: string, replace: boolean): void {
    if (this.settled) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    if (this.curThink === null) {
      const b: Block = Block.make(BLOCK_THINKING, newId('b'));
      b.uiOpen = true;
      this.curThink = b;
      this.append(b);
    }
    const b: Block = this.curThink;
    b.text = replace ? text : b.text + text;
    this.engine.setPhase(this.session, PHASE_THINKING);
    this.engine.notify(this.session);
  }

  text(text: string, replace: boolean): void {
    if (this.settled) {
      return;
    }
    if (this.curText === null) {
      const b: Block = Block.make(BLOCK_TEXT, newId('b'));
      this.curText = b;
      this.append(b);
      if (this.curThink !== null && !this.curThink.uiTouched) {
        this.curThink.uiOpen = false;
      }
    }
    const b: Block = this.curText;
    b.text = replace ? text : b.text + text;
    this.engine.setPhase(this.session, PHASE_ANSWERING);
    this.engine.notify(this.session);
  }

  toolStart(callId: string, name: string): void {
    if (this.settled) {
      return;
    }
    let b: Block | null = null;
    const existing: Block | undefined = this.toolBlocks.get(callId);
    if (existing !== undefined) {
      b = existing;
    }
    if (b === null) {
      b = Block.make(BLOCK_TOOL, newId('b'));
      b.toolId = callId;
      b.toolStatus = TOOL_PENDING;
      this.toolBlocks.set(callId, b);
      // a tool call closes the current text phase (diffusion segments)
      this.curText = null;
      this.curThink = null;
      this.append(b);
    }
    if (name.length > 0 && b.toolName !== name) {
      b.toolName = name;
    }
    if (b.toolName.length === 0) {
      b.toolName = name;
    }
    this.engine.notify(this.session);
  }

  toolArgs(callId: string, delta: string): void {
    if (this.settled) {
      return;
    }
    const b: Block | undefined = this.toolBlocks.get(callId);
    if (b === undefined) {
      return;
    }
    b.toolArgs += delta;
    this.engine.notify(this.session);
  }

  toolEnd(callId: string): void {
    if (this.settled) {
      return;
    }
    const b: Block | undefined = this.toolBlocks.get(callId);
    if (b === undefined) {
      return;
    }
    this.engine.startTool(this.session, b);
  }

  proto(protoJson: string): void {
    if (this.settled) {
      return;
    }
    this.msg.proto = protoJson;
    this.engine.touch(this.session);
  }

  end(): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.onFinish('end', '');
  }

  fail(message: string): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.onFinish('fail', message);
  }

  stopped(): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.onFinish('stopped', '');
  }

  isStopped(): boolean {
    return this.engine.isAborted(this.session.id);
  }

  private append(b: Block): void {
    const arr: Block[] = this.msg.blocks.slice();
    arr.push(b);
    this.msg.blocks = arr;
  }
}

class EngineStreamListener implements StreamListener {
  private parser: SseParser = new SseParser();
  private turn: TurnHandler;
  private sink: EngineSink;

  constructor(turn: TurnHandler, sink: EngineSink) {
    this.turn = turn;
    this.sink = sink;
    this.parser.onEvent = (name: string, data: string): void => {
      this.turn.handleEvent(name, data);
    };
  }

  onChunk(text: string): void {
    this.parser.push(text);
  }

  onEnd(stopped: boolean): void {
    if (stopped) {
      this.sink.stopped();
      return;
    }
    this.parser.flush();
    this.turn.handleEnd();
  }

  onError(message: string, code: number): void {
    this.sink.fail(message);
  }
}

export class ChatEngine {
  onUpdate: (sessionId: string) => void = (sessionId: string) => {
  };
  onPhase: (sessionId: string, phase: string) => void = (sessionId: string, phase: string) => {
  };

  private keys: Map<string, string> = new Map();
  private baseUrls: Map<string, string> = new Map();
  private handles: Map<string, StreamHandle> = new Map();
  private aborted: Set<string> = new Set();
  private running: Set<string> = new Set();
  private phases: Map<string, string> = new Map();
  private toolJobs: Map<string, Promise<void>[]> = new Map();

  // ---------- credentials ----------

  loadCredentials(): Promise<void> {
    const ids: string[] = ['deepseek', 'openai', 'mercury', 'gemini'];
    const jobs: Promise<void>[] = [];
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      const p: Promise<void> = SecureStore.getKey(id).then((v: string) => {
        this.keys.set(id, v);
      });
      jobs.push(p);
    }
    return Promise.all(jobs).then(() => {
      const s: Record<string, Object> = SessionStore.loadSettings();
      const urls: Object | undefined = s['baseUrls'];
      if (urls !== undefined && urls !== null && typeof urls === 'object') {
        const map: Record<string, Object> = urls as Record<string, Object>;
        for (let i = 0; i < ids.length; i++) {
          const v: Object | undefined = map[ids[i]];
          if (v !== undefined && v !== null && typeof v === 'string') {
            this.baseUrls.set(ids[i], v as string);
          }
        }
      }
    });
  }

  getKey(providerId: string): string {
    const v: string | undefined = this.keys.get(providerId);
    return v === undefined ? '' : v;
  }

  setKey(providerId: string, value: string): void {
    this.keys.set(providerId, value);
    SecureStore.setKey(providerId, value.trim()).then(() => {
    });
  }

  getBaseUrl(providerId: string, fallback: string): string {
    const v: string | undefined = this.baseUrls.get(providerId);
    if (v === undefined || v.trim().length === 0) {
      return fallback;
    }
    return v.trim();
  }

  setBaseUrl(providerId: string, value: string): void {
    this.baseUrls.set(providerId, value.trim());
    const s: Record<string, Object> = SessionStore.loadSettings();
    let urls: Record<string, Object> = {};
    const prev: Object | undefined = s['baseUrls'];
    if (prev !== undefined && prev !== null && typeof prev === 'object') {
      urls = prev as Record<string, Object>;
    }
    urls[providerId] = value.trim();
    s['baseUrls'] = urls;
    SessionStore.saveSettings(s);
  }

  // ---------- state ----------

  phaseOf(sessionId: string): string {
    const v: string | undefined = this.phases.get(sessionId);
    return v === undefined ? PHASE_IDLE : v;
  }

  isRunning(sessionId: string): boolean {
    return this.running.has(sessionId);
  }

  isAborted(sessionId: string): boolean {
    return this.aborted.has(sessionId);
  }

  setPhase(session: Session, phase: string): void {
    if (this.phases.get(session.id) === phase) {
      return;
    }
    this.phases.set(session.id, phase);
    this.onPhase(session.id, phase);
  }

  notify(session: Session): void {
    session.updatedAt = Date.now();
    this.onUpdate(session.id);
  }

  touch(session: Session): void {
    this.onUpdate(session.id);
  }

  // ---------- actions ----------

  send(session: Session, text: string): void {
    const trimmed: string = text.trim();
    if (trimmed.length === 0 || this.running.has(session.id)) {
      return;
    }
    const userMsg: Msg = new Msg();
    userMsg.id = newId('m');
    userMsg.role = MSG_USER;
    userMsg.status = ST_DONE;
    userMsg.createdAt = Date.now();
    const b: Block = Block.make(BLOCK_TEXT, newId('b'));
    b.text = trimmed;
    userMsg.blocks = [b];
    const arr: Msg[] = session.messages.slice();
    arr.push(userMsg);
    session.messages = arr;
    if (session.title === '新会话' || session.title.length === 0) {
      session.title = trimmed.length > 18 ? trimmed.substring(0, 18) + '…' : trimmed;
    }
    this.notify(session);
    SessionStore.save(session);
    this.runLoop(session);
  }

  /** Drop the trailing failed / stopped assistant message and generate again. */
  retry(session: Session): void {
    if (this.running.has(session.id)) {
      return;
    }
    const msgs: Msg[] = session.messages.slice();
    while (msgs.length > 0) {
      const last: Msg = msgs[msgs.length - 1];
      if (last.role === MSG_ASSISTANT && (last.status === ST_ERROR || last.status === ST_STOPPED)) {
        msgs.pop();
        continue;
      }
      break;
    }
    session.messages = msgs;
    this.notify(session);
    SessionStore.save(session);
    this.runLoop(session);
  }

  stop(sessionId: string): void {
    this.aborted.add(sessionId);
    const handle: StreamHandle | undefined = this.handles.get(sessionId);
    if (handle !== undefined) {
      handle.cancel();
      this.handles.delete(sessionId);
    }
    this.phases.set(sessionId, PHASE_STOPPED);
    this.onPhase(sessionId, PHASE_STOPPED);
  }

  // ---------- generation loop ----------

  private runLoop(session: Session): void {
    if (this.running.has(session.id)) {
      return;
    }
    this.running.add(session.id);
    this.aborted.delete(session.id);
    this.setPhase(session, PHASE_REQUESTING);
    this.loop(session, 0);
  }

  private loop(session: Session, round: number): void {
    if (this.aborted.has(session.id) || round >= MAX_ROUNDS) {
      this.finishLoop(session, round >= MAX_ROUNDS ? PHASE_DONE : PHASE_STOPPED);
      return;
    }
    const msg: Msg = new Msg();
    msg.id = newId('m');
    msg.role = MSG_ASSISTANT;
    msg.status = ST_STREAMING;
    msg.createdAt = Date.now();
    msg.modelLabel = session.modelId;
    msg.protoProvider = session.providerId;
    const arr: Msg[] = session.messages.slice();
    arr.push(msg);
    session.messages = arr;
    this.setPhase(session, PHASE_REQUESTING);
    this.notify(session);

    this.runRound(session, msg).then((kind: string) => {
      if (kind === 'stopped') {
        msg.status = ST_STOPPED;
        this.notify(session);
        SessionStore.save(session);
        this.finishLoop(session, PHASE_STOPPED);
        return;
      }
      if (kind === 'fail') {
        msg.status = ST_ERROR;
        this.notify(session);
        SessionStore.save(session);
        this.finishLoop(session, PHASE_ERROR);
        return;
      }
      msg.status = ST_DONE;
      this.notify(session);
      SessionStore.save(session);
      // make sure every tool call of this round finished before deciding
      this.drainTools(session).then(() => {
        if (msg.hasToolBlocks() && !this.aborted.has(session.id)) {
          this.setPhase(session, PHASE_TOOL);
          this.loop(session, round + 1);
          return;
        }
        this.finishLoop(session, this.aborted.has(session.id) ? PHASE_STOPPED : PHASE_DONE);
      });
    });
  }

  private finishLoop(session: Session, phase: string): void {
    this.running.delete(session.id);
    this.handles.delete(session.id);
    this.setPhase(session, phase);
    this.onUpdate(session.id);
  }

  private runRound(session: Session, msg: Msg): Promise<string> {
    const adapter: ProviderAdapter = adapterFor(session.providerId);
    const apiKey: string = this.getKey(session.providerId);
    const baseUrl: string = this.getBaseUrl(session.providerId,
      providerInfo(session.providerId).defaultBaseUrl);
    normalizeOptions(session.providerId, session.modelId, session.options);
    const toolsEnabled: boolean = ToolRunner.available(this.getKey('deepseek'));
    const spec: RequestSpec = adapter.buildRequest(session, session.messages, toolsEnabled,
      apiKey, baseUrl);

    const sink: EngineSink = new EngineSink(this, session, msg);
    const turn: TurnHandler = adapter.createTurn(sink, session);
    const listener: EngineStreamListener = new EngineStreamListener(turn, sink);

    return new Promise((resolve: (kind: string) => void) => {
      sink.onFinish = (kind: string, message: string): void => {
        if (kind === 'fail') {
          msg.errorText = message;
        }
        this.handles.delete(session.id);
        resolve(kind);
      };
      if (this.aborted.has(session.id)) {
        sink.stopped();
        return;
      }
      const handle: StreamHandle = postStream(spec.url, spec.headers, spec.bodyJson, listener);
      this.handles.set(session.id, handle);
    });
  }

  // ---------- tool execution ----------

  startTool(session: Session, block: Block): void {
    if (block.toolFinished || block.toolStatus === TOOL_RUNNING) {
      return;
    }
    if (block.toolName.length === 0) {
      block.toolName = 'search';
    }
    block.toolStatus = TOOL_RUNNING;
    this.setPhase(session, PHASE_TOOL);
    this.notify(session);
    const key: string = this.getKey('deepseek');
    const job: Promise<void> = ToolRunner.run(block.toolName, block.toolArgs, key).then((out: ToolOutcome) => {
      block.toolResult = out.resultJson;
      block.toolSummary = out.summary;
      block.toolDetail = out.detail;
      block.toolStatus = out.ok ? TOOL_DONE : TOOL_FAILED;
      block.toolFinished = true;
      this.notify(session);
      SessionStore.save(session);
    }).catch(() => {
      block.toolResult = JSON.stringify({ 'error': '工具执行异常' });
      block.toolSummary = '工具执行异常';
      block.toolDetail = '';
      block.toolStatus = TOOL_FAILED;
      block.toolFinished = true;
      this.notify(session);
      SessionStore.save(session);
    });
    let list: Promise<void>[] | undefined = this.toolJobs.get(session.id);
    if (list === undefined) {
      list = [];
      this.toolJobs.set(session.id, list);
    }
    list.push(job);
  }

  /** Wait (recursively) until every started tool call of this session settled. */
  private drainTools(session: Session): Promise<void> {
    const list: Promise<void>[] | undefined = this.toolJobs.get(session.id);
    if (list === undefined || list.length === 0) {
      return Promise.resolve();
    }
    this.toolJobs.set(session.id, []);
    return Promise.all(list).then(() => {
      return this.drainTools(session);
    });
  }
}
