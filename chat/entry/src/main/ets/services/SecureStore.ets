/**
 * API keys are stored with the platform's Asset Store Kit, which keeps
 * sensitive values in the secure on-device store. Keys are never hardcoded,
 * never written to logs and never leave the secure store except to be sent
 * in an Authorization header.
 */
import { asset } from '@kit.AssetStoreKit';
import util from '@ohos.util';

const ALIAS_PREFIX: string = 'minichat.apikey.';

function toBytes(text: string): Uint8Array {
  const enc: util.TextEncoder = util.TextEncoder.create();
  return enc.encodeInto(text);
}

function toText(bytes: Uint8Array): string {
  const dec: util.TextDecoder = util.TextDecoder.create('utf-8', { 'ignoreBOM': true });
  return dec.decodeToString(bytes);
}

function aliasOf(providerId: string): string {
  return ALIAS_PREFIX + providerId;
}

export class SecureStore {
  /** Save (or replace) the API key of one provider. */
  static setKey(providerId: string, value: string): Promise<void> {
    const alias: string = aliasOf(providerId);
    if (value.length === 0) {
      return SecureStore.removeInternal(alias);
    }
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, toBytes(alias));
    attrs.set(asset.Tag.SECRET, toBytes(value));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(alias));
    return new Promise((resolve: () => void) => {
      asset.update(query, attrs).then(() => {
        resolve();
      }).catch(() => {
        const addAttrs: asset.AssetMap = new Map();
        addAttrs.set(asset.Tag.ALIAS, toBytes(alias));
        addAttrs.set(asset.Tag.SECRET, toBytes(value));
        addAttrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
        addAttrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
        asset.add(addAttrs).then(() => {
          resolve();
        }).catch(() => {
          resolve();
        });
      });
    });
  }

  /** Read the API key of one provider ('' when missing). */
  static getKey(providerId: string): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(aliasOf(providerId)));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    return new Promise((resolve: (v: string) => void) => {
      asset.query(query).then((rows: asset.AssetMap[]) => {
        if (rows.length === 0) {
          resolve('');
          return;
        }
        const secret: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
        if (secret === undefined || typeof secret !== 'object') {
          resolve('');
          return;
        }
        resolve(toText(secret as Uint8Array));
      }).catch(() => {
        resolve('');
      });
    });
  }

  static removeKey(providerId: string): Promise<void> {
    return SecureStore.removeInternal(aliasOf(providerId));
  }

  private static removeInternal(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(alias));
    return new Promise((resolve: () => void) => {
      asset.remove(query).then(() => {
        resolve();
      }).catch(() => {
        resolve();
      });
    });
  }
}
