/** Small shared helpers. */

let seq: number = 0;

export function newId(prefix: string): string {
  seq = seq + 1;
  const t: number = Date.now();
  const r: number = Math.floor(Math.random() * 100000);
  return prefix + '_' + t.toString(36) + '_' + seq.toString(36) + '_' + r.toString(36);
}

export function formatClock(ts: number): string {
  const d: Date = new Date(ts);
  const h: string = pad2(d.getHours());
  const m: string = pad2(d.getMinutes());
  return h + ':' + m;
}

export function formatDayTime(ts: number): string {
  const d: Date = new Date(ts);
  const now: Date = new Date();
  const sameDay: boolean = d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  if (sameDay) {
    return '今天 ' + formatClock(ts);
  }
  const y: Date = new Date(now.getTime() - 86400000);
  const isY: boolean = d.getFullYear() === y.getFullYear() &&
    d.getMonth() === y.getMonth() && d.getDate() === y.getDate();
  if (isY) {
    return '昨天 ' + formatClock(ts);
  }
  return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日 ' + formatClock(ts);
}

function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

export function truncate(text: string, max: number): string {
  if (text.length <= max) {
    return text;
  }
  return text.substring(0, max) + '…';
}

export function oneLine(text: string): string {
  let out: string = '';
  for (let i = 0; i < text.length; i++) {
    const c: string = text.charAt(i);
    if (c === '\n' || c === '\r' || c === '\t') {
      out += ' ';
    } else {
      out += c;
    }
  }
  return out.trim();
}

export function hostOf(url: string): string {
  let s: string = url.trim();
  const scheme: number = s.indexOf('://');
  if (scheme >= 0) {
    s = s.substring(scheme + 3);
  }
  const cut: number = s.indexOf('/');
  if (cut >= 0) {
    s = s.substring(0, cut);
  }
  const q: number = s.indexOf('?');
  if (q >= 0) {
    s = s.substring(0, q);
  }
  return s;
}

export function countOf(n: number, unit: string): string {
  return n.toString() + ' ' + unit;
}

/** Compact number for byte / character counts shown on tool cards. */
export function compactCount(n: number): string {
  if (n < 1000) {
    return n.toString();
  }
  if (n < 1000000) {
    const k: number = Math.floor(n / 100) / 10;
    return k.toString() + 'k';
  }
  const m: number = Math.floor(n / 100000) / 10;
  return m.toString() + 'M';
}
