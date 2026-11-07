import { Conversation, ChatMessage, MessageBlock, BlockKind, ToolStatus, MsgStatus, ProviderId } from '../model/Types';
import { StreamHandle, ChatError } from '../net/HttpClient';
import { ProviderAdapter, StreamSink, ToolCallInfo, PhaseResult } from '../providers/Base';
import { DeepSeekAdapter } from '../providers/DeepSeekAdapter';
import { OpenAIAdapter } from '../providers/OpenAIAdapter';
import { MercuryAdapter } from '../providers/MercuryAdapter';
import { GeminiAdapter } from '../providers/GeminiAdapter';
import { ToolService } from '../tools/ToolService';

const MAX_TOOL_ROUNDS = 8;

export interface EngineHost {
  getKey: (p: ProviderId) => Promise<string>;
  getBaseUrl: (p: ProviderId) => string;
  persist: (conv: Conversation) => void;
  onChanged: () => void;
}

export function adapterFor(p: ProviderId): ProviderAdapter {
  switch (p) {
    case ProviderId.DEEPSEEK: return new DeepSeekAdapter();
    case ProviderId.OPENAI: return new OpenAIAdapter();
    case ProviderId.MERCURY: return new MercuryAdapter();
    case ProviderId.GEMINI: return new GeminiAdapter();
    default: return new DeepSeekAdapter();
  }
}

class EngineSink implements StreamSink {
  private msg: ChatMessage;
  private engine: ChatEngine;
  private runId: number;
  private forceNewText: boolean = true;
  private forceNewThinking: boolean = true;
  private blockSeq: number = 0;

  constructor(msg: ChatMessage, engine: ChatEngine, runId: number) {
    this.msg = msg;
    this.engine = engine;
    this.runId = runId;
  }

  beginPhase(): void {
    this.forceNewText = true;
    this.forceNewThinking = true;
  }

  private alive(): boolean {
    return this.engine.currentRunId() === this.runId;
  }

  private newBlock(kind: BlockKind): MessageBlock {
    this.blockSeq++;
    const b = new MessageBlock(kind, `${this.msg.id}_s${this.blockSeq}`);
    this.msg.blocks.push(b);
    return b;
  }

  private lastBlock(): MessageBlock | null {
    return this.msg.blocks.length > 0 ? this.msg.blocks[this.msg.blocks.length - 1] : null;
  }

  status(s: MsgStatus): void {
    if (this.alive()) {
      this.msg.status = s;
    }
  }

  thinkingDelta(text: string): void {
    if (!this.alive() || text.length === 0) {
      return;
    }
    const last = this.lastBlock();
    let target: MessageBlock;
    if (this.forceNewThinking || last === null || last.kind !== BlockKind.THINKING) {
      target = this.newBlock(BlockKind.THINKING);
      this.forceNewThinking = false;
    } else {
      target = last;
    }
    target.text += text;
    this.engine.touch();
  }

  textDelta(text: string): void {
    if (!this.alive() || text.length === 0) {
      return;
    }
    const last = this.lastBlock();
    let target: MessageBlock;
    if (this.forceNewText || last === null || last.kind !== BlockKind.TEXT) {
      target = this.newBlock(BlockKind.TEXT);
      this.forceNewText = false;
    } else {
      target = last;
    }
    target.text += text;
    this.engine.touch();
  }

  textSnapshot(text: string): void {
    if (!this.alive()) {
      return;
    }
    const last = this.lastBlock();
    let target: MessageBlock;
    if (this.forceNewText || last === null || last.kind !== BlockKind.TEXT) {
      target = this.newBlock(BlockKind.TEXT);
      this.forceNewText = false;
    } else {
      target = last;
    }
    target.text = text;
    this.engine.touch();
  }

  newTextBlock(): void {
    this.forceNewText = true;
  }

