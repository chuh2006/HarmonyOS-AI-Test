export class SseEvent {
  event: string;
  data: string;
  constructor(event: string, data: string) { this.event = event; this.data = data; }
}

// Network framing only; UTF-8 decoding is performed by the platform decoder.
export class SseParser {
  private line: string = '';
  private event: string = '';
  private data: string[] = [];
  private afterCR: boolean = false;
  private first: boolean = true;
  private size: number = 0;
  private onEvent: (event: SseEvent) => void;
  constructor(onEvent: (event: SseEvent) => void) { this.onEvent = onEvent; }
  push(text: string): void {
    for (let i = 0; i < text.length; i++) {
      const c = text.charAt(i);
      if (this.first) { this.first = false; if (c === '\uFEFF') { continue; } }
      if (this.afterCR && c === '\n') { this.afterCR = false; continue; }
      this.afterCR = false;
      if (c === '\r' || c === '\n') {
        this.consumeLine(); this.afterCR = c === '\r';
      } else {
        this.line += c;
        if (++this.size > 8 * 1024 * 1024) { throw new Error('服务返回的单个事件过大'); }
      }
    }
  }
  finish(): void { if (this.line.length > 0) { this.consumeLine(); } this.dispatch(); }
  private consumeLine(): void {
    const line = this.line; this.line = '';
    if (line.length === 0) { this.dispatch(); return; }
    if (line.startsWith(':')) { return; }
    const split = line.indexOf(':');
    const field = split < 0 ? line : line.slice(0, split);
    let value = split < 0 ? '' : line.slice(split + 1);
    if (value.startsWith(' ')) { value = value.slice(1); }
    if (field === 'data') { this.data.push(value); }
    if (field === 'event') { this.event = value; }
  }
  private dispatch(): void {
    const data = this.data; const event = this.event;
    this.data = []; this.event = ''; this.size = 0;
    if (data.length > 0) { this.onEvent(new SseEvent(event, data.join('\n'))); }
  }
}
