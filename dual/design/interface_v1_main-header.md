# XIAO ESP32-C5 ×2 → Tang Primer 25K Dock インターフェース設計

> 旧案（XIAO を40ピンヘッダに載せる案）。SDRAM が必要になったため採用せず、現行は interface.md。

最終更新: 2026-10-06（スレッド1、6bit CVBS → 720p 前提に更新）

## 0. 前提と結論

- 入力: C5VRX（XIAO ESP32-C5）が出す **6bit の CVBS（コンポジット映像のサンプル列）** を2台分。
- 出力: HDMI **1280×720p**（NTSC 入力なら 720p59.94、PAL 入力なら 720p50）。
- XIAO 2台をドーター基板に載せ、Dock の **40ピンヘッダ（J3, 2×20, 2.54mm）** に挿す。
- HDMI は手持ちの HDMI Pmod（Sipeed PMOD-DVI 相当を想定）を **左端の Pmod（J6）** に挿す。
- 各XIAO → FPGA は **6bit パラレル + サンプルクロック**（ESP32-C5 の PARLIO 送信）。11本すべて FPGA へ配線し、残りは予備・制御用にする。
- 720p 変換は **ラインバッファ方式（出力を入力フィールドに同期させる）** にする。必要なメモリは数十ライン分なので **SDRAM なしで FPGA 内蔵メモリに収まる**。遅延も数ライン分（1ms 未満）で、FPV 向き。
- 40ピンヘッダの電源は **5V（11番）と GND（12番）の1本ずつだけ**。3V3 は来ていない。

## 1. Dock 40ピンヘッダ J3 のピン配置（確認済み）

表の「上から見て」は部品面から見た向き。1番ピンは左下（USB-A 側）、40番は右上（USB-C 側）。
奇数ピンが基板内側の列、偶数ピンが基板の縁側の列。

| J3 | FPGAボール | 機能（GW5A-25 MG121） | Bank | | J3 | FPGAボール | 機能 | Bank |
|---|---|---|---|---|---|---|---|---|
| 1 | K2 | IOR20B | 2 | | 2 | K1 | IOR20A | 2 |
| 3 | L1 | IOR18B | 2 | | 4 | L2 | IOR18A | 2 |
| 5 | K4 | IOR22B | 2 | | 6 | J4 | IOR22A | 2 |
| 7 | G1 | IOR24B | 2 | | 8 | G2 | IOR24A | 2 |
| 9 | L3 | IOR31B / GCLKC_4 | 2 | | 10 | L4 | IOR31A / **GCLKT_4** | 2 |
| 11 | — | **+5V** | | | 12 | — | **GND** | |
| 13 | C2 | IOB4B / D09（コンフィグ兼用） | 5 | | 14 | B2 | IOB4A / D08（コンフィグ兼用） | 5 |
| 15 | F1 | IOB26B / GCLKC_9B | 5 | | 16 | F2 | IOB26A / **GCLKT_9B** | 5 |
| 17 | A1 | IOB24A | 5 | | 18 | E1 | IOB12B / RDWR_B（コンフィグ兼用） | 5 |
| 19 | D1 | IOB14B / CLKHOLD_N（コンフィグ兼用） | 5 | | 20 | E3 | IOB60A | 4 |
| 21 | J2 | IOR33B / GCLKC_5 | 2 | | 22 | J1 | IOR33A / **GCLKT_5** | 2 |
| 23 | H4 | IOB89B / GCLKC_7 | 3 | | 24 | G4 | IOB89A / **GCLKT_7** | 3 |
| 25 | H2 | IOB91B / GCLKC_6A | 3 | | 26 | H1 | IOB91A / **GCLKT_6A** | 3 |
| 27 | J7 | IOT21B | 7 | | 28 | K7 | IOT21A | 7 |
| 29 | L8 | IOT19B | 7 | | 30 | L7 | IOT19A | 7 |
| 31 | K10 | IOT15B | 7 | | 32 | L10 | IOT15A | 7 |
| 33 | K9 | IOT31B | 0 | | 34 | L9 | IOT31A | 0 |
| 35 | K8 | IOT56B / GCLKC_0 | 0 | | 36 | J8 | IOT56A / **GCLKT_0** | 0 |
| 37 | F6 | IOT58B / GCLKC_1 | 0 | | 38 | F7 | IOT58A / **GCLKT_1** | 0 |
| 39 | J10 | IOT1B / GCLKC_15 | 7 | | 40 | J11 | IOT1A / **GCLKT_15** | 7 |

