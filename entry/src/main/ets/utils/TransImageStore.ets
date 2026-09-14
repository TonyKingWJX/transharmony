import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { historyStore } from '../services/HistoryStore';

/**
 * 图片翻译留图（应用沙箱）：
 * - 翻译成功后把照片生成压缩副本（最长边 1080px、JPEG 质量 80）存入
 *   filesDir/trans_images/，相对路径写入历史记录 meta；页面销毁即焚的是 PixelMap，
 *   沙箱副本随历史记录保留，详情页/回收站恢复期间均可见。
 * - 彻底删除/清空回收站后调用 cleanOrphans 清理无记录引用的文件。
 * - 备份不再携带图片（v2 起）：跨设备恢复时详情页回退 meta 内嵌缩略图展示。
 */

/** 历史记录 meta 中的图片信息（写入/读取 JSON） */
export interface HistoryImageMeta {
  /** 240px 缩略图 base64 data URI（沙箱文件缺失时的兜底展示） */
  thumb: string;
  /** 沙箱相对路径 trans_images/xxx.jpg（空串=无原图文件） */
  imgPath: string;
}

const DIR_NAME = 'trans_images';
const MAX_EDGE_PX = 1080;

export class TransImageStore {
  static dir(ctx: common.Context): string {
    return ctx.filesDir + '/' + DIR_NAME;
  }

  static absPath(ctx: common.Context, rel: string): string {
    return ctx.filesDir + '/' + rel;
  }

  private static ensureDir(ctx: common.Context): boolean {
    const dir = TransImageStore.dir(ctx);
    try {
      fs.accessSync(dir);
      return true;
    } catch (e) {
      // 目录不存在
    }
    try {
      fs.mkdirSync(dir);
      return true;
    } catch (e) {
      return false;
    }
  }

  private static fileExists(ctx: common.Context, rel: string): boolean {
    try {
      fs.accessSync(TransImageStore.absPath(ctx, rel));
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 翻译成功后调用：生成 {thumb, imgPath} meta JSON。
   * thumb=240px base64 缩略图；imgPath=沙箱 1080px 副本相对路径。
   * 任一失败不阻断翻译主流程（meta 相应字段留空）。
   */
  static async makeMeta(ctx: common.Context, pm: image.PixelMap): Promise<string> {
    try {
      // 一次打包，两路缩放：q92 打包原图 → 240px 解码出缩略图 → 1080px 解码出沙箱副本
      const p1 = image.createImagePacker();
      const full: ArrayBuffer = await p1.packToData(pm, { format: 'image/jpeg', quality: 92 });
      p1.release();
      const src = image.createImageSource(full);
      const info = await src.getImageInfo();
      const scaleOf = (maxPx: number): number =>
        Math.min(1, maxPx / Math.max(1, Math.max(info.size.width, info.size.height)));

      // 缩略图（240px，base64）
      let thumb = '';
      try {
        const tOpts: image.DecodingOptions = {
          desiredSize: {
            width: Math.max(1, Math.round(info.size.width * scaleOf(240))),
            height: Math.max(1, Math.round(info.size.height * scaleOf(240)))
          }
        };
        const tPm = await src.createPixelMap(tOpts);
        const p2 = image.createImagePacker();
        const tBuf: ArrayBuffer = await p2.packToData(tPm, { format: 'image/jpeg', quality: 60 });
        p2.release();
        thumb = 'data:image/jpeg;base64,'
          + new util.Base64Helper().encodeToStringSync(new Uint8Array(tBuf));
        tPm.release();
      } catch (e) {
        // 缩略图失败不阻断
      }

      // 沙箱原图副本（1080px，JPEG q80）
      let imgPath = '';
      if (TransImageStore.ensureDir(ctx)) {
        try {
          const oOpts: image.DecodingOptions = {
            desiredSize: {
              width: Math.max(1, Math.round(info.size.width * scaleOf(MAX_EDGE_PX))),
              height: Math.max(1, Math.round(info.size.height * scaleOf(MAX_EDGE_PX)))
            }
          };
          const oPm = await src.createPixelMap(oOpts);
          const p3 = image.createImagePacker();
          const name = DIR_NAME + '/' + Date.now().toString() + '_'
            + util.generateRandomUUID(true).substring(0, 8) + '.jpg';
          const file = fs.openSync(TransImageStore.absPath(ctx, name),
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            await p3.packToFile(oPm, file.fd, { format: 'image/jpeg', quality: 80 });
          } finally {
            fs.closeSync(file);
            p3.release();
          }
          oPm.release();
          imgPath = name;
        } catch (e) {
          // 副本失败不阻断
        }
      }
      src.release();
      const meta: HistoryImageMeta = { thumb: thumb, imgPath: imgPath };
      return JSON.stringify(meta);
    } catch (e) {
      return '';
    }
  }

  /** 从 meta JSON 提取 imgPath（异常/旧数据返回空串） */
  static imgPathFromMeta(meta: string): string {
    if (meta.length === 0) {
      return '';
    }
    try {
      const parsed = JSON.parse(meta) as HistoryImageMeta;
      return parsed.imgPath ?? '';
    } catch (e) {
      return '';
    }
  }

  /** 加载沙箱原图（不存在/损坏返回 null，调用方退回缩略图兜底） */
  static async loadPixelMap(ctx: common.Context, rel: string): Promise<image.PixelMap | null> {
    try {
      if (rel.length === 0 || !TransImageStore.fileExists(ctx, rel)) {
        return null;
      }
      const src = image.createImageSource(TransImageStore.absPath(ctx, rel));
      const pm = await src.createPixelMap();
      src.release();
      return pm;
    } catch (e) {
      return null;
    }
  }

  /** 删除单个图片文件（静默） */
  static delete(ctx: common.Context, rel: string): void {
    if (rel.length === 0) {
      return;
    }
    try {
      fs.unlinkSync(TransImageStore.absPath(ctx, rel));
    } catch (e) {
      // 已不存在
    }
  }

  /** 清空图片目录（覆盖恢复前调用） */
  static clearAll(ctx: common.Context): void {
    try {
      const dir = TransImageStore.dir(ctx);
      const names = fs.listFileSync(dir);
      for (const n of names) {
        try {
          fs.unlinkSync(dir + '/' + n);
        } catch (e) {
          // 忽略
        }
      }
    } catch (e) {
      // 目录不存在
    }
  }

  /** 清理孤儿文件：删除没有任何历史记录（含回收站）引用的图片 */
  static async cleanOrphans(ctx: common.Context): Promise<void> {
    try {
      const dir = TransImageStore.dir(ctx);
      const names = fs.listFileSync(dir);
      const wanted = new Set<string>();
      const all = await historyStore.getAll();
      for (const it of all) {
        const p = TransImageStore.imgPathFromMeta(it.meta);
        if (p.length > 0) {
          wanted.add(p);
        }
      }
      for (const n of names) {
        const rel = DIR_NAME + '/' + n;
        if (!wanted.has(rel)) {
          try {
            fs.unlinkSync(dir + '/' + n);
          } catch (e) {
            // 忽略
          }
        }
      }
    } catch (e) {
      // 目录不存在
    }
  }
}
