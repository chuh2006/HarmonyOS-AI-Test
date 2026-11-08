/**
 * Conversation persistence. Sessions live as JSON files under the app's
 * files directory; the full protocol payload of every message (thinking,
 * Gemini parts + signatures, tool calls and results) is stored alongside the
 * renderable content so that a conversation can be continued after a restart.
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { Block, Msg, Session, SessionOptions } from './Types';
import { asArr, asRecord, getArr, getBool, getNum, getObj, getStr, parseObj } from '../common/JsonUtil';

function hydrateBlock(o: Record<string, Object>): Block {
  const b: Block = new Block();
  b.uid = getStr(o, 'uid');
  b.kind = getStr(o, 'kind');
  b.text = getStr(o, 'text');
  b.uiOpen = getBool(o, 'uiOpen');
  b.uiTouched = getBool(o, 'uiTouched');
  b.toolId = getStr(o, 'toolId');
  b.toolName = getStr(o, 'toolName');
  b.toolTitle = getStr(o, 'toolTitle');
  b.toolArgs = getStr(o, 'toolArgs');
  b.toolStatus = getStr(o, 'toolStatus');
  b.toolSummary = getStr(o, 'toolSummary');
  b.toolDetail = getStr(o, 'toolDetail');
  b.toolResult = getStr(o, 'toolResult');
  b.toolFinished = getBool(o, 'toolFinished');
  return b;
}

function hydrateMsg(o: Record<string, Object>): Msg {
  const m: Msg = new Msg();
  m.id = getStr(o, 'id');
  m.role = getStr(o, 'role');
  m.status = getStr(o, 'status');
  m.errorText = getStr(o, 'errorText');
  m.createdAt = getNum(o, 'createdAt');
  m.proto = getStr(o, 'proto');
  m.protoProvider = getStr(o, 'protoProvider');
  m.modelLabel = getStr(o, 'modelLabel');
  const arr: Object[] = getArr(o, 'blocks');
  for (let i = 0; i < arr.length; i++) {
    m.blocks.push(hydrateBlock(asRecord(arr[i])));
  }
  return m;
}

function hydrateOptions(o: Record<string, Object>): SessionOptions {
  const s: SessionOptions = new SessionOptions();
  if (o['thinkingOn'] !== undefined) {
    s.thinkingOn = getBool(o, 'thinkingOn');
  }
  const lvl: string = getStr(o, 'thinkingLevel');
  if (lvl.length > 0) {
    s.thinkingLevel = lvl;
  }
  const mode: string = getStr(o, 'reasoningMode');
  if (mode.length > 0) {
    s.reasoningMode = mode;
  }
  const tier: string = getStr(o, 'speedTier');
  if (tier.length > 0) {
    s.speedTier = tier;
  }
  if (o['diffusing'] !== undefined) {
    s.diffusing = getBool(o, 'diffusing');
  }
  return s;
}

function hydrateSession(o: Record<string, Object>): Session {
  const s: Session = new Session();
  s.id = getStr(o, 'id');
  s.title = getStr(o, 'title');
  s.createdAt = getNum(o, 'createdAt');
  s.updatedAt = getNum(o, 'updatedAt');
  s.providerId = getStr(o, 'providerId');
  s.modelId = getStr(o, 'modelId');
  s.options = hydrateOptions(getObj(o, 'options'));
  const arr: Object[] = getArr(o, 'messages');
  for (let i = 0; i < arr.length; i++) {
    s.messages.push(hydrateMsg(asRecord(arr[i])));
  }
  return s;
}

export class SessionStore {
  private static dir: string = '';
  private static ready: boolean = false;

  static init(filesDir: string): void {
    SessionStore.dir = filesDir + '/sessions';
    try {
      if (!fs.accessSync(SessionStore.dir)) {
        fs.mkdirSync(SessionStore.dir, true);
      }
    } catch (e) {
      try {
        fs.mkdirSync(SessionStore.dir, true);
      } catch (e2) {
        // ignore
      }
    }
    SessionStore.ready = true;
  }

  private static pathOf(id: string): string {
    return SessionStore.dir + '/' + id + '.json';
  }

  static loadAll(): Session[] {
    const out: Session[] = [];
    if (!SessionStore.ready) {
      return out;
    }
    try {
      const names: string[] = fs.listFileSync(SessionStore.dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (!name.endsWith('.json')) {
          continue;
        }
        try {
          const text: string = fs.readTextSync(SessionStore.pathOf(name.substring(0, name.length - 5)));
          const s: Session = hydrateSession(parseObj(text));
          if (s.id.length > 0) {
            out.push(s);
          }
        } catch (e) {
          // skip broken files
        }
      }
    } catch (e) {
      // ignore
    }
    out.sort((a: Session, b: Session): number => {
      return b.updatedAt - a.updatedAt;
    });
    return out;
  }

  static save(session: Session): void {
    if (!SessionStore.ready) {
      return;
    }
    try {
      const text: string = JSON.stringify(session);
      const file = fs.openSync(SessionStore.pathOf(session.id),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
    } catch (e) {
      // persistence must never break the chat flow
    }
  }

  static remove(id: string): void {
    if (!SessionStore.ready) {
      return;
    }
    try {
      if (fs.accessSync(SessionStore.pathOf(id))) {
        fs.unlinkSync(SessionStore.pathOf(id));
      }
    } catch (e) {
      // ignore
    }
  }

  private static settingsPath(): string {
    return SessionStore.dir + '/_settings.json';
  }

  /** Non-secret settings such as base URLs and the last opened session. */
  static loadSettings(): Record<string, Object> {
    try {
      const text: string = fs.readTextSync(SessionStore.settingsPath());
      return parseObj(text);
    } catch (e) {
      return {};
    }
  }

  static saveSettings(o: Record<string, Object>): void {
    try {
      const file = fs.openSync(SessionStore.settingsPath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(o));
      fs.closeSync(file);
    } catch (e) {
      // ignore
    }
  }
}
