import { relationalStore } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/**
 * 历史记录存储：RelationalStore（SQLite）。
 * 表结构：id 自增 / 原文 / 译文 / 引擎 / 源语言 / 目标语言 / 时间戳 / 收藏 / 记录类型 / 扩展信息 / 删除时间
 * 删除策略：软删除（deleted_at > 0 进回收站），列表查询自动排除；彻底删除/清空回收站为物理 DELETE；
 * 回收站记录保留 30 天，写入时自动清理超期项。
 */

/**
 * 单条历史记录（UI 可观察模型）。
 * 收藏状态 @Trace：V2 列表（Repeat 懒加载）里点星标后精准刷新对应卡片，
 * 无需整体重载数组；其余字段入库后不可变。
 */
@ObservedV2
export class HistoryItem {
  public id: number;
  @Trace public source: string;
  @Trace public result: string;
  public engineId: string;
  public fromLang: string;
  public toLang: string;
  public createdAt: number;
  @Trace public favorite: number;
  /** 记录类型：0=文本，1=图片翻译 */
  public recordType: number;
  /** 扩展信息 JSON（图片翻译：{"thumb":"base64,...","imgPath":"trans_images/x.jpg"}），空串=无 */
  public meta: string;
  /** 软删除时间戳（0=未删除；>0 表示在回收站） */
  public deletedAt: number;

  constructor(id: number, source: string, result: string, engineId: string,
    fromLang: string, toLang: string, createdAt: number, favorite: number,
    recordType: number = 0, meta: string = '', deletedAt: number = 0) {
    this.id = id;
    this.source = source;
    this.result = result;
    this.engineId = engineId;
    this.fromLang = fromLang;
    this.toLang = toLang;
    this.createdAt = createdAt;
    this.favorite = favorite;
    this.recordType = recordType;
    this.meta = meta;
    this.deletedAt = deletedAt;
  }
}

/** 新增记录（无 id，自增生成）。ArkTS 不保证支持 Omit 等工具类型，显式声明 */
export interface NewHistoryItem {
  source: string;
  result: string;
  engineId: string;
  fromLang: string;
  toLang: string;
  createdAt: number;
  favorite?: number;
  /** 记录类型：0=文本（默认），1=图片翻译 */
  recordType?: number;
  /** 扩展信息 JSON（图片翻译缩略图等），默认空 */
  meta?: string;
  /** 软删除时间戳（备份恢复时还原回收站状态），默认 0=未删除 */
  deletedAt?: number;
}

/**
 * 历史记录筛选条件：关键词（原文/译文模糊匹配）、仅收藏、语言对（方向无关）。
 * 空字符串表示不过滤该维度。
 */
export interface HistoryQuery {
  keyword: string;
  favOnly: boolean;
  fromLang: string;
  toLang: string;
}

/** WHERE 子句 + 绑定参数（ArkTS 对象字面量须对应显式接口） */
interface FilterSql {
  where: string;
  args: relationalStore.ValueType[];
}

const DB_NAME = 'transharmony.db';
const TABLE = 'history';
export const MAX_ROWS = 5000;
/** 历史数据版本号（AppStorage key）：任何写操作后 bump，Index 桥接给历史页实时刷新 */
export const HISTORY_VERSION_KEY = 'history_version';

export class HistoryStore {
  private store: relationalStore.RdbStore | null = null;

  /** 数据变更广播：三个主页签常驻挂载，历史页靠监听该版本号保持实时 */
  private bump(): void {
    AppStorage.setOrCreate(HISTORY_VERSION_KEY, Date.now());
  }

