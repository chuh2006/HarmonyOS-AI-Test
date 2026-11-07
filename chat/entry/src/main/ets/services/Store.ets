import { fileIo } from '@kit.CoreFileKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Archive, Session, Turn, Segment, isBusy, normalizeOptions } from '../core/Models';
import { J } from '../core/Json';

export class Vault {
  private alias(provider: string): Uint8Array { return new util.TextEncoder().encodeInto('minichat.key.' + provider); }
  async read(provider: string): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias(provider)); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const values = await asset.query(query);
      if (values.length === 0) { return ''; }
      const bytes = values[0].get(asset.Tag.SECRET) as Uint8Array;
      return util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) { return ''; }
      throw new Error('无法读取安全存储，请解锁设备后重试');
    }
  }
  async write(provider: string, key: string): Promise<void> {
    const data: asset.AssetMap = new Map(); data.set(asset.Tag.ALIAS, this.alias(provider));
    try {
      if (key.length === 0) {
        try { await asset.remove(data); } catch (error) {
          if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw error as Error; }
        }
      } else {
        data.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(key));
        data.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
        data.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
        await asset.add(data);
      }
    } catch (_) { throw new Error('密钥保存失败，请解锁设备后重试'); }
  }
}

export class Store {
  private path: string;
  recoveryNotice: string = '';
  constructor(filesDir: string) { this.path = filesDir + '/conversations.json'; }
  load(): Archive {
    let data = new Archive();
    if (!fileIo.accessSync(this.path) && !fileIo.accessSync(this.path + '.bak')) { return data; }
    try { data = this.decode(fileIo.readTextSync(this.path)); }
    catch (_) {
      if (!fileIo.accessSync(this.path + '.bak')) { throw new Error('历史文件读取失败，原文件已保留'); }
      try { data = this.decode(fileIo.readTextSync(this.path + '.bak')); }
      catch (_) { throw new Error('历史文件与备份读取失败，原文件已保留'); }
      if (fileIo.accessSync(this.path)) { fileIo.renameSync(this.path, this.path + '.damaged-' + Date.now().toString()); }
      this.recoveryNotice = '已从上一份完整备份恢复对话';
    }
    data.sessions.forEach((session: Session) => {
      normalizeOptions(session.options);
      session.turns.forEach((turn: Turn) => {
        if (isBusy(turn.status)) {
          turn.status = 'stopped'; turn.error = '上次生成因应用退出而中断';
          turn.segments.forEach((segment: Segment) => {
            if (segment.kind === 'tool' && segment.state === 'running') { segment.state = 'stopped'; }
          });
        }
      });
    });
    return data;
  }
  private decode(text: string): Archive {
    const root = J.parse(text);
    if (root.get('version').num() !== 1 || !Array.isArray(root.get('sessions').value) ||
      !Array.isArray(root.get('providers').value)) { throw new Error('历史格式不受支持'); }
    const data = JSON.parse(text) as Archive;
    data.sessions.forEach((session: Session) => {
      if (!session.id || !session.options || !Array.isArray(session.turns)) { throw new Error('历史内容损坏'); }
      session.turns.forEach((turn: Turn) => {
        if (!Array.isArray(turn.segments) || !Array.isArray(turn.replay)) { throw new Error('消息内容损坏'); }
      });
    });
    return data;
  }
  save(data: Archive): void {
    const text = JSON.stringify(data);
    // A complete UTF-8 file avoids Preferences' per-value size limit.
    const bytes = new util.TextEncoder().encodeInto(text);
    const file = fileIo.openSync(this.path + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.byteLength) {
        const written = fileIo.writeSync(file.fd, bytes.slice(offset).buffer);
        if (written <= 0) { throw new Error('写入历史记录失败'); }
        offset += written;
      }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    if (fileIo.accessSync(this.path)) {
      // Do not replace a usable backup with an unreadable primary.
      this.decode(fileIo.readTextSync(this.path));
      fileIo.copyFileSync(this.path, this.path + '.bak');
    }
    fileIo.renameSync(this.path + '.tmp', this.path);
  }
}