  toolStart(id: string, name: string): void {
    if (!this.alive() || id.length === 0) {
      return;
    }
    if (this.msg.findToolBlock(id) !== null) {
      return;
    }
    const b = this.newBlock(BlockKind.TOOL);
    b.toolId = id;
    b.toolName = name;
    b.toolStatus = ToolStatus.STREAMING;
    this.forceNewText = true;
    this.forceNewThinking = true;
    this.engine.touch();
  }

  toolArgs(id: string, fragment: string): void {
    if (!this.alive()) {
      return;
    }
    const b = this.msg.findToolBlock(id);
    if (b !== null) {
      b.toolArgs += fragment;
    }
  }

  toolReady(id: string, argsJson: string): void {
    if (!this.alive()) {
      return;
    }
    const b = this.msg.findToolBlock(id);
    if (b !== null) {
      b.toolArgs = argsJson;
      if (b.toolStatus === ToolStatus.STREAMING) {
        b.toolStatus = ToolStatus.WAITING;
      }
      this.engine.touch();
    }
  }

  usage(text: string): void {
    if (this.alive()) {
      this.msg.usageText = text;
    }
  }
}

export class ChatEngine {
  private runId: number = 0;
  private running: boolean = false;
  private handles: StreamHandle[] = [];
  private currentConv: Conversation | null = null;
  private currentMsg: ChatMessage | null = null;
  private host: EngineHost | null = null;
  private saveTimer: number = -1;

  currentRunId(): number {
    return this.runId;
  }

  isRunning(): boolean {
    return this.running;
  }

  touch(): void {
    const host = this.host;
    const conv = this.currentConv;
    if (host === null || conv === null) {
      return;
    }
    host.onChanged();
    if (this.saveTimer < 0) {
      this.saveTimer = setTimeout(() => {
        this.saveTimer = -1;
        if (this.currentConv !== null && this.host !== null) {
          this.host.persist(this.currentConv);
        }
      }, 2000);
    }
  }

  stop(): void {
    this.runId++;
    this.running = false;
    for (const h of this.handles) {
      h.abort();
    }
    this.handles = [];
    const msg = this.currentMsg;
    const conv = this.currentConv;
    if (msg !== null && conv !== null) {
      msg.status = MsgStatus.STOPPED;
      this.finalizeTools(msg);
      this.collapseThinking(msg);
      if (this.host !== null) {
        this.host.persist(conv);
        this.host.onChanged();
      }
    }
    this.currentMsg = null;
    this.currentConv = null;
  }

