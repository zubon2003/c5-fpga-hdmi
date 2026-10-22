# c5-fpga-hdmi

[English README](README.md)

> **実験段階です。至近距離でしか動作を確認していません。** VTX を受信機の
> すぐ近く（机の上、約 1 m）に置いた状態でしか動作を確認していません。
> 受信距離、弱い信号での動作、他の VTX や他のチャンネルは試していません。
> 実用的な FPV 受信機ではなく、動作原理の確認（概念実証）として扱ってください。

[C5VRX](https://github.com/Twotoz/C5VRX) を動かしている ESP32-C5 で受信した
5.8 GHz のアナログ FPV 映像（FM、NTSC）を、Sipeed の **Tang Primer 25K**
FPGA で復調し、HDMI モニターに **1280×720p、約 60 Hz** のカラー映像として
表示します。

C5VRX-5 のファームウェアは、受信機の生の 4 ビット IQ サンプル
（MODEM_DIAG Q4/I4）を 8 本の GPIO にすでに出しています。FPGA はその
ピンを並列に読むだけで、ESP32-C5 のファームウェアは改変せずに使います。
ゲイン制御、AFC、チャンネル選択は、引き続き ESP32-C5 が行います。

## 由来

- **[fpvdec / 5G8atv-rf-hackrf-decoder](https://github.com/zubon2003/5G8atv-rf-hackrf-decoder)**
  — このプロジェクトの出発点になった、HackRF One 用のアナログ FPV 映像の
  ソフトウェア受信機（作者のもの）です。fpvdec 自体は、GOROman 氏の
  [famicom-rf-hackrf-decoder](https://github.com/GOROman/famicom-rf-hackrf-decoder)
  をベースにしています。fpvdec の NTSC デコーダと C5VRX 受信系の
  エミュレーション（`--c5`）を、ここでの処理の参考にしました。FPGA の設計は
  新しく書いた HDL です。
- **[C5VRX](https://github.com/Twotoz/C5VRX)**（Twotoz 氏と C5VRX
  コントリビューター）— ESP32-C5 の FPV 受信機です。このプロジェクトは、
  C5VRX の MODEM_DIAG IQ の GPIO 出力（レーンの割り当てとピン順、C5VRX-5 の
  `main/rf.c`）を使い、「C5 を RF フロントエンドにして、信号処理は外部の
  ロジックで行う」という研究（C5VRX-4 の `RESEARCH.md`）に沿っています。
  同期分離には C5VRX-4 の sync flywheel（`SYNC_FLYWHEEL.md`）のライン格子の
  考え方を、FM 復調には C5VRX-5 の U85Q 位相トラッカーと kp ラダーの考え方を
  広げて使っています。[クレジット](#クレジット) を参照してください。

## 必要なハードウェア

| 部品 | 備考 |
|---|---|
| Seeed XIAO ESP32-C5 | C5VRX-5 を書き込んだもの（下記） |
| Sipeed Tang Primer 25K + Tang Primer 25K Dock | GW5A-LV25MG121 |
| Sipeed PMOD DVI（HDMI）モジュール | Dock の PMOD **J6** に挿す |
| HDMI モニターまたはキャプチャ装置 | 720p 入力に対応したもの |
| ジャンパ線 9 本（信号 8 本 + GND）、短いもの | XIAO → Dock の PMOD **J4** |
| アナログ 5.8 GHz VTX（NTSC） | F3（5780 MHz）で確認 |

### C5VRX のバージョン

C5VRX-5 の公式リリース **`c5vrx5-v5.0.332`**（commit `24da232`）を、改変せずに
使って確認しました。[C5VRX の Web フラッシャー](https://twotoz.github.io/C5VRX/)
または GitHub のリリースから書き込めます。下の IQ の GPIO の割り当ては、
このバージョンのものです（v5.0.322 も同じでした）。今後のバージョンで変わる
可能性があるので、C5VRX の `main/rf.c` にある `s_iq_pins` と `s_lane_diag` を
確認してください。チャンネルは、いつもどおり C5 側（BOOT ボタンのメニューか
USB コンソール）で合わせ、起動時の校正が終わるのを待ってください。

## 結線（XIAO ESP32-C5 → Tang Primer 25K Dock J4）

Dock の PMOD J4 のピン番号は、Dock の回路図どおりです。1/2 番が +3V3、
3/4 番が GND、5〜12 番が信号です（左列が偶数ピン、右列が奇数ピン）。
配線する前に、テスターで 1 番ピン（+3.3 V）を確認してください。

```
   XIAO ESP32-C5                         Tang Primer 25K Dock, PMOD J4
   （表面）                                    ┌─────────┐
   GND  ──────────────────────────────── 3/4  │ 2    1  │  +3V3（接続しない）
   D0   (GPIO1)  ── Q bit 0 ───────────── 5   │ 4    3  │  GND
   D1   (GPIO0)  ── Q bit 1 ───────────── 6   │ 6    5  │
   D2   (GPIO25) ── Q bit 2 ───────────── 7   │ 8    7  │
   D3   (GPIO7)  ── Q 符号  ───────────── 8   │ 10   9  │
   D10  (GPIO10) ── I bit 0 ───────────── 9   │ 12  11  │
   （裏面の JTAG パッド）                      └─────────┘
   MTDO (GPIO5)  ── I bit 1 ───────────── 10
   MTDI (GPIO3)  ── I bit 2 ───────────── 11
   MTCK (GPIO4)  ── I 符号  ───────────── 12
   MTMS (GPIO2)  ── 接続しない（C5VRX-5 の同期フライホイールの出力）
```

| J4 ピン | FPGA のピン | `iq[n]` | 信号 | XIAO のピン | ESP32-C5 の GPIO |
|---|---|---|---|---|---|
| 1, 2 | +3V3 | – | 接続しない | – | – |
| 3 か 4 | GND | – | グラウンド | GND | – |
| 5 | C11 | 0 | Q bit 0 | D0 | 1 |
| 6 | C10 | 1 | Q bit 1 | D1 | 0 |
| 7 | B11 | 2 | Q bit 2 | D2 | 25 |
| 8 | B10 | 3 | Q 符号 | D3 | 7 |
| 9 | D11 | 4 | I bit 0 | D10 | 10 |
| 10 | D10 | 5 | I bit 1 | MTDO（裏面パッド） | 5 |
| 11 | G11 | 6 | I bit 2 | MTDI（裏面パッド） | 3 |
| 12 | G10 | 7 | I 符号 | MTCK（裏面パッド） | 4 |

- 2 つの 3.3 V 電源同士はつながないでください。どちらのボードも、それぞれの
  USB から給電します。GND は必ず共通にしてください。
- 配線は短く（目安 10 cm 以下）してください。IQ のビットは 80 MHz で変化します。
- XIAO の裏面の JTAG パッドにある I の 3 本は、はんだ付けが必要です。
- PMOD DVI は **J6** に挿します。J5 は空いています。

## 書き込み

ビルド済みのビットストリームを [GitHub のリリース](../../releases) に添付して
あります（Gowin Programmer 用の `c5_fpga_hdmi.fs`、ほかの書き込みツール用の
`c5_fpga_hdmi.bin`）。

Gowin Programmer（Education 版、ライセンス不要）で書き込みます。デバイスは
**GW5A-25A / GW5A-LV25MG121NC1/I0** です。

```powershell
# SRAM（電源を切ると消える）
programmer_cli.exe --device GW5A-25A --run 2  --fsFile c5_fpga_hdmi.fs
# 外部フラッシュ（電源投入時に起動、約 3 分）
programmer_cli.exe --device GW5A-25A --run 54 --fsFile c5_fpga_hdmi.fs
```

Programmer がデバイス ID の不一致を出した場合は、ボードが GW5A-25B の
可能性があります。`scripts/build.tcl` の `set_device` を変えて、ビルドし直して
ください。

### ビルド

Gowin EDA Education 1.9.11.03（バッチ実行）:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1
# 出力: impl\pnr\c5_fpga_hdmi.fs
```

## 使い方

XIAO（C5VRX-5 を VTX のチャンネルに合わせたもの）と Dock に電源を入れ、
HDMI をつなぎます。VTX がついていれば、1 秒ほどで映像が出ます。VTX がない
ときは、出力は約 59.9 Hz で自走します。画面右上の小さな四角は、水平同期を
検出できている間は緑、できていないときは赤になります。

Dock の USB デバッガには UART（2 つ目の COM ポート、1 Mbaud）があります。
1 文字送ると、実行中に設定を変えられます（電源を切ると元に戻ります）。

| キー | 動作 |
|---|---|
| `P` / `W` | 画像（初期値）/ 復調した 1 ラインの波形モニター |
| `u` / `d` | 有効ラインの開始を −/+ 1 |
| `h` / `l` | 画像の開始位置を −/+ 0.2 µs |
| `f` | フィールドの上下補正の向き（インターレース） |
| `c` | 色のオン・オフ |
| `v` | V の符号（色相） |
| `a` / `z` | 色の濃さ +/− 0.25 倍 |
| `[` / `]` | 色相 −/+ 11.25° |
| `T` | 内部状態（同期、レベル、色のロック） |
| `C` `S` `B` `G` | ロジアナの取り込み（生の IQ、シンボル、FM 検波出力、色信号） |

`scripts/viewer.py` は、UVC キャプチャ装置経由で HDMI の出力を表示し、
ウィンドウからこれらのキーを送り、`T` の内容を読みやすく表示します。

```powershell
py -3 scripts\viewer.py --device "C8 USB3.0 Video" --port COM4
```

必要なもの: numpy と pyserial を入れた Python 3、PATH の通った ffmpeg。
`scripts/iqla.py`、`demod.py`、`fm_model.py`、`resampler_model.py` は、各段を
実機で検証するのに使った PC 側のツールとビット単位のモデルです。

## 仕組み

```
XIAO ESP32-C5（C5VRX-5、改変なし）: RF、ADC、ゲイン、AFC
  │ MODEM_DIAG Q4/I4 を 8 本の GPIO に出力、約 80 MHz、クロックなし
  ▼
Tang Primer 25K
  IDES8 入力         675 MS/s、IQ シンボルあたり 8.4 サンプル
  iq_resampler       位相追従リサンプラ（バイト単位の Alexander 型位相比較）
                     → シンボルあたり 1 バイトの IQ、約 80 MS/s
                     （C5 と Dock の水晶の差、約 30 ppm を追従）
  fm_demod           位相 LUT、隣接差分、22 タップの移動和
  video_in           同期分離（ヒステリシス、パルス幅、フライホイール）、
                     フィールドとパリティ、バックポーチと同期の深さから
                     黒と白のレベル、1 ライン 640 点を 32 ラインのリングへ
  chroma             バーストに周波数ロックした 3.58 MHz の NCO、
                     ライン間で平均したバースト基準（色相と ACC）、
                     1.6 µs の色のローパス、上下 2 ラインの色の平均
  display            縦方向の補間で 240 → 720 ライン（フィールド 2 は
                     1.5 行下に配置）、BT.601 で RGB へ
  video_timing       1280×720、常に 750 ライン × 1657 ピクセル。入力の
                     フィールドへの同期は、垂直フロントポーチの 5 ラインの
                     長さだけを変えて取る（PI 制御）
  TMDS / OSER10      → PMOD DVI（J6）
```

立ち上げで分かったこと:

- C5 の GPIO の IQ は 80 MHz で更新されています（C5VRX 自身は 40 MS/s で
  取り込んでいます）。
- フレームの長さが毎フレーム変わる出力（以前の版は、入力を待つために最後の
  ラインを繰り返していました）は、キャプチャ装置では映りましたが、HDMI
  モニターでは映りませんでした。また、映像部分のラインの長さを変えると、
  キャプチャ装置で画像が斜めにずれました。今は、垂直フロントポーチの
  ラインだけ長さを変えています。
- くっきりした横の輪郭（OSD の文字）は、フィールドの切り替わりで今も約 1
  ラインずれます。各フィールドを 1 枚ずつ表示している（ボブ方式）ためです。
  なくすには、1 フィールド分を保存するメモリ、つまり外付けの SDRAM が必要です。
- 開発で使ったキャプチャ装置は、書き込み直後に真っ黒のままになることが
  ありました。表示モードを一度切り替える（`W` → `P`）と戻ります。

使用資源: LUT 約 5,000、BSRAM 56 個中 49 個、DSP 15 個。

詳しい開発記録（日本語）は [docs/DEVLOG.ja.md](docs/DEVLOG.ja.md) にあります。

## ライセンス

GPL-3.0-only — [LICENSE](LICENSE) を参照してください。

## クレジット

このプロジェクトは、Twotoz 氏と C5VRX コントリビューターによる
[C5VRX](https://github.com/Twotoz/C5VRX) から、ESP32-C5 の MODEM_DIAG IQ の
GPIO 出力（Q4/I4 のレーンの割り当てとピン順、C5VRX-5 の `main/rf.c`）と、
「C5 を RF フロントエンドにして、信号処理は外部のロジックで行う」という
構成の研究（C5VRX-4 の `legacy/c5vrx4/RESEARCH.md`）と、予測位置の近くの
同期パルスだけを受け付ける PLL ライン格子の考え方（C5VRX-4 の sync flywheel、
`legacy/c5vrx4/SYNC_FLYWHEEL.md`。ここでは `src/video_in.v` のライン PLL として
新しく実装し、ラインのタイミングだけに使っています。同期パルスの再生はしません）と、
ループゲインを選べる位相トラッカー型の FM 復調（C5VRX-5 の U85Q トラッカーと
kp ラダー、`main/u85q.bsasm`、`main/kp_ladder.h`、`research/README.md`。ここでは
`src/fm_demod.v` で 2 次ループ、振幅で絞る補正、途切れないモード切り替えを加えて
います。`research/demod_sim.py` の信号とチャネルのモデルは C5VRX-5 の距離
シミュレータ `research/sim.py` に沿っています）を取り入れています。
元のプロジェクトと Discord への招待は
[C5VRX 公式サイト](https://twotoz.github.io/C5VRX/) にあります。適用される
条件は、ソースとライセンスの表示を参照してください（C5VRX は
GPL-3.0-only です）。このプロジェクトは C5VRX の公式リリースではありません。

- [fpvdec / 5G8atv-rf-hackrf-decoder](https://github.com/zubon2003/5G8atv-rf-hackrf-decoder)
  （GPL-3.0-only）。GOROman 氏の
  [famicom-rf-hackrf-decoder](https://github.com/GOROman/famicom-rf-hackrf-decoder)（MIT）がベースです。
- Tang Primer 25K Dock の PMOD / HDMI のピン配置と PLL の設定は、Sipeed の
  [TangPrimer-25K-example](https://github.com/sipeed/TangPrimer-25K-example)
  （`hdmi/svo`、commit 27c1737）と Dock の回路図に従っています。HDL は新しく
  書いたものです。
