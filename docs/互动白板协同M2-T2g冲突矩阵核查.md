# 互动白板协同 M2 T2g 冲突矩阵落地核查记录 —— 决策 D2-H

- 关联计划：《互动白板实时协同开发计划》M2 任务 T2.7（本任务编号 T2g）
- 关联设计：《互动白板实时协同设计文档》§5.6（软锁 + 锁粒度）/ §5.7（删除与橡皮擦 exists 规则）/ §5.8（各元素类型并发冲突矩阵，"铁律：key 的粒度 = 冲突合并的粒度"）
- 决策口径：D2-H —— 字段级 op 全量拆分（`el:{id}:{field}` 改造）本轮不做；本轮核查收口
- 核查执行：wb-core-domain-agent（代码实读，桌面端 + 核心 + 服务端）
- 核查日期：2026-10-01
- **口径声明：以 M2 交付时点代码现状为准；本任务不改代码，偏差仅记录不修复（供门 G2 引用与后续任务裁定）。**

> 证据口径：全部结论以 2026-10-01 工作区代码实读为依据；引用格式 `文件 L行号`，行号为当次快照。结论分类：**一致 / 偏差 / 未落地留 M3+**。

---

## 1. 核查汇总表（结论先行）

| # | 核查项 | 结论 | 一句话依据 |
|---|---|---|---|
| ① | 文字整体提交 | ✅ **一致** | 落定为全量 `el:{id}:data` 整元素覆盖（无字符级 op）；begin/endTextEditing 与软锁 acquire/release 接线完整 |
| ② | 表格结构锁（整表） | ✅ **一致（结构锁 = 整表）**；单元格级粒度**未落地留 M3+** | 打开表格编辑器即整表软锁；退出整 payload 单条 op；无单元格 id / 单元格锁（§5.6 明文"MVP 可直接整表锁"口径内） |
| ③ | 2D/3D 预览流 | ⚠️ **偏差 2 处**（3D 旋转拖动、3D 滚轮缩放无预览帧）；其余一致 | move/scale 走 D2-F 载荷预览流；尺寸对话框期间软锁（D2-C）；预览不落模型、终态 op 到达即清除 |
| ④ | 橡皮擦-锁并发 | ⚠️ **偏差 2 处**（"降级并提示"未落地；exists 跨 key 联合判定未落地）；其余一致 | 擦除跳过他人锁定元素（D2-G）；100ms 逐批 + 抬笔 flush；不产生"编辑幽灵元素" |

偏差明细与后续建议见 §3；矩阵外补充观察见 §4。

---

## 2. 逐项核查明细

### 2.1 ① 文字整体提交

**设计口径（§5.8 表格「文字」行）**：文本内容 key 粒度 = `el:{id}:text` **整体**；"后提交整体覆盖（**不做字符级**）"；抑制手段 = 编辑期元素软锁（"XX 编辑中"）。M1 既有语义：画布出口统一 `el:{id}:data`（整元素契约 JSON）。

**实现现状**：
- **入口闸门与锁接线完整**：`beginTextEditing` 先查本地远端锁快照，命中他人锁 → `onLockedElementTap` 提示并拒绝进入；通过后请求锁 `onEditLockRequest(id)`（canvas_controller.dart L2373-2387）。触发点：双击文本元素（L1390-1396）、文本创建完成后（L2118-2123）。
- **宿主接线**：`onEditLockRequest = _collab.acquireLock`、`onEditLockRelease = _collab.releaseLock`（board_edit_page.dart L170-172）；锁被拒回执兜底 `_onLockDenied`（L405-408，退编辑 + 提示）。
- **编辑期无 op**：`updateEditingText` 每键仅写本地模型 + 失效文本缓存（L2390-2402），不产生网络出口。
- **落定全量覆盖**：`endTextEditing` 释放锁（L2419）后走 `_commitEdit` → `_emitLocalCommit`（L3539-3587）→ `handleCanvasCommit` → 每条 upsert 发 `el:{id}:data`（`WbBoardFileCodec.encodeElement` 整元素 JSON；sync_service.dart L724-750）。语义 = 整体覆盖、不做字符级；空文本清理走 removedIds → `el:{id}:exists=false`。
- **用例证据**：collab_lock_test.dart L111-143（远端锁拒绝 / 退出释放）；sync_service_test.dart L302-317（upsert → `el:{id}:data`）。
- **说明**：字面 key `el:{id}:text` 未使用——与 M1 `el:{id}:data` 全元素契约合并实现；`el:{id}:{field}` 字段级拆分按 D2-H 本轮不做（接收端对未知字段显式忽略，前向兼容：sync_service.dart L819-835、L1057-1079）。

