# XIAO ESP32-C5 ×2 → Tang Primer 25K Dock インターフェース設計

最終更新: 2026-10-06（スレッド1、第3版: C5VRX のピン配置に合わせて修正。SDRAM を残し、XIAO は Pmod 2つに接続）
旧案（40ピンヘッダに XIAO を載せる案）は [interface_v1_main-header.md](interface_v1_main-header.md)。

## 0. 前提と結論

- 入力: C5VRX（https://github.com/Twotoz/C5VRX ）を書き込んだ XIAO ESP32-C5 ×2。
  C5VRX は **6bit の CVBS を 20MS/s**（PARLIO TX 40MHz、同じ値を2回ずつ出す [D,D] 方式）で **D4〜D9** に出している。NTSC/PAL 両対応。
- 出力: HDMI **1280×720p**。
- **40ピンヘッダ（J3）は SDRAM モジュール（32MB）用に残す**。SDRAM は38本の I/O をすべて使うので、J3 に空きはない。
- 残りのユーザー I/O は **Pmod 3つ × 8本 = 24本**。HDMI Pmod が8本使うので、**XIAO に使えるのは16本（1台あたり8本）**。
- 1台あたり実際に必要なのは **6本（D4〜D9）だけ**。C5VRX はクロックを外に出していないので、**FPGA 側で 160MHz でオーバーサンプリングして 20MS/s を取り出す**（ファーム変更なし）。
  クロックを直接もらいたい場合は、ファームを1行変えて XIAO 裏面の GPIO2（MTMS）パッドに 40MHz を出し、Pmod の GCLK ピンへ配線できるようにしておく（任意）。
- **XIAO の D0, D1, D2, D3, D10 は C5VRX が RF の IQ 取り込みに使っている**（チップ内部の信号を一度ピンに出して読み戻している）。アダプタ上では **どこにも接続しない**こと。
- 配置: **左 Pmod（J6）= HDMI、中央 Pmod（J5）= XIAO-B、右 Pmod（J4）= XIAO-A**。

## 1. Dock で使える I/O の内訳

| 場所 | 本数 | 用途 |
|---|---|---|
| 40ピンヘッダ J3 | 38 | SDRAM モジュールが全部使う（空き 0） |
| Pmod J6（左） | 8 | HDMI Pmod |
| Pmod J5（中央） | 8 | XIAO-B |
| Pmod J4（右） | 8 | XIAO-A |
| ボタン S1/S2、READY/DONE LED、USB-A、デバッガ UART | 各2 | Dock 上の部品につながっていて外に出ていない（はんだ付けで流用は可能だが非推奨） |

Pmod の電源ピンは **3V3 と GND のみ**（5V は無い）。I/O はすべて LVCMOS33。

## 2. Pmod のピンと FPGA の機能

Pmod 標準のピン番号で書く。上段がピン1〜6、下段がピン7〜12 で、ピン1〜4（7〜10）が I/O、ピン5（11）が GND、ピン6（12）が 3V3。

| Pmod | 上段 ピン1〜4 | 下段 ピン7〜10 | クロック専用ピン |
|---|---|---|---|
| J6（左） | F5, G7, H8, H5 | G5, G8, H7, J5 | H5 = GCLKT_2 |
| J5（中央） | A11, E11, K11, L5 | A10, E10, L11, K5 | E11 = GCLKT_14, L5 = GCLKT_3 |
| J4（右） | G11, D11, B11, C11 | G10, D10, B10, C10 | C11 = GCLKT_13 |

物理的な並び（第2版で訂正）: Dock の外側からソケットをのぞき込むと、上段は左から 3V3, GND, IO4, IO3, IO2, IO1 の順（J4 なら 3V3, GND, C11, B11, D11, G11）。Dock 裏のシルクは裏から見た向きなので左右が逆に見える。アダプタ基板はこの向きに合わせてあり、Sipeed 純正 Pmod モジュールと同じく「部品面を上にして差す」だけで正しく入る（../hw/pmod_adapter/README.md）。

## 3. 信号の割り当て

### C5VRX の XIAO ピン使用状況（main ブランチ、2026-10-04 時点の Kconfig 既定値）