  async init(context: Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    this.store = await relationalStore.getRdbStore(context, config);
    await this.store.executeSql(
      'CREATE TABLE IF NOT EXISTS ' + TABLE + ' ('
      + 'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      + 'source TEXT NOT NULL, '
      + 'result TEXT NOT NULL, '
      + 'engine_id TEXT NOT NULL, '
      + 'from_lang TEXT NOT NULL, '
      + 'to_lang TEXT NOT NULL, '
      + 'favorite INTEGER NOT NULL DEFAULT 0, '
      + 'created_at INTEGER NOT NULL)'
    );
    await this.store.executeSql(
      'CREATE INDEX IF NOT EXISTS idx_history_created ON ' + TABLE + '(created_at DESC)'
    );
    // 老库升级：补 favorite 列（已存在则报错，忽略）
    try {
      await this.store.executeSql(
        'ALTER TABLE ' + TABLE + ' ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0');
    } catch (e) {
      // 列已存在
    }
    // 回收站功能已移除：老库升级时物理清掉历史版本软删除的记录（无该列则忽略）
    try {
      await this.store.executeSql('DELETE FROM ' + TABLE + ' WHERE deleted_at > 0');
    } catch (e) {
      // 列不存在
    }
    // v1.1：图片翻译记录 —— 记录类型（0 文本 / 1 图片）与扩展信息（缩略图等）
    try {
      await this.store.executeSql(
        'ALTER TABLE ' + TABLE + ' ADD COLUMN record_type INTEGER NOT NULL DEFAULT 0');
    } catch (e) {
      // 列已存在
    }
    try {
      await this.store.executeSql(
        "ALTER TABLE " + TABLE + " ADD COLUMN meta TEXT NOT NULL DEFAULT ''");
    } catch (e) {
      // 列已存在
    }
    // v1.1：回收站 —— 软删除时间戳（0=未删除）
    try {
      await this.store.executeSql(
        'ALTER TABLE ' + TABLE + ' ADD COLUMN deleted_at INTEGER NOT NULL DEFAULT 0');
    } catch (e) {
      // 列已存在
    }
  }

