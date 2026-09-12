/**
 * 图片获取工具：拍照（系统相机选择器，免权限）与相册选图（PhotoViewPicker，免权限）。
 * 两个入口统一返回 PixelMap；用户取消返回 null，真实异常向上抛由调用方提示。
 * 拍照照片落应用沙箱临时文件（不进相册），读取 PixelMap 后临时文件即删。
 */

import { camera, cameraPicker } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/** 拍照取图：系统相机选择器；取消/未出片返回 null */
export async function captureFromCamera(ctx: common.UIAbilityContext): Promise<image.PixelMap | null> {
  let tmpPath = '';
  try {
    // saveUri 指向应用沙箱临时文件（官方要求：文件须已存在且可写）：
    // 相机直接写这里，不经过相册；不传 saveUri 时系统默认落库到相册
    tmpPath = ctx.cacheDir + '/ocr_' + Date.now().toString() + '.jpg';
    const tmpFile = fs.openSync(tmpPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fs.closeSync(tmpFile);
    const saveUri = fileUri.getUriFromPath(tmpPath);
    const result = await cameraPicker.pick(ctx,
      [cameraPicker.PickerMediaType.PHOTO],
      { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK, saveUri: saveUri });
    if (result.resultCode !== 0 || result.resultUri.length === 0) {
      return null; // 用户取消或未取到照片，静默返回
    }
    return await readPixelMap(result.resultUri, tmpPath);
  } finally {
    // 沙箱临时照片即用即删，不留痕迹
    if (tmpPath.length > 0) {
      try {
        fs.unlinkSync(tmpPath);
      } catch (e) {
        // 文件可能已被系统清理
      }
    }
  }
}

/** 相册选图：PhotoViewPicker 选择（免权限，返回只读 uri）；取消返回 null */
export async function pickFromGallery(ctx: common.UIAbilityContext): Promise<image.PixelMap | null> {
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = 1;
  const picker = new photoAccessHelper.PhotoViewPicker();
  const result = await picker.select(options);
  if (result.photoUris.length === 0) {
    return null; // 用户取消选择
  }
  return await readPixelMap(result.photoUris[0], '');
}

/** uri 转 PixelMap：uri 直读优先；失败后拍照走沙箱路径、相册走 fd（官方示例路径） */
async function readPixelMap(uri: string, sandboxPath: string): Promise<image.PixelMap> {
  try {
    const source = image.createImageSource(uri);
    if (source !== undefined) {
      const pm = await source.createPixelMap();
      await source.release();
      return pm;
    }
  } catch (e) {
    // uri 直读失败，走下方兜底
  }
  if (sandboxPath.length > 0) {
    // saveUri 流程：临时文件是我们自己建的，真实沙箱路径最可靠
    // （fileUri 形如 file://<包名>/data/...，直接剥 file:// 会带上包名导致 13900002）
    let path = sandboxPath;
    if (!path.startsWith('/')) {
      const i = path.indexOf('/data/');
      if (i >= 0) {
        path = path.substring(i);
      }
    }
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const source = image.createImageSource(file.fd);
      const pm = await source.createPixelMap();
      await source.release();
      return pm;
    } finally {
      fs.closeSync(file);
    }
  }
  // 媒体库 uri（file://media/...）：按官方示例以只读 fd 打开
  const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  try {
    const source = image.createImageSource(file.fd);
    const pm = await source.createPixelMap();
    await source.release();
    return pm;
  } finally {
    fs.closeSync(file);
  }
}
