# C5VRX-5 Tang IQ 版ファーム

C5VRX-5（[Twotoz/C5VRX](https://github.com/Twotoz/C5VRX) の `v5/`、2026-10-11 のコミット 6887fb3）に、Tang へ IQ と受信状態を出す変更を足したもの。内容は [`../design/iq_link.md`](../design/iq_link.md) §2〜3。

| ファイル | 内容 |
|---|---|
| `c5vrx5_tang_iq.patch` | ソースの変更（`v5/main` の6ファイル、約100行） |
| `c5vrx5_tang_iq_merged.bin` | ESP-IDF v6.0.2 でビルドした書き込み用イメージ（0x0 に書く。ブートローダ、パーティション表、アプリを1つにまとめたもの） |

## 変更点

- IQ 8本を XIAO の端のピンに移す: Q0〜Q3 = D4〜D7、I0〜I3 = D8, D9, D0, D1。
- 抵抗 DAC の出力は D2, D3 と裏面パッドに移す（使わない）。**このファームではゴーグル用のアナログ出力は出ない。**
- D10 から受信状態のパケットを UART1（2Mbaud）で送る（`tang_link.c`）。ゲインを書いた直後と、2ms ごと。
- それ以外（U85Q、Direct Gain V5、AFC、フィルタの校正、メニュー操作）は C5VRX-5 のまま。

## 書き込み

ブラウザの C5VRX Web Flasher は公式リリースしか書けないので、esptool を使う。

```
python -m esptool --chip esp32c5 write-flash 0x0 c5vrx5_tang_iq_merged.bin
```

ブラウザで書くなら Espressif の ESP Tool（https://espressif.github.io/esptool-js/ ）で、アドレス 0x0 に merged.bin を指定する。
元に戻すときは、C5VRX の Web Flasher で C5VRX-5 を書き直せばよい。

## 自分でビルドする場合

```
git clone https://github.com/Twotoz/C5VRX && cd C5VRX
git checkout 6887fb3
git apply /path/to/c5vrx5_tang_iq.patch
cd v5 && idf.py build          # ESP-IDF v6.0.2（C5VRX の CI と同じ版）
```

## 注意

- ビルドは通ったが、実機ではまだ動かしていない。
- 起動後に `idf.py monitor` で `C5VRX5 ... ready` が出ることをまず確かめる。
