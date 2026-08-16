# 七彩の塔

Supabase(認証・DB・Realtime)を使ったブラウザRPG。単一の `index.html` で完結する。

## 構成

- `index.html` — ゲーム本体(このリポジトリのルートに置くことで、GitHub Pagesがそのまま公開してくれる)
- `supabase/` — データベースのスキーマ・RLSポリシー・RPC関数の定義(SQL)。番号順にSupabaseのSQL Editorで実行する

## デプロイ

GitHub Pages: リポジトリの Settings > Pages > Source を「Deploy from a branch」、ブランチを `main`、フォルダを `/(root)` に設定するだけで公開される。

## 開発メモ

- バックエンドはSupabase(匿名認証 + RLS + RPC)
- ゲーム内の`SUPABASE_URL` / `SUPABASE_ANON_KEY`は`index.html`内に直書きしている(publishable keyなので公開して問題ない設計)
