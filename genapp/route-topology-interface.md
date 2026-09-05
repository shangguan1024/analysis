# 意图路由模块接口说明（routeTopology）

> 定位：创建入口的纯拓扑判定器。回答唯一必须在 DAG 加载前定死的问题——走哪张拓扑。
> 模板/DS 维度不在本模块职责内（垂类拓扑天然无对应节点；通用拓扑由节点内自决）。

## 1. 接口签名

```typescript
routeTopology(input: RouteTopologyInput): Promise<RouteTopologyResult>
```

## 2. 输入参数

```typescript
interface RouteTopologyInput {
  /** 输入① 用户原始 query（语义信号） */
  readonly query: string;

  /** 输入② 显式拓扑选择（Dashboard 表单 basic.projectType 值） */
  readonly explicitTopology: 'auto' | 'app' | 'game';

  /** 输入③ 拓扑清单（creator 拥有的 TOPOLOGY_CATALOG，外部注入） */
  readonly topologyCatalog: ReadonlyArray<TopologyEntry>;
}

interface TopologyEntry {
  readonly id: 'app' | 'game';   // 未来垂类在此扩展
  readonly description: string;  // 区分性语义描述（LLM 判定依据）
}
```

| 参数 | 类型 | 来源 | 作用 |
|------|------|------|------|
| `query` | `string` | 用户输入框原文 | LLM 判定的语义信号 |
| `explicitTopology` | `'auto' \| 'app' \| 'game'` | 表单字段 `basic.projectType` | 短路开关 + 显式优先保障 |
| `topologyCatalog` | `TopologyEntry[]` | creator（L8）的 `TOPOLOGY_CATALOG` | LLM 的选项空间 + 归一化校验值域 |

### explicitTopology 语义

| 值 | 含义 | 后续行为 |
|----|------|---------|
| `'auto'` | 未显式选择（表单默认值） | 进 LLM 判定 |
| `'app'` / `'game'` | 用户显式指定 | 短路返回，零 LLM 调用 |

> 注：`'auto'` 只是「未指定」信号，不是拓扑，不在 topologyCatalog 中。

## 3. 输出参数

```typescript
interface RouteTopologyResult {
  /** 选定的拓扑（恒非空，失败兜底 'app'）——唯一业务消费字段 */
  readonly topologyId: 'app' | 'game';

  /** 决策来源（可观测性） */
  readonly source: 'explicit' | 'llm' | 'fallback';

  /** LLM 原始输出（排障；非 LLM 来源为 null） */
  readonly raw: string | null;

  /** 失败标记 */
  readonly error: 'llm-error' | 'config-error' | null;
}
```

| 字段 | 语义 | 消费方 |
|------|------|--------|
| `topologyId` | 走哪张 DAG | server → `job.type` → 现有 JOB_RUNS 通道 |
| `source` | 拓扑怎么定的（显式/LLM/兜底） | 日志/可观测 |
| `raw` | 归一化前的 LLM 原文 | 排障 |
| `error` | 失败原因分类 | 排障 |

## 4. 输入输出映射

| query | explicitTopology | 输出 |
|-------|------------------|------|
| 任意 | `'app'` 或 `'game'` | `{topologyId: 显式值, source:'explicit', raw:null, error:null}`（零 LLM） |
| 「做跑酷游戏」 | `'auto'` | `{topologyId:'game', source:'llm', raw:'game', error:null}` |
| 「做旅游应用」 | `'auto'` | `{topologyId:'app', source:'llm', raw:'app', error:null}` |
| 任意 | `'auto'` + LLM 失败/输出非法 | `{topologyId:'app', source:'fallback', raw, error:'llm-error'\|'config-error'}` |

## 5. 内部数据流（5 步）

```
输入 {query, explicitTopology, topologyCatalog}
  ▼
① 显式短路: explicitTopology !== 'auto' → 直接返回 explicit（零 LLM）
  ▼
② prompt 组装: topologyCatalog ──渲染──► system（候选清单+边界规则）
               query ─────────────────► user
  ▼
③ LLM 调用: pi-ai complete · loadLlmConfig('topology-router')
            maxTokens=50 · 60s 超时 · 产出 {text, stopReason}
  ▼
④ 归一化: text → trim → 小写 → 去引号 → ∈ catalog id 集合？
          合法 → {topologyId, source:'llm'}
          非法/空 → {topologyId:'app', source:'fallback', error:'llm-error'}
  ▼
⑤ 异常捕获（包住②③④，永不 throw）:
  stopReason error/aborted → fallback + 'llm-error'
  Agent/apiKey/config 异常 → fallback + 'config-error'
  ▼
输出 RouteTopologyResult
```

## 6. 调用链与分层

```
server (L9)   收集 query + explicitTopology → 调 creator 入口     L9→L8 ✅
creator (L8)  持有 TOPOLOGY_CATALOG → 调路由服务传齐 3 参数       L8→L7 ✅
路由服务 (L7) 纯函数，三步执行（短路→LLM→归一化），永不 throw
```

- `TOPOLOGY_CATALOG` 位置：`creator/src/workflow/topologies.ts`（与 JOB_RUNS 同包）
  —— 加拓扑 = 加 YAML + JOB_RUNS 一行 + CATALOG 一条，全部在 creator 内完成，单一真相源
- 路由服务对「有哪些拓扑」零内置知识——归一化校验值域从 `topologyCatalog` 入参现场提取

## 7. 设计纪律

1. **永不 throw**——所有失败收敛为 `source:'fallback'` + `error` 标记，创建不阻断（宁可漏召不可误召）
2. **显式不可被 LLM 覆盖**——`explicitTopology !== 'auto'` 时 LLM 根本不参与
3. **输出值域受控**——`topologyId` 只能是 catalog id 或兜底 'app'，LLM 幻觉 id 被归一化拒绝
4. **零新落盘契约**——`topologyId` 走现有 `job.type` 通道，无新文件、无 DAG/注册表/节点改动
5. **兜底偏置方向安全**——漏判 game = 产物形态普通化（可迭代纠正）；误判 game = 走错管线（不可逆）
