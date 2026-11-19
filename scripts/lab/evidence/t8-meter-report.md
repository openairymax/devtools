# T8/P2-6 计量三档基线实测报告（gate:lab）

- 基线 SSoT：docs-workload/140-application-development/28-inference-metering-baseline.md（§1 档位 / §3 判据 / §5 记录）
- 机器指纹：`089f7fe751a3e230`；后端 cpu；模型 `Qwen3-0.6B-Q8_0`
- 缓存口径：llm_d cache_prompt 为能力位、无法透传 false，以逐请求唯一前缀达成非缓存 prefill（R3 实证 prefix_ratio）

| 档位 | 负载 | 延迟 | 内存 | 结论 |
|---|---|---|---|---|
| A 单流 | 输入 200~202 tok；输出 64 tok；n=12 | prefill_ms 850.0~986.8；decode_tps 68.59~75.68（原始值） | 1936504 KB | R1 绿 / R2 绿 / R3 绿 |
| B 2 路 | 输入 200~202 tok；输出 64 tok；n=12 | prefill_ms 2148.0~2409.0；decode_tps 44.06~47.84（原始值） | 2249156 KB | R1 绿 / R2 绿 / R3 绿 |
| C 长 prompt | 输入 2427~2430 tok；输出 64 tok；n=12 | prefill_ms 15782.2~16465.5；decode_tps 28.03~34.11（原始值） | 5379420 KB | R1 绿 / R2 绿 / R3 绿 |

内存列 = llama-server 与 llm_d 常驻 RSS 合计（KB，档末采样）。

## R1~R4/R6 判定

| 判据 | 阈值 | 实测 | 判定 |
|---|---|---|---|
| R1 上报率 | >=0.95 | A=1.0 B=1.0 C=1.0 | 绿 |
| R2 口径自洽 | 偏差<=2% | 最大 0.00% | 绿 |
| R3 缓存可辨 | prefix_ratio<=0.05 | 最大 0.0471 | 绿 |
| R4 聚合一致 | meas_samples==n_B | 12 vs 12 | 绿 |
| R6 并发下限 | min(波次聚合 decode_tps) >= mean(a) | 85.3~93.68 vs 71.82 | 绿 |

R5 回归容差：本机无前次基线记录，判据不适用（SSoT §5 纪律 1）。

记录：`t8-meter-baseline.json`（airy.t8.meter/1）。
