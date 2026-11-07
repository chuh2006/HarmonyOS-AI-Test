import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProviderId } from '../model/Types';
import { providerInfo } from '../model/Catalog';

const PREF_NAME = 'minichat_settings';

function toBytes(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function fromBytes(b: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(b);
}

function keyAlias(p: ProviderId): string {
  return `minichat_apikey_${p as string}`;
}

@ObservedV2
export class SettingsStore {
  private static instance: SettingsStore | null = null;
  private pref: preferences.Preferences | null = null;
  private baseUrls: Map<string, string> = new Map();
  private keyCache: Map<string, string> = new Map();
  @Trace hasDeepSeekKey: boolean = false;
  @Trace hasOpenAIKey: boolean = false;
  @Trace hasMercuryKey: boolean = false;
  @Trace hasGeminiKey: boolean = false;

  static getInstance(): SettingsStore {
    if (SettingsStore.instance === null) {
      SettingsStore.instance = new SettingsStore();
    }
    return SettingsStore.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.pref = await preferences.getPreferences(context, PREF_NAME);
    const ids: ProviderId[] = [ProviderId.DEEPSEEK, ProviderId.OPENAI, ProviderId.MERCURY, ProviderId.GEMINI];
    for (const p of ids) {
      const url = this.pref.getSync(`baseurl_${p as string}`, '') as string;
      if (url.length > 0) {
        this.baseUrls.set(p as string, url);
      }
      try {
        const key = await this.queryKey(p);
        if (key.length > 0) {
          this.keyCache.set(p as string, key);
          this.markKey(p, true);
        }
      } catch (e) {
        // 无已保存 Key 时忽略
      }
    }
  }

  getBaseUrl(p: ProviderId): string {
    const saved = this.baseUrls.get(p as string);
    if (saved !== undefined && saved.length > 0) {
      return saved;
    }
    return providerInfo(p).defaultBaseUrl;
  }

  async setBaseUrl(p: ProviderId, url: string): Promise<void> {
    const trimmed = url.trim();
    if (trimmed.length === 0 || trimmed === providerInfo(p).defaultBaseUrl) {
      this.baseUrls.delete(p as string);
      await this.pref?.delete(`baseurl_${p as string}`);
    } else {
      this.baseUrls.set(p as string, trimmed);
      await this.pref?.put(`baseurl_${p as string}`, trimmed);
    }
    await this.pref?.flush();
  }

  private async queryKey(p: ProviderId): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(keyAlias(p)));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const res: Array<asset.AssetMap> = await asset.query(query);
    if (res.length === 0) {
      return '';
    }
    const secret = res[0].get(asset.Tag.SECRET);
    if (secret === undefined) {
      return '';
    }
    return fromBytes(secret as Uint8Array);
  }

  async getKey(p: ProviderId): Promise<string> {
    const cached = this.keyCache.get(p as string);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const key = await this.queryKey(p);
      this.keyCache.set(p as string, key);
      this.markKey(p, key.length > 0);
      return key;
    } catch (e) {
      return '';
    }
  }

  async setKey(p: ProviderId, key: string): Promise<void> {
    const trimmed = key.trim();
    if (trimmed.length === 0) {
      const del: asset.AssetMap = new Map();
      del.set(asset.Tag.ALIAS, toBytes(keyAlias(p)));
      try {
        await asset.remove(del);
      } catch (e) {
        // 不存在时忽略
      }
      this.keyCache.delete(p as string);
      this.markKey(p, false);
      return;
    }
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, toBytes(keyAlias(p)));
    attrs.set(asset.Tag.SECRET, toBytes(trimmed));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attrs);
    this.keyCache.set(p as string, trimmed);
    this.markKey(p, true);
  }

  private markKey(p: ProviderId, present: boolean): void {
    switch (p) {
      case ProviderId.DEEPSEEK: this.hasDeepSeekKey = present; break;
      case ProviderId.OPENAI: this.hasOpenAIKey = present; break;
      case ProviderId.MERCURY: this.hasMercuryKey = present; break;
      case ProviderId.GEMINI: this.hasGeminiKey = present; break;
      default: break;
    }
  }

  hasKey(p: ProviderId): boolean {
    switch (p) {
      case ProviderId.DEEPSEEK: return this.hasDeepSeekKey;
      case ProviderId.OPENAI: return this.hasOpenAIKey;
      case ProviderId.MERCURY: return this.hasMercuryKey;
      case ProviderId.GEMINI: return this.hasGeminiKey;
      default: return false;
    }
  }

  getLastProvider(): ProviderId {
    const v = this.pref?.getSync('last_provider', ProviderId.DEEPSEEK as string) as string;
    return v as ProviderId;
  }

  getLastModel(): string {
    return this.pref?.getSync('last_model', 'deepseek-flash') as string;
  }

  async setLast(provider: ProviderId, model: string): Promise<void> {
    await this.pref?.put('last_provider', provider as string);
    await this.pref?.put('last_model', model);
    await this.pref?.flush();
  }

  getCurrentConversationId(): string {
    return this.pref?.getSync('current_conversation', '') as string;
  }

  async setCurrentConversationId(id: string): Promise<void> {
    await this.pref?.put('current_conversation', id);
    await this.pref?.flush();
  }
}