- I/O 規格はすべて LVCMOS33（Sipeed のサンプル制約が全バンク `BANK_VCCIO=3.3`）。XIAO と直結でよい。
- 単端クロック入力は **GCLKT（True側）** のピンに入れる。
- 13/14/18/19番はFPGAコンフィグ兼用ピンなので、XIAOの信号には使わず予備にする。

出典: Dock 裏面シルク（ピン名が印刷されている）、Sipeed TANG SDRAM V1.1 回路図（11番=VIN、12番=GND）、
LiteX `sipeed_tang_primer_25k.py` の J3 定義、Dock 回路図 `Tang_Primer_25K_Dock_60033`、Gowin UG985（GW5A-25 ピン配置）。

## 2. XIAO ESP32-C5 のピン

| XIAO | GPIO | 既定機能 | 注意 |
|---|---|---|---|
| D0 | GPIO1 | ADC | |
| D1 | GPIO0 | | |
| D2 | GPIO25 | | **ストラッピングピン** |
| D3 | GPIO7 | | **ストラッピングピン** |
| D4 | GPIO23 | I2C SDA | |
| D5 | GPIO24 | I2C SCL | |
| D6 | GPIO11 | UART0 TX | |
| D7 | GPIO12 | UART0 RX | |
| D8 | GPIO8 | SPI SCK | |
| D9 | GPIO9 | SPI MISO | |
| D10 | GPIO10 | SPI MOSI | |
| 5V / 3V3 / GND | | 電源 | 3V3 は出力 |

- 書き込み・デバッグは XIAO 本体の USB-C（USB-Serial-JTAG, GPIO13/14）で行う。ヘッダ側の UART0 はデータに回してよい。
- 裏面パッド（GPIO2〜5, JTAG）は基板に載せると使いにくいので使わない。
- ストラッピングピン（D2, D3）は **XIAO→FPGA の片方向** にし、FPGA からは駆動しない。

## 3. データ方式（6bit CVBS）

### 帯域の見積もり

| サンプルレート | 6bit での転送量 | 備考 |
|---|---|---|
| 13.5 MS/s | 81 Mbps（約 10 MB/s） | 白黒なら十分 |
| 14.32 MS/s（NTSC 色副搬送波の4倍） | 86 Mbps | 色を復調するならこの付近以上が扱いやすい |
| 17.73 MS/s（PAL の4倍） | 106 Mbps | |
| 27 MS/s | 162 Mbps | 上限の目安 |

- 6bit を1サンプル1クロックで並列に送る（6本 + クロック）。サンプルクロックは 13.5〜27MHz なので、GND が1本しかないヘッダでも現実的な速度。
- SPI/QSPI はパケット化と隙間が出るため、映像の連続ストリームには向かない。**PARLIO（パラレル送信）を既定**にする。
- XIAO が **サンプルクロックを出すマスタ**。FPGA はクロックを GCLK ピンで受け、各XIAO のクロックドメインでラインバッファに書き込む。
- 映像の流れは止められないので、FPGA→XIAO の READY 線はフロー制御には使わず、**制御用 UART（FPGA→XIAO）** に回す（チャンネル切り替えなどを FPGA 側から送る用途）。

### 信号の割り当て（1台ぶん）

| 信号 | 方向 | XIAO ピン | 用途 |
|---|---|---|---|
| CLK | XIAO→FPGA | D8 (GPIO8) | サンプルクロック（PARLIO クロック出力） |
| VALID | XIAO→FPGA | D2 (GPIO25) | データ有効（PARLIO valid）。ストリーム開始・停止の区切り |
| CVBS0 | XIAO→FPGA | D10 (GPIO10) | 6bit サンプル bit0（LSB） |
| CVBS1 | XIAO→FPGA | D9 (GPIO9) | bit1 |
| CVBS2 | XIAO→FPGA | D0 (GPIO1) | bit2 |
| CVBS3 | XIAO→FPGA | D1 (GPIO0) | bit3 |
| CVBS4 | XIAO→FPGA | D4 (GPIO23) | bit4 |
| CVBS5 | XIAO→FPGA | D5 (GPIO24) | bit5（MSB） |
| AUX6 | XIAO→FPGA | D3 (GPIO7) | 予備（受信強度フラグなど。PARLIO 8bit の bit6） |
| AUX7 / TX | XIAO→FPGA | D6 (GPIO11) | 状態通知 UART（RSSI、周波数など） |
| CTRL / RX | **FPGA→XIAO** | D7 (GPIO12) | 制御 UART（チャンネル切り替えなど） |