| XIAO ピン | GPIO | C5VRX での用途 | アダプタでの扱い |
|---|---|---|---|
| D4 | GPIO23 | CVBS bit0（LSB） | → FPGA |
| D5 | GPIO24 | CVBS bit1 | → FPGA |
| D6 | GPIO11 | CVBS bit2 | → FPGA |
| D7 | GPIO12 | CVBS bit3 | → FPGA |
| D8 | GPIO8 | CVBS bit4 | → FPGA |
| D9 | GPIO9 | CVBS bit5（MSB） | → FPGA |
| D0, D1, D2, D3, D10 | GPIO1, 0, 25, 7, 10 | RF の IQ 取り込み（内部信号の折り返し） | **未接続**（パッドだけ、配線しない） |
| 裏面 MTMS | GPIO2 | 未使用 | 任意: クロック出力用（ファーム変更時） |
| 裏面 MTDO/MTDI/MTCK | GPIO5, 3, 4 | RF の IQ 取り込み | 未接続 |
| BOOT ボタン | GPIO28 | チャンネル切替・メニュー | XIAO のボタンをそのまま使う |
| USB-C | GPIO13/14 | 書き込み・シリアルコンソール | そのまま使う |

- CVBS の値は FM 復調後の映像波形そのもの（同期、輝度、色副搬送波を含む）。値は 40MHz の立ち下がりで切り替わり、同じ値が2クロック（50ns）続く。
- 元の抵抗 DAC（ゴーグルへのアナログ出力）を同時に付けても FPGA 側は問題ない。アダプタには DAC の抵抗のフットプリントを「実装しない」前提で残しておくと、アナログ出力も使える。

### 1台あたりの Pmod 配線（8本中6本使用）

| Pmod の位置 | 信号 | XIAO ピン |
|---|---|---|
| 上段1番目 | CVBS0 | D4 |
| 上段2番目 | CVBS1 | D5 |
| 上段3番目 | CVBS2 | D6 |
| 上段4番目（GCLK ピン） | OPT_CLK（任意） | 裏面 GPIO2 パッドから線（通常は未接続） |
| 下段1番目 | CVBS3 | D7 |
| 下段2番目 | CVBS4 | D8 |
| 下段3番目 | CVBS5 | D9 |
| 下段4番目 | 予備 | 未接続 |

J4 と J5 で同じ位置にしてあるので、アダプタは同じ基板を2枚作ればよい（1枚にまとめる場合も同じ並び）。

### FPGA ボール

| 信号 | XIAO-A → J4（右） | XIAO-B → J5（中央） |
|---|---|---|
| CVBS0 | G11 | A11 |
| CVBS1 | D11 | E11 |
| CVBS2 | B11 | K11 |
| OPT_CLK | C11（GCLKT_13） | L5（GCLKT_3） |
| CVBS3 | G10 | A10 |
| CVBS4 | D10 | E10 |
| CVBS5 | B10 | L11 |
| 予備 | C10 | K5 |

### FPGA 制約ファイルのたたき台（.cst）

```
// XIAO-A on J4
IO_LOC "xa_cvbs[0]" G11; IO_LOC "xa_cvbs[1]" D11; IO_LOC "xa_cvbs[2]" B11;
IO_LOC "xa_cvbs[3]" G10; IO_LOC "xa_cvbs[4]" D10; IO_LOC "xa_cvbs[5]" B10;
IO_LOC "xa_clk_opt" C11;
// XIAO-B on J5
IO_LOC "xb_cvbs[0]" A11; IO_LOC "xb_cvbs[1]" E11; IO_LOC "xb_cvbs[2]" K11;
IO_LOC "xb_cvbs[3]" A10; IO_LOC "xb_cvbs[4]" E10; IO_LOC "xb_cvbs[5]" L11;
IO_LOC "xb_clk_opt" L5;
// HDMI (PMOD-DVI on J6, Sipeed nestang と同じ)
IO_LOC "tmds_d_p[0]" H8,H7; IO_LOC "tmds_d_p[1]" G7,G8; IO_LOC "tmds_d_p[2]" F5,G5; IO_LOC "tmds_clk_p" H5,J5;
// SDRAM on J3: Sipeed nestang-25k の nestang.cst をそのまま使う
// 入力はすべて IO_TYPE=LVCMOS33 PULL_MODE=NONE BANK_VCCIO=3.3
```

## 4. 受信方式と帯域

