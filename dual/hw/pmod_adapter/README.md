# C5VRX Pmod アダプタ rev A（XIAO ESP32-C5 → Tang Primer 25K Dock Pmod）

XIAO ESP32-C5（C5VRX ファーム）1台を Dock の Pmod 1口につなぐ基板。**同じ基板を2枚作り**、XIAO-A を Pmod J4（右）、XIAO-B を J5（中央）に差す。HDMI Pmod は J6（左）。

- 大きさ 19.0 × 34.5 mm、2層、1.6 mm 厚
- 配線 0.25 mm／クリアランス 0.18 mm／ビア 0.6/0.3 mm、両面ベタ GND。どの基板メーカーの標準仕様でも作れる
- DRC: エラー 0、未接続 0（`kicad/drc.rpt`）。残る警告は J1 のシルクを Fab 層へ移したことによる「ライブラリと不一致」の1件だけで、意図したもの
- 回路図: `fab/c5vrx_pmod_adapter_schematic.pdf`、外観: `images/pcb_top.png` と `images/pcb_bottom.png`

## 差す向き

Sipeed 純正 Pmod モジュールと同じく、**部品面を上にして**差す。基板の J1 側が Dock、USB-C 側が外を向く。

J1 の並び（Dock の外からのぞいた向き、左→右）:

| 段 | 左 → 右 | Pmod 番号 |
|---|---|---|
| 上段 | 3V3, GND, OPT_CLK, CVBS2, CVBS1, CVBS0 | 6, 5, 4, 3, 2, 1 |
| 下段 | 3V3, GND, (空き), CVBS5, CVBS4, CVBS3 | 12, 11, 10, 9, 8, 7 |

KiCad 上の J1 のピン番号（1〜12、奇数が上段）は Pmod 標準の番号とは別物なので注意。FPGA ボールとの対応は `../../design/interface.md` §2〜§3。

## 回路

- **XIAO の D4〜D9 → 33 Ω（R1〜R6）→ Pmod**。ダンピング抵抗で、40 MHz 出力のリンギングを抑える。
- XIAO の D0〜D3、D10 は C5VRX が内部の RF IQ ループバックに使うので**どこにもつないでいない**。
- **XIAO は 1×7 のピンソケット2本に差す**（基板に直接はんだ付けしない）。R1〜R6、C2、C3、JP1、D1 は XIAO の下にある。

## 電源

- **J2（5V, G）**: Dock 裏のデバッガ部の「5V」パッドから線を引いてつなぐ。D1（B5819W）を通って XIAO の 5V ピンへ入る。
  - XIAO に USB をつないだときに Dock 側へ逆流するのを D1 が防ぐ。XIAO が受ける電圧は約 4.6 V。
  - Dock の 5V は USB-C 給電で、ポリスイッチ（2 A）経由。合計は 0.6〜0.8 A の見込みなので、5V/2A 電源を使う。
- **JP1（ソルダージャンパ、初期状態は開放）**: はんだで閉じると XIAO の 3V3 が Pmod の 3V3 とつながる。
  - J2 を使わないときだけ閉じる。
  - 閉じている間は XIAO に USB を挿さないこと（XIAO と Dock の 3.3V 同士がぶつかる）。
- GND は Pmod の GND ピン（2本）と J2 の G の両方で Dock と共通。

## OPT_CLK（任意）

- **TP1（CLK）** は Pmod の IO4 につながっている。J4 では C11（GCLKT_13）、J5 では L5（GCLKT_3）。
- 使う場合は XIAO 裏の MTMS パッド（GPIO2）から細線で TP1 へ配線し、C5VRX の `main/video.c` の `create_tx_unit()` で `clk_out_gpio_num = 2` にする。
- 使わなければ FPGA は 160 MHz の非同期オーバーサンプリングで受ける（設計メモ §4）。

## アナログ映像出力（任意、初期状態は未実装）

- 裏面の R10〜R16 と C4 は C5VRX 本来の抵抗 DAC（参考定数）。
- 実装すると J3（VID, G）からアナログ CVBS が出るので、FPGA と並行してモニタで確認できる。
- 通常は実装しない（BOM で DNP）。

## 製造データ

| ファイル | 内容 |
|---|---|
| `fab/c5vrx_pmod_adapter_gerber.zip` | ガーバー＋ドリル（そのまま基板メーカーへ） |
| `fab/c5vrx_pmod_adapter_bom.csv` | 部品表（DNP 含む。XIAO 用 1×7 ピンソケット ×2 も記載） |
| `fab/c5vrx_pmod_adapter_pos.csv` | 実装位置（表面部品、DNP 除く、原点は基板左下） |
| `kicad/` | KiCad 7 プロジェクト一式（独自ライブラリ c5vrx 同梱） |
| `scripts/` | 生成スクリプト。`design.py` が部品・ネット・配置の元データで、`run.sh` で回路図生成から配線、DRC まで再実行できる（自動配線は Freerouting 2.1） |

## 確認してほしいこと

- **Pmod 間隔**: 写真から約 22 mm と見積もった値で、まだ実測していない。
  - 基板幅は 19 mm なので、隣の Pmod との間に約 3 mm の余裕がある見込み。
  - XIAO の USB-C 側は基板の外側にあるため、隣り合わない。
  - 発注前に、J4 と J5 の中心間をノギスで測ってほしい。
- **J1 の高さ**: J1 は普通の 2×6 L字ピンヘッダ。Dock の Pmod ソケットの高さと合うかを、手元の HDMI Pmod と並べて確認してほしい。