  async run(conv: Conversation, msg: ChatMessage, host: EngineHost): Promise<void> {
    if (this.running) {
      this.stop();
    }
    this.runId++;
    const myRun = this.runId;
    this.running = true;
    this.currentConv = conv;
    this.currentMsg = msg;
    this.host = host;
    const sink = new EngineSink(msg, this, myRun);
    try {
      const key = await host.getKey(conv.provider);
      if (this.runId !== myRun) {
        return;
      }
      if (key.length === 0) {
        msg.status = MsgStatus.FAILED;
        msg.error = '请先在设置中填写该服务商的 API Key';
        host.persist(conv);
        host.onChanged();
        return;
      }
      const dsKey = await host.getKey(ProviderId.DEEPSEEK);
      const baseUrl = host.getBaseUrl(conv.provider);
      const dsBase = host.getBaseUrl(ProviderId.DEEPSEEK);
      const adapter = adapterFor(conv.provider);
      let rounds = 0;
      let exhausted = false;
      while (rounds < MAX_TOOL_ROUNDS) {
        if (this.runId !== myRun) {
          return;
        }
        sink.beginPhase();
        const handle = new StreamHandle();
        this.handles.push(handle);
        let result: PhaseResult = new PhaseResult();
        try {
          result = await adapter.streamPhase(conv, key, baseUrl, sink, handle);
        } finally {
          this.removeHandle(handle);
        }
        if (this.runId !== myRun) {
          return;
        }
        msg.phases.push(result.payload);
        conv.updatedAt = Date.now();
        host.persist(conv);
        if (result.toolCalls.length === 0) {
          break;
        }
        msg.status = MsgStatus.TOOL;
        host.onChanged();
        const jobs: Promise<void>[] = [];
        for (const tc of result.toolCalls) {
          jobs.push(this.execTool(conv, msg, tc, dsKey, dsBase, myRun, host));
        }
        await Promise.all(jobs);
        if (this.runId !== myRun) {
          return;
        }
        host.persist(conv);
        rounds++;
        if (rounds >= MAX_TOOL_ROUNDS) {
          exhausted = true;
        }
      }
      if (this.runId !== myRun) {
        return;
      }
      if (exhausted) {
        const note = new MessageBlock(BlockKind.TEXT, `${msg.id}_limit`);
        note.text = '\n\n（已达到工具调用次数上限，以上为当前结果。）';
        msg.blocks.push(note);
      }
      msg.status = MsgStatus.DONE;
      this.collapseThinking(msg);
    } catch (e) {
      if (this.runId !== myRun) {
        return;
      }
      if (e instanceof ChatError && e.aborted) {
        msg.status = MsgStatus.STOPPED;
      } else {
        msg.status = MsgStatus.FAILED;
        msg.error = e instanceof Error ? e.message : '发生未知错误';
      }
      this.finalizeTools(msg);
      this.collapseThinking(msg);
    } finally {
      if (this.runId === myRun) {
        this.running = false;
        this.currentMsg = null;
        this.currentConv = null;
        if (this.saveTimer >= 0) {
          clearTimeout(this.saveTimer);
          this.saveTimer = -1;
        }
        host.persist(conv);
        host.onChanged();
      }
    }
  }

  private async execTool(conv: Conversation, msg: ChatMessage, tc: ToolCallInfo,
    dsKey: string, dsBase: string, myRun: number, host: EngineHost): Promise<void> {
    const block = msg.findToolBlock(tc.id);
    if (block !== null) {
      block.toolStatus = ToolStatus.RUNNING;
      host.onChanged();
    }
    const handle = new StreamHandle();
    this.handles.push(handle);
    try {
      const res = await ToolService.execute(tc.name, tc.argsJson, dsKey, dsBase, handle);
      if (this.runId !== myRun) {
        return;
      }
      if (block !== null) {
        block.toolResult = res.result;
        block.toolDisplay = res.display;
        block.toolError = res.error;
        block.toolStatus = res.ok ? ToolStatus.DONE : ToolStatus.ERROR;
      }
    } catch (e) {
      if (this.runId !== myRun) {
        return;
      }
      if (block !== null) {
        block.toolStatus = ToolStatus.STOPPED;
        block.toolResult = '{"error":"工具执行被停止。"}';
        block.toolDisplay = '已停止';
      }
    } finally {
      this.removeHandle(handle);
    }
  }

  private removeHandle(h: StreamHandle): void {
    const idx = this.handles.indexOf(h);
    if (idx >= 0) {
      this.handles.splice(idx, 1);
    }
  }

  private finalizeTools(msg: ChatMessage): void {
    for (const b of msg.blocks) {
      if (b.kind !== BlockKind.TOOL) {
        continue;
      }
      if (b.toolStatus === ToolStatus.DONE || b.toolStatus === ToolStatus.ERROR) {
        continue;
      }
      b.toolStatus = ToolStatus.STOPPED;
      if (b.toolResult.length === 0) {
        b.toolResult = '{"error":"工具未执行：生成已停止。请基于已有信息继续。"}';
      }
      if (b.toolDisplay.length === 0) {
        b.toolDisplay = '已停止';
      }
    }
  }

  private collapseThinking(msg: ChatMessage): void {
    for (const b of msg.blocks) {
      if (b.kind === BlockKind.THINKING) {
        b.collapsed = true;
      }
    }
  }
}