- **既定: FPGA で非同期オーバーサンプリング**（XIAO のファームは無変更）。
  - 6本を 160MHz（40MHz の4倍）で2段 FF に取り込む。
  - 値が変わるタイミング（40MHz の格子に乗っている）から位相を推定し、変化点から最も遠い位相で 20MS/s のサンプルを取り出す。
  - XIAO の水晶（40MHz）と FPGA の 50MHz 発振器のずれは数十 ppm なので、位相はゆっくり追従するだけでよい。
  - ビット間のずれ（数 ns）は1サンプル幅 50ns に対して十分小さい。
- **任意: ソース同期**。C5VRX の `create_tx_unit()`（main/video.c）で `clk_out_gpio_num = 2` にすると、
  GPIO2（裏面 MTMS パッド）に 40MHz のクロックが出る。これを Pmod の GCLK ピン（OPT_CLK）に配線すれば、FPGA はそのクロックで取り込める。
  裏面パッドへのはんだ付けが要るので、まずは既定の方式で始める。
- 帯域: 6bit × 20MS/s = 120Mbps/台。色副搬送波（NTSC 3.58MHz）の約 5.6 倍のサンプルレートなので、色の復調も可能。
- 各 Pmod に GND が2本あり、信号は 20MS/s なので Pmod で問題ない速度。必要なら XIAO 側に直列抵抗 33Ω を入れる。


## 5. 720p 変換（SDRAM を使う）

SDRAM（32MB, 16bit）があるので、**フレームバッファ方式**にできる。

- 入力: 各XIAO のフィールド（20MS/s なら有効期間 約 1040 サンプル × 240 ライン）を YCbCr で SDRAM に書く。
- 出力: 標準の 720p60（74.25MHz, 1650×750）を固定で出し、SDRAM から読みながら縦3倍・横拡大する。
  入力と出力のフレームレート差は、フィールドの破棄や繰り返しで吸収する（トリプルバッファ）。
- 遅延は最大1フレーム程度（約17ms）。遅延を最小にしたい場合は、第1版のラインバッファ方式（出力を入力に同期させる）も選べる。
- 帯域の見積もり: 出力読み出し 720×240×2B×60 ≈ 21MB/s、入力書き込み 2台で約 42MB/s。
  SDRAM（16bit, 100MHz 以上）の実効帯域 100MB/s 以上に対して余裕がある。
- **表示モードは2つとも実装し、Dock のボタン S1（H11）で切り替える**（2026-10-06 決定）。ハードは同じで、FPGA の設定だけが違う。
  - **ダイバーシティ**: 2台を同じチャンネルにして（各XIAO の BOOT ボタンで設定）、フィールドごとに同期の品質（同期パルスの検出率、ノイズ量）を比べ、良いほうのフィールドを表示する。
    切替はフィールドの境目で行い、SDRAM 上で両方のフィールドを持っているので切替時に画面が乱れない。
  - **2画面**: 2台の映像を横に並べる。4:3 の映像を各 640×480（横は約 1040 サンプル→640、縦は 240→480 で2倍）にして左右に置き、720p の上下 120 ラインずつは黒にする。
    2台は別々の送信機・チャンネルでもよい（それぞれ独立に同期を取る）。
  - 乗算器の見積もりは [multiplier_budget.md](multiplier_budget.md)。DSP を時分割すれば、2画面でもカラー2台分で 16 個程度（28 個中）に収まる見込み。

## 6. 電源計画

Pmod には 3V3 しか無い。XIAO の給電は次のどちらか:

| 案 | 方法 | 長所 | 注意 |
|---|---|---|---|
| **A（推奨）** | Dock 裏のデバッガ用パッド「5V」から線を引き、ダイオード（B5819W など）経由で各XIAO の 5V ピンへ | XIAO 内蔵の LDO で 3.3V を作るので Dock の 3V3 に負担をかけない。XIAO の USB を挿しても逆流しない | アダプタに 5V 入力用のピンかパッドが要る |
| B | Pmod の 3V3 を XIAO の 3V3 ピンへ直結 | 配線が Pmod だけで済む | Dock の 3V3 の電流余裕が不明（ESP32-C5 は送信ピークで約 300mA）。XIAO に USB を挿すと 3.3V 同士がぶつかるので、書き込み時はジャンパで切る |

