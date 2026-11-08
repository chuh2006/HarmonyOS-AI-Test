/**
 * Provider adapter contract. Each adapter knows how to turn the stored
 * conversation into one provider's wire format and how to fold that
 * provider's stream back into the shared block model.
 */
import { Msg, Session } from './Types';

export class RequestSpec {
  url: string = '';
  headers: Record<string, string> = {};
  bodyJson: string = '';
}

/**
 * Implemented by the chat engine. All streaming updates arrive here and are
 * mapped onto the blocks of the assistant message under construction.
 */
export interface TurnSink {
  /** Reasoning text. replace=true means the draft overwrites the current block (diffusion). */
  thinking(text: string, replace: boolean): void;

  /** Answer text. replace=true means the draft overwrites the current block (diffusion). */
  text(text: string, replace: boolean): void;

  /** A tool call block appears (or is renamed). */
  toolStart(callId: string, name: string): void;

  /** More tool arguments for a call. */
  toolArgs(callId: string, delta: string): void;

  /** The arguments of a call are complete; the engine may execute it. */
  toolEnd(callId: string): void;

  /** Snapshot of the provider raw payload needed to replay this turn. */
  proto(protoJson: string): void;

  /** The provider signalled a clean end of the response. */
  end(): void;

  /** The provider reported an error. */
  fail(message: string): void;

  /** True once the user stopped the generation. */
  isStopped(): boolean;
}

/** Feeds one SSE event at a time into the provider specific state machine. */
export interface TurnHandler {
  handleEvent(name: string, data: string): void;

  /** Connection closed. */
  handleEnd(): void;
}

export interface ProviderAdapter {
  buildRequest(session: Session, messages: Msg[], toolsEnabled: boolean,
    apiKey: string, baseUrl: string): RequestSpec;

  createTurn(sink: TurnSink, session: Session): TurnHandler;
}

/** Strip trailing slashes for safe path concatenation. */
export function trimSlash(url: string): string {
  let s: string = url.trim();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
