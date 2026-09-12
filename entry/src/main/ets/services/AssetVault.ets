import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

/**
 * 关键资产封装（Asset Store Kit，简称 ASSET）：
 * 服务商的密钥类凭证（ConfigField.secret = true 的字段）以「一条字段 = 一条资产」存储，
 * 明文不再落盘（Preferences 的 services_list JSON 中不含 secret 字段）。
 *
 * 设计要点：
 * - 别名 `th_cred_<serviceId>_<fieldKey>` 全局唯一；
 * - SYNC_TYPE = TRUSTED_DEVICE：手机克隆（可信设备间迁移）可携带凭证；
 *   云备份恢复不携带（TRUSTED_ACCOUNT 官方标注能力预埋），跨设备迁移走应用内加密备份；
 * - read/remove 对「资产不存在（24000002）/ 数据库未创建（24000008）」静默降级为空；
 * - 单条 SECRET 上限 1024 字节，API Key/Secret 类值远小于该限制。
 */

const ALIAS_PREFIX = 'th_cred_';

function toBytes(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function toStr(u: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(u);
}

export class AssetVault {
  /** 写入密钥（已存在则覆盖）。空串视为删除。 */
  static async write(fieldAlias: string, secret: string): Promise<void> {
    if (secret.length === 0) {
      AssetVault.remove(fieldAlias);
      return;
    }
    const alias = toBytes(ALIAS_PREFIX + fieldAlias);
    // 先删后加：同名资产 add 会报 24000001，先 remove 保证幂等
    try {
      const del: asset.AssetMap = new Map();
      del.set(asset.Tag.ALIAS, alias);
      await asset.remove(del);
    } catch (e) {
      // 资产不存在，忽略
    }
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.SECRET, toBytes(secret));
    attr.set(asset.Tag.ALIAS, alias);
    attr.set(asset.Tag.SYNC_TYPE, asset.SyncType.TRUSTED_DEVICE);
    await asset.add(attr);
  }

  /** 读取密钥（不存在/未配置返回空串） */
  static read(fieldAlias: string): string {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(ALIAS_PREFIX + fieldAlias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const res = asset.querySync(query);
      if (res.length === 0) {
        return '';
      }
      const secret = res[0].get(asset.Tag.SECRET);
      if (secret === undefined || secret === null) {
        return '';
      }
      return toStr(secret as Uint8Array);
    } catch (e) {
      // 24000002 资产不存在 / 24000008 数据库未创建（首次使用）
      return '';
    }
  }

  /** 删除资产（不存在时静默忽略） */
  static remove(fieldAlias: string): void {
    try {
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.ALIAS, toBytes(ALIAS_PREFIX + fieldAlias));
      asset.removeSync(attrs);
    } catch (e) {
      // 不存在，忽略
    }
  }
}