- PARLIO を 8bit 幅で使う場合は bit6 = AUX6、bit7 = AUX7 として同時に送れる（例: bit6 に「ライン先頭」フラグ）。
- C5VRX のファームが既に別のピンで 6bit を出している場合は、ドーター基板を作る前にこの表をそちらに合わせる（ESP32-C5 は GPIO マトリクスでどのピンにも出せるので、ファーム側で合わせるほうが簡単）。

## 4. ピン割当表（2台ぶん）

XIAO-A は J3 の左半分（1〜10, 15番）、XIAO-B は右半分（27〜40番）に寄せる。
電源（11/12番）は左寄りの中央にあるので、ドーター基板上で両XIAOへ分配する。

### XIAO-A（Bank 2 中心）

| 信号 | XIAO-A | J3 | FPGAボール | 備考 |
|---|---|---|---|---|
| CLK_A | D8 | 10 | L4 | GCLKT_4 |
| VALID_A | D2 | 9 | L3 | |
| CVBS0_A | D10 | 1 | K2 | |
| CVBS1_A | D9 | 2 | K1 | |
| CVBS2_A | D0 | 3 | L1 | |
| CVBS3_A | D1 | 4 | L2 | |
| CVBS4_A | D4 | 5 | K4 | |
| CVBS5_A | D5 | 6 | J4 | |
| AUX6_A | D3 | 7 | G1 | |
| AUX7_A / TX_A | D6 | 8 | G2 | |
| CTRL_A / RX_A | D7 | 15 | F1 | FPGA→XIAO |

### XIAO-B（Bank 7 中心）

| 信号 | XIAO-B | J3 | FPGAボール | 備考 |
|---|---|---|---|---|
| CLK_B | D8 | 40 | J11 | GCLKT_15 |
| VALID_B | D2 | 39 | J10 | |
| CVBS0_B | D10 | 32 | L10 | |
| CVBS1_B | D9 | 31 | K10 | |
| CVBS2_B | D0 | 30 | L7 | |
| CVBS3_B | D1 | 29 | L8 | |
| CVBS4_B | D4 | 28 | K7 | |
| CVBS5_B | D5 | 27 | J7 | |
| AUX6_B | D3 | 34 | L9 | Bank 0 |
| AUX7_B / TX_B | D6 | 33 | K9 | Bank 0 |
| CTRL_B / RX_B | D7 | 35 | K8 | Bank 0, FPGA→XIAO |

### 予備ピン（ドーター上の 2.54mm パッドに引き出しておく）

| J3 | ボール | 用途案 |
|---|---|---|
| 16 | F2 (GCLKT_9B) | 予備クロック入力 |
| 17 | A1 | 予備 |
| 20 | E3 | 予備（XIAO の EN をFPGAから操作したい場合など） |
| 21–26 | J2, J1, H4, G4, H2, H1 | 予備（GCLKT_5/7/6A を含む） |
| 36–38 | J8, F6, F7 | 予備（GCLKT_0/1 を含む） |
| 13, 14, 18, 19 | C2, B2, E1, D1 | コンフィグ兼用。基本は未接続 |

### FPGA 制約ファイルのたたき台（.cst）

```
// XIAO-A
IO_LOC "xa_clk"   L4;  IO_LOC "xa_valid" L3;
IO_LOC "xa_cvbs[0]" K2; IO_LOC "xa_cvbs[1]" K1; IO_LOC "xa_cvbs[2]" L1; IO_LOC "xa_cvbs[3]" L2;
IO_LOC "xa_cvbs[4]" K4; IO_LOC "xa_cvbs[5]" J4; IO_LOC "xa_aux6" G1; IO_LOC "xa_aux7" G2;
IO_LOC "xa_ctrl" F1;
// XIAO-B
IO_LOC "xb_clk"   J11; IO_LOC "xb_valid" J10;
IO_LOC "xb_cvbs[0]" L10; IO_LOC "xb_cvbs[1]" K10; IO_LOC "xb_cvbs[2]" L7; IO_LOC "xb_cvbs[3]" L8;
IO_LOC "xb_cvbs[4]" K7;  IO_LOC "xb_cvbs[5]" J7;  IO_LOC "xb_aux6" L9; IO_LOC "xb_aux7" K9;
IO_LOC "xb_ctrl" K8;
// HDMI (PMOD-DVI on J6, Sipeed nestang と同じ)
IO_LOC "tmds_d_p[0]" H8,H7; IO_LOC "tmds_d_p[1]" G7,G8; IO_LOC "tmds_d_p[2]" F5,G5; IO_LOC "tmds_clk_p" H5,J5;
// 入力はすべて IO_TYPE=LVCMOS33 BANK_VCCIO=3.3, ctrl は DRIVE=8
```

## 5. 電源計画

