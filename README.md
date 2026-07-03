# ピースウィーク — Peace Week Hiroshima '26

810のピースで、2045年の広島をつくる。コンセプトデモ（単一HTML / データ送信なし）。

**Live:** https://michiyosi.github.io/peace-week/

## つかいかた

好きな色と2045年へのメッセージをえらんで「ピースを置く」。壁のピースをタップすると、みんなのメッセージが読めます。「8月6日、いっきに組み上げる」で当日の一斉組み上げ演出をプレビューできます。

## 技術メモ (v2.0)

- 単一HTML。外部依存は Google Fonts のみ（Zen Maru Gothic / Yusei Magic）。Canvas2D 描画。
- ジグソー形状: 隣接ピースが必ず噛み合う（辺ごとの符号 + 対称プロファイル）。ノブは「きのこ型」（円弧バルブ）、振幅はセル短辺基準で統一。
- グリッド: 810 の因数ペア（15×54 / 18×45 / 27×30 / 30×27 / 45×18 / 54×15）から画面アスペクト比に最も合う組を自動選択。`?cols=&rows=` 指定時は固定。
- URLパラメータ: `?rm=1`（reduced-motion強制）/ `?seed=N`（初期ピース数）/ `?cols=` `?rows=`
- テストフック: `PW.place(色,msg,名)` / `PW.assemble()` / `PW.reset()` / `PW.fill(n)` / `PW.count()` / `PW.target` / `PW.version`
- 対応: モバイル390px / prefers-reduced-motion / IME変換確定 / キーボード(Esc・focus-visible)

## 更新手順

`index.html` を編集して main にコミットすると、GitHub Pages が自動再ビルドします（数分）。反映確認はキャッシュ回避のため `?v=日付` を付けると確実。初回デプロイが失敗した場合は Actions から Re-run。
