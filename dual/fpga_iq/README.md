# C5VRX ×2（IQ）→ Tang Primer 25K → HDMI 720p（IQ 版・白黒）

XIAO ESP32-C5 2台から **生の IQ（4bit I/Q、40MS/s）** を受け、FPGA で FM 復調して 720p で出す版。v1（`../fpga/`、C5 が作った CVBS を受ける版）はそのまま残してある。
方式の説明は [`../design/iq_link.md`](../design/iq_link.md)。XIAO 側は [`../firmware/`](../firmware/README.md) の改造版ファームが必要。

表示は v1 と同じで、S1 でダイバーシティ（960×720）と2画面（640×480 ×2）を切り替える。

## 状態

| 項目 | 状態 |
|---|---|
| シミュレーション（Verilator） | 合格。FM 変調した 4bit IQ を2台分入力（B はキャリア +0.7MHz、偏移 1.3 倍）。NTSC / PAL、雑音を入れたときのダイバーシティ切替、S1 で2画面、TMDS 検算、SDRAM タイミング検査（違反 0）、受信状態 UART の受信 |
| IQ 受信の単体試験（Icarus） | ±100ppm、ピン間スキュー 5ns まで 16 万語でエラー 0 |
| レベル自動調整 | B（偏移 1.3 倍、+0.7MHz）で倍率 306（理論値 308）、オフセット −64（理論値 −61）に収束 |
| 回路規模（Yosys 見積もり） | LUT 約 7,000＋ALU 約 2,700、FF 約 2,500、BSRAM 12、DSP 8 前後 |
| Gowin IDE での合成 | **未実施** |
| 実機 | 未確認 |

`sim_results/`: `ntsc_diversity_A.png`（雑音の少ない A を表示）、`ntsc_diversity_B.png`（A に雑音を足した後、B に切替）、`ntsc_dual.png`（2画面）、`pal_dual.png`（B が PAL）。

## v1 から変わったファイル

| ファイル | 内容 |
|---|---|
| `src/c5vrx_tang_iq_top.v` | トップ。入力が `xa_iq[7:0]`、`xb_iq[7:0]`、`xa_link`、`xb_link` に変わった |
| `src/c5vrx_core_iq.v` | 本体の接続 |
| `src/iq_os_rx.v` | IQ バスの非同期受信（150MHz で取り込み） |
| `src/iq_phase_lut.v` | IQ → 位相の表（`tools/gen_iq_lut.py` で生成） |
| `src/fm_demod.v` | FM 復調、低域通過、20MS/s へ間引き、75MHz 側への受け渡し |
| `src/cvbs_decode_fm.v` | 周波数入力の CVBS デコーダ（レベル自動調整つき） |
| `src/link_rx.v` | XIAO の受信状態パケット（UART 2Mbaud）の受信 |
| `src/c5vrx_tang_iq.cst` / `.sdc` | ピン配置（IQ 8本×2、USB-A の D+/D−）とクロック制約 |
| `c5vrx_tang_iq.gprj` | Gowin プロジェクト |
| `sim/` | `tb_iq.v`（全体）、`iq_src.v`（FM IQ の模擬信号源）、`tb_iq_rx.v`（IQ 受信の単体試験） |

`chan_buf.v`、`sdram_fb.v`、`display.v`、`tmds_enc.v`、`button.v`、`gowin_pll.v` は v1 と同じもの。

## ビルド

v1 と同じ手順。

1. Gowin IDE で `c5vrx_tang_iq.gprj` を開く。
2. Project → Configuration → Place & Route → Dual-Purpose Pin で SSPI / MSPI / I2C / CPU の4つを「regular IO」にする（`impl/project_process_config.json` にも入れてある）。
3. Run All。`impl/pnr/c5vrx_tang_iq.fs` ができる。
4. Timing の 150MHz（clk_os）と 75MHz（clk_sys）に違反が無いことを確認する。

## シミュレーション

```
BUILD=/tmp/build ./sim/run_sim.sh        # NTSC 2台
BUILD=/tmp/build ./sim/run_sim.sh pal    # B が PAL
iverilog -g2012 -o rxt sim/tb_iq_rx.v src/iq_os_rx.v && vvp rxt
```

## 実機での確認の順番

1. XIAO を挿さずに書き込み、紺色の画面と左上の赤い四角が出ることを確かめる（v1 と同じ）。
2. 改造版ファームを書いた XIAO を1台つなぐ。`iq_lock` と `link_ok` を GAO で見るか、映像が出るかで確かめる。
3. 2台にしてダイバーシティと2画面を試す。