- Dock の USB-C（デバッガ側）から来る 5V が J3 の11番に出ている。ドーターはここから取る。
- 各XIAO の **5V ピン**に、**ショットキーダイオード**（例: B5819W / SS14）経由で 5V を入れる。
  XIAO 内部の LDO が 3.3V を作る。XIAO に USB-C を挿して書き込むときに Dock 側へ逆流しないようにするため。
- XIAO の 3V3 ピン同士・Dock の 3V3 とはつながない（LDO の出力同士がぶつかるため）。
- 消費電流の見積もり（概算）: FPGA+Dock 150〜250mA、ESP32-C5 は受信時 1台 80〜100mA 程度、無線送信のピークで 300mA 前後。
  合計で 0.5〜0.8A 程度になり得るので、PC の USB 3.x ポートか 5V/2A 以上の電源を使う。
- 各XIAO の 5V 入力に 10µF + 0.1µF、ドーターの 5V 入口に 47〜100µF を置く。
- **GND が J3 に1本しかない**。信号20本強の帰りがこの1本に集中するので:
  - XIAO 側の出力に直列抵抗 33Ω を入れて立ち上がりを緩める。
  - サンプルクロックは 27MHz 以下に抑える（6bit CVBS なら 13.5〜18MHz 程度で足りる）。
  - Dock 上側の2つの取付穴（ヘッダの両端）にスペーサーを立て、穴が GND ならそれも GND として使う
    （穴が GND につながっているかは未確認。テスターで確認する）。
- 電源投入順: XIAO だけを USB で給電し Dock が無電源の状態は避ける（FPGA の I/O に電流が回り込む）。直列抵抗が保護にもなる。

## 6. 720p 変換の方式とメモリ

### 方式: 出力を入力フィールドに同期させるラインバッファ型

1. **CVBS デコード**（各XIAOのクロックドメイン）: 同期分離（水平・垂直）→ 必要なら Y/C 分離と色復調（バーストに位相同期）→ YCbCr。
2. **ラインバッファ**に 1ライン 720 サンプル相当で書き込む。
3. **出力**: 1280×720。NTSC は 720p59.94（74.176MHz, 1650×750）。入力1フィールド（240本）を縦3倍で 720本にする。
   4:3 を保つなら横は 960 画素にして左右を黒にし、16:9 に引き伸ばすなら 1280 画素にする（設定で切替）。
4. 出力のフレーム開始を入力フィールドの開始に合わせる（フレームロック）。XIAO と FPGA の水晶のずれは、
   出力の垂直総ライン数を 750±1 で微調整して吸収する。
5. インターレースは各フィールドをそのまま3倍する（bob）。奇数・偶数フィールドで半ラインずらして縦の揺れを抑える。

### この方式を選ぶ理由

- フレームバッファが要らないので **SDRAM なし**で作れる（J3 をドーターに使っても問題ない）。
- 遅延は入力から数ライン〜十数ライン（1ms 未満）。FPV で重要な低遅延になる。
- 720p59.94 は標準のタイミングなので、一般的なモニタで映る。

### 内蔵メモリ（BSRAM 1008Kbit, 56ブロック）の見積もり

出力1ラインは入力1ラインの 3分の1の時間（22.2µs）しかなく、入力ライン（63.6µs）3本ぶん＝66.7µs かけて入力1本を消費する。
1フィールド（240本）で入力より約 12 ライン遅れるので、余裕を見て **32 ライン**持つ。

| 用途 | 計算 | 容量 |
|---|---|---|
| ラインバッファ（YCbCr 4:2:2, 16bit/画素） | 720 × 32 ライン × 16bit | 369 Kbit |
| 2台目の受信用（ダイバーシティ切替） | 同上 | 369 Kbit |
| 合計 | | 738 Kbit（全体の約 73%） |

- 白黒（Y のみ 8bit）なら半分で済む。
- 2台を同時に画面に並べる（2画面表示）場合も、各 640 画素×32 ラインで同程度に収まる。
- フレームバッファ方式（1フィールド丸ごと保存）は 720×240×16bit = 2.7Mbit で入らない。必要になった場合は SDRAM が要る。

### FPGA の規模の目安

- HDMI 720p の TMDS は 742.5Mbps。Sipeed の 25K の HDMI サンプルはこれより高いレートで出しており、問題ない。
- 色復調には乗算器を 1台あたり 6〜10 個使う見込み（GW5A-25 は 18×18 が 28 個）。2台とも色復調するとぎりぎりなので、
  ダイバーシティなら「同期の品質は2台とも測り、色復調は選んだ1台だけ」にする。
