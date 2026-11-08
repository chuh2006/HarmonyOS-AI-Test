/**
 * Incremental Server-Sent Events parser.
 *
 * Correctly handles:
 *  - an event split across arbitrary network chunks
 *  - several events inside one chunk
 *  - LF / CRLF / CR line endings, including a CRLF pair split across chunks
 *  - comment lines used as keep-alives
 *  - frames without an event name (e.g. DeepSeek's unnamed error frames)
 *  - buffered data that never saw a trailing blank line before close
 */
export class SseParser {
  private buf: string = '';
  private evName: string = '';
  private dataLines: string[] = [];
  /** Invoked for every complete event. name is '' when the frame is unnamed. */
  onEvent: (name: string, data: string) => void = (name: string, data: string) => {
  };

  push(chunk: string): void {
    if (chunk.length === 0) {
      return;
    }
    this.buf += chunk;
    while (true) {
      const idx: number = this.findBreak(this.buf);
      if (idx < 0) {
        break;
      }
      const ch: string = this.buf.charAt(idx);
      let lineEnd: number = idx + 1;
      if (ch === '\r') {
        if (idx === this.buf.length - 1) {
          // Might be the first half of a CRLF pair split across chunks.
          break;
        }
        if (this.buf.charAt(idx + 1) === '\n') {
          lineEnd = idx + 2;
        }
      }
      const line: string = this.buf.substring(0, idx);
      this.buf = this.buf.substring(lineEnd);
      this.handleLine(line);
    }
  }

  /** Feed any buffered trailing data at connection close. */
  flush(): void {
    if (this.buf.length > 0) {
      const line: string = this.buf;
      this.buf = '';
      this.handleLine(line);
    }
    this.dispatch();
  }

  private findBreak(s: string): number {
    for (let i = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      if (c === '\n' || c === '\r') {
        return i;
      }
    }
    return -1;
  }

  private handleLine(line: string): void {
    if (line.length === 0) {
      this.dispatch();
      return;
    }
    if (line.charAt(0) === ':') {
      // keep-alive comment
      return;
    }
    let field: string = line;
    let value: string = '';
    const colon: number = line.indexOf(':');
    if (colon >= 0) {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.charAt(0) === ' ') {
        value = value.substring(1);
      }
    }
    if (field === 'event') {
      this.evName = value;
    } else if (field === 'data') {
      this.dataLines.push(value);
    }
    // "id" and unknown fields are ignored.
  }

  private dispatch(): void {
    if (this.dataLines.length === 0) {
      this.evName = '';
      return;
    }
    let data: string = '';
    for (let i = 0; i < this.dataLines.length; i++) {
      if (i > 0) {
        data += '\n';
      }
      data += this.dataLines[i];
    }
    const name: string = this.evName;
    this.dataLines = [];
    this.evName = '';
    this.onEvent(name, data);
  }
}
