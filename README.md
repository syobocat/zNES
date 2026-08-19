<!--
SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>

SPDX-License-Identifier: MIT-0
-->

# zNES

Claude Codeのお試しがてら作成した、Zig製のNESエミュレータです。

## ビルド

- `zig build`
  デスクトップ版をビルドします。成果物は`zig-out/bin/znes`に生成されます。
- `zig build wasm`
  Web版をビルドします。成果物は`zig-out/web/`以下に生成されます。

## 操作

- 方向キー: 十字キー
- Z: A ボタン
- X: B ボタン
- Enter: START
- 右 Shift: SELECT
- Ctrl+R (Web版ではR): リセット
- Ctrl+Shift+R (Web版ではShift+R): 電源再投入
- Ctrl+Z: ポート2をコントローラとZapperとで切り替える

## エミュレーション精度等

`STATUS.md`を参照ください。

## ライセンス

100% LLM製であり、私(SyoBoN)はいかなる権利も主張しません。MIT-0でご利用いただけます。
