import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Conversation, ConversationData } from '../model/Types';

export class ConversationFiles {
  private dir: string = '';

  init(context: common.UIAbilityContext): void {
    this.dir = `${context.filesDir}/conversations`;
    if (!fs.accessSync(this.dir)) {
      fs.mkdirSync(this.dir);
    }
  }

  save(conv: Conversation): void {
    if (this.dir.length === 0) {
      return;
    }
    const path = `${this.dir}/${conv.id}.json`;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(conv.toData()));
    } finally {
      fs.closeSync(file);
    }
  }

  loadAll(): Conversation[] {
    const out: Conversation[] = [];
    if (this.dir.length === 0 || !fs.accessSync(this.dir)) {
      return out;
    }
    const names = fs.listFileSync(this.dir);
    for (const name of names) {
      if (!name.endsWith('.json')) {
        continue;
      }
      try {
        const text = fs.readTextSync(`${this.dir}/${name}`);
        const data = JSON.parse(text) as ConversationData;
        out.push(Conversation.fromData(data));
      } catch (e) {
        // 单个会话损坏时跳过，不影响其他会话
      }
    }
    out.sort((a: Conversation, b: Conversation) => b.updatedAt - a.updatedAt);
    return out;
  }

  delete(id: string): void {
    const path = `${this.dir}/${id}.json`;
    if (this.dir.length > 0 && fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  }
}