import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/**
 * 哈希工具：腾讯云 TC3 签名与百度 MD5 签名共用。
 * cryptoFramework 全部走异步接口，这里封装成 Promise。
 */

async function digest(alg: string, data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd(alg);
  await md.update({ data: data });
  const out = await md.digest();
  return out.data;
}

export function utf8(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

export async function sha256Hex(s: string): Promise<string> {
  // cryptoFramework 算法名不带连字符（SHA256，非 SHA-256），见 MD 算法规格文档
  const out = await digest('SHA256', utf8(s));
  return toHex(out);
}

export async function hmacSha256Hex(key: Uint8Array, data: string): Promise<string> {
  const out = await hmac(key, data);
  return toHex(out);
}

export async function hmacSha256Raw(key: Uint8Array, data: string): Promise<Uint8Array> {
  return hmac(key, data);
}

/** HMAC-SHA1 → Base64（阿里云 RPC 签名用） */
export async function hmacSha1Base64(key: Uint8Array, data: string): Promise<string> {
  const symKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
  const keyBlob: cryptoFramework.DataBlob = { data: key };
  const symKey = await symKeyGenerator.convertKey(keyBlob);
  const mac = cryptoFramework.createMac('SHA1');
  await mac.init(symKey);
  await mac.update({ data: utf8(data) } as cryptoFramework.DataBlob);
  const out: cryptoFramework.DataBlob = await mac.doFinal();
  return new util.Base64Helper().encodeToStringSync(out.data);
}

export async function md5Hex(s: string): Promise<string> {
  const out = await digest('MD5', utf8(s));
  return toHex(out);
}

async function hmac(key: Uint8Array, data: string): Promise<Uint8Array> {
  const symKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
  const keyBlob: cryptoFramework.DataBlob = { data: key };
  const symKey = await symKeyGenerator.convertKey(keyBlob);
  const mac = cryptoFramework.createMac('SHA256');
  await mac.init(symKey);
  await mac.update({ data: utf8(data) } as cryptoFramework.DataBlob);
  const out: cryptoFramework.DataBlob = await mac.doFinal();
  return out.data;
}

function toHex(bytes: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, '0');
  }
  return hex;
}
