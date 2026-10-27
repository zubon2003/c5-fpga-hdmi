# dual/ — XIAO ESP32-C5 ×2 ダイバーシティ版（開発中）

XIAO ESP32-C5（C5VRX）を **2台** つなぎ、Tang Primer 25K で画質の良い方を選ぶ
ダイバーシティ表示と、2画面表示（640×480 ×2）を切り替えて 720p で出す版です。
リポジトリ直下の 1台版とは **ピン配置もファームウェアも互換がありません**。
直下の README の結線説明はこのフォルダには当てはまりません。

> **実機では未確認です。** どちらの FPGA 設計も Verilator のシミュレーションだけで
> 確認しています。Gowin IDE での合成・配置配線も未実施です。表示は白黒です。

## 中身

| フォルダ | 内容 |
|---|---|
| [`fpga/`](fpga/README.md) | 第1版。C5VRX が出す 6bit の CVBS（抵抗 DAC 用の信号）を 2台分受けて復調する |
| [`fpga_iq/`](fpga_iq/README.md) | IQ 版。2台から生の 4bit IQ を受けて FPGA で FM 復調する |
| [`firmware/`](firmware/README.md) | IQ 版用の改造 C5VRX-5 ファーム（パッチとビルド済みイメージ）。IQ を XIAO の端のピンに移し、受信状態を UART で送る |
| [`hw/pmod_adapter/`](hw/pmod_adapter/README.md) | XIAO を Dock の Pmod に直接差すアダプタ基板 rev A（KiCad、ガーバー、BOM、実装位置） |
| [`design/`](design/) | 設計メモ（Tang とのインターフェース、IQ リンク、4in1 の案、乗算器の見積もり） |

## 構成

- Dock の Pmod: XIAO-A を **J4**、XIAO-B を **J5**、HDMI（PMOD DVI）を **J6**。
- Dock の **S1** でダイバーシティ表示と 2画面表示を切り替える。
- ビルドとシミュレーションの手順は各フォルダの README を参照。

## ライセンス

リポジトリ直下の [LICENSE](../LICENSE)（GPL-3.0）に従います。`firmware/` は
[C5VRX](https://github.com/Twotoz/C5VRX)（Twotoz 氏と C5VRX コントリビューター、
GPL-3.0）への改変で、公式リリースではありません。
