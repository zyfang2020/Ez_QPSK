# Tool

用于存放仿真后处理和算法验证脚本（Matlab/Python 等）。

建议约定：
- `Tool/matlab`：Matlab/Octave 脚本
- `Tool/python`：Python 脚本
- `Tool/data`：离线测试数据（可选）

当前已提供：
- `Tool/matlab/qpsk_single_dac_demod_demo.m`
- `Tool/matlab/qpsk_uart_capture_demod.m`
- `Tool/python/uart_capture_qpsk.py`
- `Tool/python/decode_rx_demod_ila.py`

## ILA external RX debug 解码

external RX bitstream 的 BD ILA `probe2` 连接 `rx_demod_dbg_bus[95:0]`。在 Vivado Hardware Manager 中抓取并导出 ILA CSV 后，可运行：

```powershell
python Tool/python/decode_rx_demod_ila.py path\to\ila_export.csv --decoded-csv Tool\data\rx_demod_ila_decoded.csv --summary-json Tool\data\rx_demod_ila_summary.json
```

该工具会解出 `nco_freq_corr`、I/Q、lock score、timing phase、phase bin、lock/valid/symbol 和 ADC 采样字段，并打印 lock 比例、最长连续 lock、频偏校正范围和符号统计。

默认按当前工程的 `100 MHz` 采样/NCO 时钟和 `24-bit` 相位累加器，把 `nco_freq_corr` 换算为 Hz，同时输出 ADC 动态范围和简单诊断提示。若后续时钟或 NCO 位宽变化，可加：

```powershell
python Tool/python/decode_rx_demod_ila.py path\to\ila_export.csv --sample-rate-hz 100000000 --phase-width 24
```

外部输入第一轮验收可加 `--check-external-rx`，默认检查 `lock_ratio >= 0.50`、`valid_ratio >= 0.005`、`adc_raw_span >= 16`，失败时返回非零，便于把 ILA 抓取结果接入批处理脚本。

如果外部源发的是本项目固定 Gray 循环 `00 -> 01 -> 11 -> 10`，可追加：

```powershell
python Tool/python/decode_rx_demod_ila.py path\to\ila_export.csv --check-external-rx --check-gray-cycle
```

该检查允许循环起点和方向不确定，默认要求有效符号的 Gray-cycle match ratio 不低于 `0.85`。