- 6bit なので輝度の段階は約 45 段（同期レベルを除く）。暗部の縞は出やすいが、FPV の画質（アナログ受信）の範囲では目立ちにくい。

## 7. 物理配置と干渉チェック

Dock の配置（部品面から見て）:

```
 ┌──────────────── 64 mm ────────────────┐
 │○ [J3 2x20 ヘッダ 1……………………40] ○ │ ← 上辺。ドーターはここに挿す
 │ MODE  LED      [25K コア]     S1 S2     │
 │ USB-A                    BL616  USB-C   │
 │ [Pmod J6]  C  [Pmod J5]  C  [Pmod J4]  │ ← 下辺。直角Pmod、モジュールは外へ突き出す
 └─────────────────────────────────────────┘
          ↓HDMI Pmod（J6 推奨）は下辺から外側へ
```

- 40ピンヘッダは **上辺**、3つの Pmod は **下辺**で、Pmod モジュールは基板の外側に向かって水平に突き出す。
  HDMI Pmod とドーターは基板の反対側の辺にあるので **干渉しない**。
- HDMI Pmod は左端 J6 を推奨（Sipeed の nestang と同じピン。左隣は USB-A だが、モジュールは基板の外に出るので当たらない）。
  J5/J4 に挿しても電気的には同じように使える（ピンは §4 の .cst を差し替える）。
- ドーター基板の形は次の2案。**A 案を推奨**:
  - **A 案（外側に張り出す）**: ドーター下面のメスヘッダを J3 に挿し、基板は Dock の上辺から外側へ約 35mm 張り出す。
    XIAO 2台（各 21×17.8mm）を横に並べ、USB-C とアンテナ用 U.FL を外側の辺に向ける。
    Dock のボタン（S1/S2/MODE）、LED、USB-C を覆わない。Dock 上辺の取付穴2つにスペーサーで固定し、片持ちのたわみを防ぐ。
  - B 案（Dock の上に重ねる）: 64×40mm で Dock の真上に重ねる。標準のピンヘッダ＋メスヘッダで基板間は約 11mm 空き、
    USB-A（高さ約 7mm）や 220µF コンデンサより高いので物理的には収まるが、ボタンと LED が隠れ、XIAO のアンテナが FPGA や USB ケーブルに近くなる。
- 5.8GHz を受けるので、アンテナは HDMI ケーブルと基板から離す。A 案だと HDMI（下辺）とアンテナ（上辺の外側）が Dock を挟んで反対側になり有利。
- 2台の XIAO の間は 3mm 以上空ける（USB-C プラグ同士が当たらないように）。

## 8. 未確定事項

1. **C5VRX のサンプルレート**と、6bit のどのビットがどの GPIO に出ているか（既に決まっていれば §3 の表を合わせる）。色を出すなら 14.3MS/s（NTSC）以上が目安。
2. **2台の使い方**: ダイバーシティ（良いほうを自動選択、既定にしている）か、2画面表示か。
3. 映像方式: NTSC（720p59.94）を既定。PAL なら 720p50 にする（縦は 288→720 で 2.5 倍、補間が必要）。
4. Dock の取付穴が GND につながっているか（テスターで確認）。
5. ストラッピングピン（GPIO25, GPIO7）について、FPGA コンフィグ中のプルアップが XIAO の起動に影響しないかを、スレッド4の実機確認で見る。

## 参考資料

- Sipeed Wiki: Tang Primer 25K — https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html
- Sipeed Wiki: TANG PMOD（SDRAM V1.1 のピン図、PMOD-DVI） — https://wiki.sipeed.com/hardware/en/tang/tang-PMOD/FPGA_PMOD.html
- Dock 回路図 — https://dl.sipeed.com/fileList/TANG/Primer_25K/02_Schematic/Tang_Primer_25K_Dock_60033_Schematic.pdf
- Gowin UG985（GW5A-25 ピン配置） — https://cdn.gowinsemi.com.cn/UG985E.pdf
- LiteX boards: sipeed_tang_primer_25k.py — https://github.com/litex-hub/litex-boards
- Sipeed TangPrimer-25K-example（hdmi / nestang の .cst） — https://github.com/sipeed/TangPrimer-25K-example
- Seeed Wiki: XIAO ESP32-C5 — https://wiki.seeedstudio.com/xiao_esp32c5_getting_started/
- ESP-IDF: ESP32-C5 GPIO（ストラッピングピン） — https://docs.espressif.com/projects/esp-idf/en/stable/esp32c5/api-reference/peripherals/gpio.html
- ESP-IDF: ESP32-C5 Parallel IO TX — https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32c5/api-reference/peripherals/parlio/parlio_tx.html