  async add(item: NewHistoryItem): Promise<void> {
    if (this.store === null) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'source': item.source,
      'result': item.result,
      'engine_id': item.engineId,
      'from_lang': item.fromLang,
      'to_lang': item.toLang,
      'favorite': item.favorite ?? 0,
      'created_at': item.createdAt,
      'record_type': item.recordType ?? 0,
      'meta': item.meta ?? '',
      'deleted_at': item.deletedAt ?? 0
    };
    await this.store.insert(TABLE, bucket);
    await this.maintain();
    this.bump();
  }

  /** 按 id 查单条（历史详情二级页） */
  async getById(id: number): Promise<HistoryItem | undefined> {
    if (this.store === null) {
      return undefined;
    }
    const items = await this.rowsFrom(
      'SELECT * FROM ' + TABLE + ' WHERE id = ?', [id]);
    return items.length > 0 ? items[0] : undefined;
  }

  /** 全量读取（含回收站记录，按时间正序；备份与孤儿图片清理用） */
  async getAll(): Promise<HistoryItem[]> {
    if (this.store === null) {
      return [];
    }
    return this.rowsFrom('SELECT * FROM ' + TABLE + ' ORDER BY created_at ASC', []);
  }

  /** 备份恢复：批量写入（不逐条 trim/bump，最后统一维护+广播）。replace=true 先清空 */
  async restoreAll(items: NewHistoryItem[], replace: boolean): Promise<void> {
    if (this.store === null) {
      return;
    }
    if (replace) {
      await this.clear();
    }
    for (const it of items) {
      const bucket: relationalStore.ValuesBucket = {
        'source': it.source,
        'result': it.result,
        'engine_id': it.engineId,
        'from_lang': it.fromLang,
        'to_lang': it.toLang,
        'favorite': it.favorite ?? 0,
        'created_at': it.createdAt,
        'record_type': it.recordType ?? 0,
        'meta': it.meta ?? '',
        'deleted_at': it.deletedAt ?? 0
      };
      await this.store.insert(TABLE, bucket);
    }
    await this.maintain();
    this.bump();
  }

  /** 组装筛选 WHERE 子句：active=未删除 / recycle=回收站；关键词 LIKE / 收藏 / 语言对，参数化防注入 */
  private filterSql(q: HistoryQuery, mode: string): FilterSql {
    const conds: string[] = [];
    const args: relationalStore.ValueType[] = [];
    conds.push(mode === 'recycle' ? 'deleted_at > 0' : 'deleted_at = 0');
    if (q.keyword.trim().length > 0) {
      // ESCAPE '\'：关键词中的 % _ \ 按字面匹配
      conds.push("(source LIKE ? ESCAPE '\\' OR result LIKE ? ESCAPE '\\')");
      const kw = '%' + q.keyword.trim()
        .replace(/\\/g, '\\\\').replace(/%/g, '\\%').replace(/_/g, '\\_') + '%';
      args.push(kw);
      args.push(kw);
    }
    if (q.favOnly) {
      conds.push('favorite = 1');
    }
    if (q.fromLang.length > 0 && q.toLang.length > 0) {
      conds.push(
        "((from_lang = ? AND to_lang = ?) OR (from_lang = ? AND to_lang = ?))");
      args.push(q.fromLang, q.toLang, q.toLang, q.fromLang);
    }
    if (conds.length === 1) {
      return { where: ' WHERE ' + conds[0], args: [] };
    }
    return { where: ' WHERE ' + conds.join(' AND '), args: args };
  }

  /** 分页查询（未删除记录）：筛选条件下推 SQLite，按创建时间倒序 */
  async queryPage(q: HistoryQuery, limit: number, offset: number): Promise<HistoryItem[]> {
    if (this.store === null) {
      return [];
    }
    const f = this.filterSql(q, 'active');
    const sql = 'SELECT * FROM ' + TABLE + f.where + ' ORDER BY created_at DESC LIMIT ? OFFSET ?';
    return this.rowsFrom(sql, f.args.concat([limit, offset]));
  }

  /** 符合筛选条件的未删除记录总数（分页加载的结束判据） */
  async countPage(q: HistoryQuery): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    const f = this.filterSql(q, 'active');
    const resultSet = await this.store.querySql('SELECT COUNT(*) AS c FROM ' + TABLE + f.where, f.args);
    let count = 0;
    try {
      if (resultSet.goToFirstRow()) {
        count = resultSet.getLong(resultSet.getColumnIndex('c'));
      }
    } finally {
      resultSet.close();
    }
    return count;
  }

  /** 分页查询回收站（已软删除记录），条件同 queryPage */
  async queryRecyclePage(q: HistoryQuery, limit: number, offset: number): Promise<HistoryItem[]> {
    if (this.store === null) {
      return [];
    }
    const f = this.filterSql(q, 'recycle');
    const sql = 'SELECT * FROM ' + TABLE + f.where + ' ORDER BY deleted_at DESC LIMIT ? OFFSET ?';
    return this.rowsFrom(sql, f.args.concat([limit, offset]));
  }

  /** 回收站记录总数 */
  async countRecyclePage(q: HistoryQuery): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    const f = this.filterSql(q, 'recycle');
    const resultSet = await this.store.querySql('SELECT COUNT(*) AS c FROM ' + TABLE + f.where, f.args);
    let count = 0;
    try {
      if (resultSet.goToFirstRow()) {
        count = resultSet.getLong(resultSet.getColumnIndex('c'));
      }
    } finally {
      resultSet.close();
    }
    return count;
  }

  /** 执行 SELECT 并逐行映射为 HistoryItem（@ObservedV2 类须显式构造） */
  private async rowsFrom(sql: string, args: relationalStore.ValueType[]): Promise<HistoryItem[]> {
    const resultSet = await this.store!.querySql(sql, args);
    const items: HistoryItem[] = [];
    try {
      while (resultSet.goToNextRow()) {
        items.push(new HistoryItem(
          resultSet.getLong(resultSet.getColumnIndex('id')),
          resultSet.getString(resultSet.getColumnIndex('source')),
          resultSet.getString(resultSet.getColumnIndex('result')),
          resultSet.getString(resultSet.getColumnIndex('engine_id')),
          resultSet.getString(resultSet.getColumnIndex('from_lang')),
          resultSet.getString(resultSet.getColumnIndex('to_lang')),
          resultSet.getLong(resultSet.getColumnIndex('created_at')),
          resultSet.getLong(resultSet.getColumnIndex('favorite')),
          resultSet.getLong(resultSet.getColumnIndex('record_type')),
          resultSet.getString(resultSet.getColumnIndex('meta')),
          resultSet.getLong(resultSet.getColumnIndex('deleted_at'))
        ));
      }
    } finally {
      resultSet.close();
    }
    return items;
  }

  /** 查询记录，按创建时间倒序（保留兼容入口） */
  async query(limit: number, offset: number): Promise<HistoryItem[]> {
    const empty: HistoryQuery = { keyword: '', favOnly: false, fromLang: '', toLang: '' };
    return this.queryPage(empty, limit, offset);
  }

  /** 软删除单条（进回收站，30 天后自动清理） */
  async remove(id: number): Promise<void> {
    if (this.store === null) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE).equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'deleted_at': Date.now() };
    await this.store.update(bucket, predicates);
    this.bump();
  }

  /** 软删除批量 */
  async removeMany(ids: number[]): Promise<void> {
    // slice 副本剥离 V2 状态代理数组：@Local 数组直接传入 native RDB 的 in() 会抛异常
    // （左滑 remove 传单个 number 正常，批量传代理数组失败，即此原因）
    const plain = ids.slice();
    if (this.store === null || plain.length === 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE).in('id', plain);
    const bucket: relationalStore.ValuesBucket = { 'deleted_at': Date.now() };
    await this.store.update(bucket, predicates);
    this.bump();
  }

  /** 从回收站恢复单条/批量 */
  async restoreMany(ids: number[]): Promise<void> {
    const plain = ids.slice();
    if (this.store === null || plain.length === 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE).in('id', plain);
    const bucket: relationalStore.ValuesBucket = { 'deleted_at': 0 };
    await this.store.update(bucket, predicates);
    this.bump();
  }

  /** 彻底删除单条/批量（物理 DELETE；关联图片文件由调用方清理） */
  async purgeMany(ids: number[]): Promise<void> {
    const plain = ids.slice();
    if (this.store === null || plain.length === 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE).in('id', plain);
    await this.store.delete(predicates);
    this.bump();
  }

  /** 一键清空回收站（物理 DELETE 全部已删记录；关联图片文件由调用方清理） */
  async purgeRecycleAll(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE).greaterThan('deleted_at', 0);
    await this.store.delete(predicates);
    this.bump();
  }

  /** 收藏 / 取消收藏 */
  async setFavorite(id: number, favorite: boolean): Promise<void> {
    if (this.store === null) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE).equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'favorite': favorite ? 1 : 0 };
    await this.store.update(bucket, predicates);
    this.bump();
  }

  /** 清空全部历史（物理删除） */
  async clear(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE);
    await this.store.delete(predicates);
    this.bump();
  }

  /** 超量维护：清理 30 天前的回收站记录 + 只保留最近 MAX_ROWS 条未删除记录 */
  private async maintain(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000;
    await this.store.executeSql(
      'DELETE FROM ' + TABLE + ' WHERE deleted_at > 0 AND deleted_at < ' + cutoff);
    await this.store.executeSql(
      'DELETE FROM ' + TABLE + ' WHERE deleted_at = 0 AND id NOT IN '
      + '(SELECT id FROM ' + TABLE + ' WHERE deleted_at = 0 ORDER BY created_at DESC LIMIT ' + MAX_ROWS + ')'
    );
  }
}

export const historyStore = new HistoryStore();