**结论：✅ 一致**。全量 `el:{id}:data` 整体提交、无字符级 op、锁 acquire/release 接线完整。key 名从设计表 `el:{id}:text` 到实现 `el:{id}:data` 的差异属 D2-H 既定口径（整元素粒度 ≥ 文本整体粒度），非偏差。

### 2.2 ② 表格结构锁（整表）

**设计口径**：
- §5.6 锁粒度表：「表格内容｜单元格级（**MVP 可整表**）；**行列结构操作整表锁**」。
- §5.8 矩阵两行：「单元格内容｜**单元格级（以单元格 id）**｜编辑不同格 = 完美合并｜单元格软锁」；「增删行列（结构）｜整表操作｜索引漂移问题｜**结构操作整表软锁**（低频重操作）；**MVP 可直接整表锁**」。
- §5.8 务实解法段：结构操作走整表软锁 + 整体 op，内容编辑走单元格级；稳定 UUID + 序列 CRDT 属 M10.5 后，**第一期不做**。

**实现现状**：
- **打开即整表锁**：表格编辑入口 = 双击 → 全窗独立编辑器（`_onElementActivate`，board_edit_page.dart L809-845）：本地锁快照闸门（`lockHolderOf` 命中他人 → 提示并拒绝）→ `acquireLock` → 打开编辑页（整表模型）→ 返回后 `_canvas.updateElement` 整 payload 回写 → `finally releaseLock`。内容与结构操作共享同一会话、同一整表锁。
- **提交粒度为整表 payload**：`updateElement` 走 `_commitEdit` → 单条 `el:{id}:data`（canvas_controller.dart L2758-2776；sync_service.dart L733-743）。无单元格拆分。
- **单元格级能力现状**：无单元格 id 语义、无 `el:{id}:cell:{cid}` key、无单元格锁；op 键解析仅认 `data` / `exists`，其余字段忽略（sync_service.dart L1057-1079）。
- **用例证据**：collab_lock_test.dart L145-188（远端锁命中过滤 / 锁定元素双击提示）。

**对应关系与差异说明**：
- 「增删行列 → 整表锁 + 整体 op」：实现与此行**一致**（甚至更粗——内容编辑也共享整表会话）。
- 「单元格内容 → 单元格级（以单元格 id）」：**未落地**——实现在设计双处明文允许的「MVP 可直接整表锁」口径内，但未获得该行描述的「编辑不同格 = 完美合并」并行度；异格/同格编辑在 MVP 下均为整表 LWW。
- 由于 M2 表格编辑器是全窗单会话（进入锁、退出提交），两行操作实际合并为「整表锁 + 整表提交」；并行度差异随字段级/单元格级拆分（D2-H 范围外）一并留 M3+。

**结论：✅ 一致（结构锁 = 整表）；单元格级粒度未落地留 M3+**（属 MVP 允许口径，非偏差）。

### 2.3 ③ 2D/3D 预览流