- Dock の 5V は USB-C（デバッガ側）から **ポリスイッチ FU1（6V 2A）** を通って来る（Dock 回路図の読み取り）。Dock 全体で約 2A が上限で、実際には USB 電源側の能力で決まる。
- 消費の目安: FPGA コア＋Dock＋SDRAM＋HDMI で 0.3〜0.5A、C5VRX は 5GHz 受信を続けるので 1台 0.1〜0.15A 程度。合計 0.6〜0.8A。
  PC の USB 2.0（0.5A）では足りない可能性が高いので、**5V/2A 以上の USB 電源か USB-C 充電器**を使う。
- A 案でも GND は Pmod の GND ピンで共通にする。
- 各XIAO の電源ピンに 10µF + 0.1µF を置く。
- Dock が無電源のまま XIAO だけ動かさない（FPGA の I/O に電流が回り込む）。直列抵抗が保護にもなる。

## 7. 物理配置と Pmod 間隔の干渉

```
 ┌──────────────── 64 mm ────────────────┐
 │○ [J3 40ピン: SDRAM モジュール]       ○ │ ← 上辺
 │ MODE  LED      [25K コア]     S1 S2     │
 │ USB-A                    BL616  USB-C   │
 │ [Pmod J6]  C  [Pmod J5]  C  [Pmod J4]  │ ← 下辺。直角コネクタ、外へ突き出す
 └─────────────────────────────────────────┘
      HDMI        XIAO-B         XIAO-A
```

- Pmod の中心間隔は **約 22mm**（Dock 写真からの概算。実物をノギスで確認すること）。Pmod コネクタ自体の幅は 15.2mm（6ピン×2.54mm）。
- XIAO の幅は 17.8mm なので、**XIAO の長辺を外向き（Pmod から真っ直ぐ外）に向ければ、1枚あたり幅 20mm 前後のアダプタに収まる**。
  隣とは 2mm 程度しか空かないので、アダプタの幅は **21mm 以下**にする。
- HDMI ケーブルのプラグは太いので、HDMI を端（J6）に置くのが良い。
- おすすめは、**J5 と J4 の2つに同時に挿さる1枚のアダプタに XIAO を2台載せる**形。2枚が互いに当たる心配がなく、機械的にも安定する。
  そのためには J5 と J4 の正確な間隔が必要（実測するか、Sipeed の機構図で確認）。
- 2枚に分ける場合は同じ基板を2枚作る（§3 で配線位置を揃えてある）。XIAO の USB-C とアンテナ（U.FL）は外向きにする。
- 5.8GHz のアンテナは HDMI ケーブルからできるだけ離す。

## 8. 未確定事項

1. ~~2台の使い方~~ → ダイバーシティと2画面の両方を実装し、ボタンで切り替える（決定済み、§5）。
2. 映像方式: C5VRX は NTSC/PAL を自動判定する。HDMI 出力は NTSC 入力なら 720p60、PAL なら 720p50 を既定にする。
3. Pmod J5–J4 の正確な間隔（1枚アダプタにする場合）。
4. 給電を A 案（5V 線）と B 案（Pmod 3V3）のどちらにするか（既定は A 案）。
5. ソース同期クロック（GPIO2）を使うか（既定は使わない）。

## 参考資料

- Sipeed Wiki: Tang Primer 25K — https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html
- Sipeed Wiki: TANG PMOD（SDRAM, PMOD-DVI） — https://wiki.sipeed.com/hardware/en/tang/tang-PMOD/FPGA_PMOD.html
- Dock 回路図 — https://dl.sipeed.com/fileList/TANG/Primer_25K/02_Schematic/Tang_Primer_25K_Dock_60033_Schematic.pdf
- Gowin UG985（GW5A-25 ピン配置） — https://cdn.gowinsemi.com.cn/UG985E.pdf
- LiteX boards: sipeed_tang_primer_25k.py — https://github.com/litex-hub/litex-boards
- Sipeed TangPrimer-25K-example（nestang-25k の SDRAM/HDMI 制約） — https://github.com/sipeed/TangPrimer-25K-example
- Seeed Wiki: XIAO ESP32-C5 — https://wiki.seeedstudio.com/xiao_esp32c5_getting_started/
- C5VRX — https://github.com/Twotoz/C5VRX （README のピン表、main/Kconfig、main/video.c の create_tx_unit）
- ESP-IDF: ESP32-C5 GPIO / Parallel IO TX — https://docs.espressif.com/projects/esp-idf/en/stable/esp32c5/api-reference/peripherals/gpio.html