**设计口径**：
- §5.6：「2D/3D 变换｜**拖动走预览流（不锁）**；**尺寸调整对话框期间元素锁**」。
- §5.8：「2D/3D 变换（位置/尺寸/**旋转**）｜字段级；与笔迹同模式（**预览流 + 落定一条 op**）｜尺寸调整对话框期间软锁」。
- D2-F 载荷：`{kind:'transform', elementId, pageId, x, y, w, h}`；D2-C：尺寸对话框期间软锁、锁被拒单播回执 + 本端提示。

**实现现状**：
- **move / scale 拖动 = 预览流（一致）**：`_applyMove` / `_applyScale` 跳过 `isLockedByOther` 元素，并按 33ms 节流调度 `_emitTransformPreviews`（canvas_controller.dart L1780-1814 / L1816-1886）；预览载荷逐元素 `{kind:'transform', elementId, pageId, x, y, w, h}`（L1888-1915），与 D2-F 精确一致；同帧条数上限 `maxTransformPreviews`。拖动过程不获取软锁（符合"不锁"）。
- **落定一条 op**：抬笔 `_commitEdit()`（L1280-1285）→ `el:{id}:data` 整元素（非 `transform-{field}` 拆分——D2-H 范围）。
- **尺寸对话框软锁（D2-C，一致）**：`_onSizeBadgeTap` 闸门 + `acquireLock` → 对话框 → `resizeElementById`（中心不变、入撤销栈）→ `finally releaseLock`（board_edit_page.dart L853-873）；尺寸角标仅单选 2D/3D 且非编辑态可点（canvas_controller.dart L727-739）。
- **预览不落模型 / 终态清除（一致）**：远端 `_applyRemoteTransformFrame` 仅更新鬼影目标几何 + touch，不写 `document`（L3294-3329）；painter 绘制时以 overlay 临时变换（canvas_painter.dart L125-147）；终态 op 到达 → `applyRemoteElement` 清鬼影 + finalized 记忆丢弃迟到帧（L3486-3489），删除 → `applyRemoteRemove` 同（L3508-3512）+ 150ms 淡出。本端正在同元素手势时本地优先、不被远端帧覆盖（L3304-3309）。
- **偏差 1（3D 旋转拖动无预览帧）**：`_applyRotate3d` 拖动中仅写本地模型 + notify（L1635-1662），**无预览帧调度**；抬笔才 `_commitEdit` 发终态。§5.8 变换字段清单含「旋转」、§5.6「拖动走预览流」应覆盖旋转拖动，但 D2-F 载荷无旋转字段 → 远端在抬笔前无实时反馈。
- **偏差 2（3D 滚轮缩放无预览帧）**：`_zoomRender3dSize`（L1586-1607）同样无预览帧（会话式本地变更 + 空闲自动提交 `_flushRender3dSizeSession` L1610-1633）；"拖动走预览流"字面未覆盖滚轮，但同属「尺寸」变更，仅终态可见。
- **用例证据**：canvas_m2_preview_test.dart L236-284（move 预览 + 落定终态）、L286-327（scale）、L327-356（帧上限）、L618-684（transform 帧不落模型 / 终态丢弃）；canvas_m2_render_test.dart L161-192（锁角标像素）。

**结论：⚠️ 部分偏差**。move/scale 预览流（D2-F 载荷）、尺寸对话框软锁（D2-C）、预览不落模型 + 终态清除 = 一致；**3D 旋转拖动与 3D 滚轮缩放无预览帧**（远端延迟到抬笔/空闲提交才见结果）= 偏差（见 §3 D1/D2）。

### 2.4 ④ 橡皮擦-锁并发

**设计口径**：
- §5.6：「橡皮擦划过'被他人锁定/编辑中'的元素时**跳过**（本地基于 `lock:changed` 状态判断），不产生删除 op」。
- §5.7 首段：每划过一批元素立即攒批（**100ms**）发删除 op（**不等抬笔**）。
- §5.7 表：「A 擦 X vs B 正在编辑 X｜橡皮擦跳过锁定元素；极端并发下 B 提交时元素已不存在 → **提交降级 no-op 并提示**｜不产生'编辑幽灵元素'」。
- exists 规则：元素存在性用独立 key `el:{id}:exists`；「A 擦 X vs B 拖 X｜B 的 transform op 照常记录，**渲染以 `exists=false` 为准**」。

**实现现状**：
- **跳过锁定（D2-G，一致）**：`_eraseAt` 经 `hitTestElement`（默认过滤 `isLockedByOther`）命中——锁定元素不参与擦除、不产生删除 op（canvas_controller.dart L1932-1949 / L808-826）；锁快照由 `lock:changed` 驱动经 `refreshRemoteLocks` 刷新（L3170-3193；board_edit_page.dart L397-399）。
- **100ms 逐批 + 抬笔 flush（一致）**：擦除手势中 100ms 节流发中间批次（首沿立即），抬笔 `_emitEraseBatch` + `_commitEdit(emitLocal: false)` 终态 flush 防重复（L1286-1293 / L1955-1967）；中间批次不入撤销栈、整段一个撤销单元。删除 op = `el:{id}:exists=false`（sync_service.dart L744-748）。
- **极端并发（A 擦 X vs B 正在编辑 X，锁失效窗口）**：B 收到 exists=false → `applyRemoteRemove` 移除元素（L3504-3531）；B 后续每键编辑因元素不存在静默丢弃、提交时以 removedIds 重发幂等 `exists=false`——**不产生编辑幽灵元素**（一致）；但 **"并提示"未落地**（无 toast/snack，编辑框静默消失，见 §3 D3）。附带：`_editingElementId` 未随远端删除清理（applyRemoteRemove 无编辑态处理），编辑框渲染为空态（canvas_text_editor.dart L38-45），软锁续约延续至下一次文本编辑动作——卫生问题、无实际冲突危害。
- **偏差（exists 跨 key 联合判定未落地）**：`data` 与 `exists` 为独立 LWW register（core/src/crdt/crdt.cpp L78-99 按 key 独立比较）；桌面逐 op 顺序应用（sync_service.dart L811-835）、`applyRemoteElement` 直接 upsert、不检查该 id 是否已收过删除（canvas_controller.dart L3482-3499）——无「exists=false 优先渲染」合并层。"A 擦 X vs B 拖 X" 场景下，若 exists=false 先于 B 迟到的 data op 到达接收端，则 X 复活，与 §5.7「渲染以 exists=false 为准」不符（见 §3 D4）。
- **用例证据**：canvas_m2_preview_test.dart L770-822（100ms 逐批 + 抬笔 flush + 整段撤销）、L824-860（跳过锁定元素）。

**结论：⚠️ 部分偏差**。跳过锁定元素（D2-G）、100ms 逐批 + 抬笔 flush、降级不产生幽灵元素 = 一致；"并提示"未落地（轻）；**exists 跨 key 联合判定未落地 → "渲染以 exists=false 为准"在 op 乱序时存在复活窗口**（如实记录，见 §3 D3/D4）。

---

## 3. 偏差项与后续建议（供门 G2 引用）

| 编号 | 所属 | 偏差（如实标注） | 影响 | 建议（供后续任务裁定） |
|---|---|---|---|---|
| D1 | ③ | 3D 旋转拖动（`_applyRotate3d`）无预览帧，远端抬笔前无反馈 | 轻：单人写、反馈延迟；无一致性风险（终态仍走 op） | M3 统一「2D/3D 变换走预览流」时扩展载荷旋转字段（D2-F+），或明确旋转不纳入预览流口径 |
| D2 | ③ | 3D 滚轮缩放（`_zoomRender3dSize`）无预览帧，尺寸变更仅终态可见 | 轻：同上 | 同 D1；或补口径说明「滚轮缩放非拖动交互、不承诺预览」 |
| D3 | ④ | 「极端并发下提交降级 no-op **并提示**」的提示未落地（编辑框静默消失）；编辑态 `_editingElementId` 残留至下次交互 | 轻（UX）：用户不知情；无数据损坏 | M3 在 `applyRemoteRemove` 命中编辑中/选中元素时补提示与编辑态清理（endTextEditing 等价路径） |
| D4 | ④ | exists 跨 key 联合判定未落地：data/exists 独立 LWW、接收端逐 op 应用，op 乱序时已删元素可被迟到 data op 复活（与「渲染以 exists=false 为准」不符） | 中：低概率状态复活（需软锁失效 + op 乱序叠加）；可再收敛、不数据损坏（LWW 兜底语义） | M3 评估接收端「墓碑优先」合并层（维护已删 id 集合、抑制迟到 data 渲染），或随字段级拆分范围一并处理 |
| S1 | 矩阵外 | `undo()/redo()` 仅本地 `document.replace`、**不发反向 op**（canvas_controller.dart L3029-3058），与 §5.8「undo 与协同」段不符 | 协同会话中本地撤销不回传，远端不感知，状态发散至下一次提交覆盖 | 留 M3+ 裁定（协同 undo 语义）；本轮仅记录 |
| S2 | 矩阵外 | `_onLockDenied` 兜底仅 `endTextEditing` + 提示（board_edit_page.dart L405-408）；专业编辑页 / 尺寸对话框路径被拒后仅提示、不关闭会话 | 轻：竞态窄窗口；提交仍走 LWW 兜底 | 可并入 D3 的 M3 清理项一并处理 |

> 备注：D1/D2 为"预览覆盖不全"类（体验层），D3/S2 为"提示/清理"类，D4 为唯一影响一致性表现（渲染层）的偏差；S1 为 §5.8 明确功能未落地。均不涉及数据损坏路径（三层防线中软锁与 LWW 兜底工作正常）。

---

## 4. 补充观察（矩阵外，供 G2 裁定）

1. **锁快照刷新链路**：`lock:changed` → 协同服务 `remoteLocks`（排除本端，sync_service.dart L381-398）→ `_onCollabChanged` → `refreshRemoteLocks`（同值去抖）→ 命中过滤 / 角标渲染（painter L795-849）/ 交互禁用，链路完整（collab_lock_test.dart L82-188 覆盖）。
2. **软锁生命周期（服务端旁证）**：TTL 30s / 续约 10s / 断连释放（services/realtime/src/rooms.ts；sync_service.dart L231-232、L605-711）；锁为会话态、不进 CRDT（§5.6 末条一致）。
3. **防回发两层**：结构隔离（远端走 `applyRemoteElement/applyRemoteRemove`，绕过提交漏斗）+ `isRemoteApplying` 谓词（canvas_controller.dart L3479-3481 / L3565-3568；board_edit_page.dart L154-155），与 M1 设计一致。
4. **帧载荷防御**：非当前页 / 已终态 / 非法载荷的预览帧直接丢弃（canvas_controller.dart L3227-3253）；坏载荷安全空转用例见 canvas_m2_preview_test.dart L585-616。

---

## 5. 证据文件清单

| 文件 | 用途 |
|---|---|
| `docs/互动白板实时协同设计文档.md`（§5.6-5.8） | 设计口径来源 |
| `docs/互动白板实时协同开发计划.md` | 任务 T2.7 / D2-H 范围 |
| `apps/desktop/lib/widgets/canvas/canvas_controller.dart` | 锁闸门 / 预览流 / 擦除跳过 / 提交漏斗 / 远端应用（①-④） |
| `apps/desktop/lib/widgets/canvas/canvas_painter.dart` | 远端变换 overlay / 锁角标渲染（③④） |
| `apps/desktop/lib/widgets/canvas/canvas_text_editor.dart` | 文本编辑态渲染与提交触发（①④） |
| `apps/desktop/lib/pages/board_edit_page.dart` | 锁接线 / 专业编辑与尺寸对话框锁 / 拒绝兜底（①②③④） |
| `apps/desktop/lib/services/sync_service.dart` | `el:{id}:data` / `el:{id}:exists` op 生成、锁管理、远端应用（①-④） |
| `core/src/crdt/crdt.cpp` | 按 key LWW register map（exists 独立 key 事实，④） |
| `core/tools/schema/element.schema.json` | drawing 已入契约（M2 前置项旁证） |
| `services/realtime/src/rooms.ts` | 软锁表 TTL 30s 旁证 |
| `apps/desktop/test/collab_lock_test.dart` | 锁闸门 / 软锁生命周期用例（①②） |
| `apps/desktop/test/canvas_m2_preview_test.dart` | 预览流 / 擦除逐批 / 擦除跳过用例（③④） |
| `apps/desktop/test/canvas_m2_render_test.dart` | 锁角标像素断言（④） |
| `apps/desktop/test/sync_service_test.dart` | `el:{id}:data` 提交用例（①） |

---

*记录完（T2g / D2-H，2026-10-01）。本任务未修改任何产品代码与既有文档，仅新增本记录。*
