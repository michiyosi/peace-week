-- =============================================================================
-- Piece Project P0-1: 投稿レート制限 ＋ 緊急一括削除
-- 作成: 2026-07-16 / 対象: Supabase (Postgres + PostgREST)
--
-- 【これは何を防ぐか】
--   公開キーは仕様上ソースに露出するため、開発者ツールで sbSubmit の fetch を
--   ループさせれば誰でも 810 枠を数十秒で埋め尽くせる。そうなると本物の参加者が
--   1枚も置けなくなり、企画の中核が死ぬ。NGワードフィルタは「こんにちは」810件を
--   止められないため、この穴はNG対策とは別に塞ぐ必要がある。
--
-- 【適用手順】
--   Supabase ダッシュボード → SQL Editor → 新規クエリに全文を貼って Run。
--   STEP 0 だけ先に実行して現状を確認してから、STEP 1 以降を流すのを推奨。
--
-- 【設計方針】
--   - IPは pieces テーブルに入れない。専用テーブル rate_log に隔離し、
--     RLSポリシーを1つも作らないことで anon からは物理的に到達不能にする。
--     （pieces に列を足すと Prefer: return=representation で漏れる経路ができるため）
--   - 一括削除は既存の hide_piece() を内部で呼ぶ。パスワード検証や非表示化の
--     実装詳細に依存しないので、既存の仕様が何であれ整合する。
-- =============================================================================


-- =============================================================================
-- STEP 0: 現状確認（先にこれだけ実行して結果を確認してください）
-- =============================================================================

-- 0-1. pieces の列構成
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'pieces'
 order by ordinal_position;

-- 0-2. pieces に付いている既存トリガー（NGチェックの名前を確認）
select tgname, tgenabled
  from pg_trigger
 where tgrelid = 'public.pieces'::regclass and not tgisinternal;

-- 0-3. hide_piece の定義（引数と戻り値を確認）
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       pg_get_function_result(p.oid) as returns
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname like 'hide_piece%';

-- 0-4. 現在の投稿数
select count(*) as total from public.pieces;


-- =============================================================================
-- STEP 1: レート制限用のログテーブル（IPはここに隔離する）
-- =============================================================================

create table if not exists public.rate_log (
  id         bigserial primary key,
  ip         text        not null,
  idx        int,                          -- どのマスを取ったか（IP単位の一括削除に使う）
  created_at timestamptz not null default now()
);

create index if not exists rate_log_ip_time_idx
  on public.rate_log (ip, created_at desc);

-- RLSを有効にした上で、ポリシーを1つも作らない。
-- これにより anon / authenticated からは SELECT も INSERT も一切できない。
-- 書き込みは下の security definer 関数だけが行う。
alter table public.rate_log enable row level security;

-- 明示的に権限を落としておく（保険）
revoke all on public.rate_log from anon, authenticated;


-- =============================================================================
-- STEP 2: レート制限トリガー
--   同一IPから 10分間に 10件 まで。超過は HTTP 429 で拒否。
--
--   ★閾値を変えるにはここの数字2つだけ変更:
--       c_window = '10 minutes'
--       c_max    = 10
--
--   【なぜ 10分10件か】(2026-07-18 運用条件が確定したため決定)
--     ・会場のWi-Fiを参加者に使わせる予定は「なし」。8/6は屋外モニターの周りに
--       人が集まって見るだけで、投稿はしない。
--     ・8/1〜8/5の収集も「参加者自身のスマホ」＝各自の携帯回線から。
--       運営がタブレットを置いて代理入力する運用ではない。
--     → よって「会場の1回線から全員が投稿」という最悪ケースが存在しない。
--       IPは参加者ごとにばらけるので、制限を安全に効かせられる。
--
--     それでも 3件 ではなく 10件 にしたのは、日本の携帯回線（CGNAT）では
--     複数の利用者が同じグローバルIPを共有することがあるため。会場に行列が
--     できたとき、同じキャリア・同じ基地局の数人が同一IPになる可能性がある。
--     3件だと巻き添えで弾かれる恐れがあるが、10件なら現実的に届かない。
--
--     10件でも防御は十分成立する: 810枠を1IPから埋めるには 13.5時間 かかる。
--     運営が気づいて STEP 3 の一括削除で戻すには余りある時間。
--     完全なボット排除は狙っていない（それはTurnstile+Edge Functionの領分）。
--
--   ※タブレット代理入力や紙からの一括入力を後から始める場合は、その回線が
--     必ず引っかかる。始める前に必ず下の c_allow にそのIPを入れること。
-- =============================================================================

create or replace function public.aa_rate_limit_pieces()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip     text;
  v_recent int;
  -- ▼ 閾値（変えるならこの2つだけ）
  c_window constant interval := interval '10 minutes';
  c_max    constant int      := 10;
  -- ▼ 無制限にする固定IP（運営がタブレット代理入力や紙からの一括入力をする場合、
  --    その回線のグローバルIPをここに入れる。今の運用（各自のスマホ）では空でよい）
  --    例: array['203.0.113.45','198.51.100.7']
  c_allow  constant text[]   := array[]::text[];
begin
  -- PostgREST 経由のリクエストヘッダから接続元IPを取得
  v_ip := split_part(
            coalesce(
              current_setting('request.headers', true)::json ->> 'x-forwarded-for',
              ''),
            ',', 1);
  v_ip := btrim(v_ip);

  -- IPが取れない場合（ローカル実行・Table Editorからの手動投入など）は素通し
  if v_ip = '' or v_ip is null then
    return new;
  end if;

  -- 許可リストは無制限
  if v_ip = any(c_allow) then
    return new;
  end if;

  select count(*) into v_recent
    from public.rate_log
   where ip = v_ip
     and created_at > now() - c_window;

  if v_recent >= c_max then
    -- PostgREST は SQLSTATE 'PTxxx' を HTTP xxx にマップする → 429 が返る
    raise sqlstate 'PT429'
      using message = 'rate_limited',
            detail  = 'Too many submissions from this network. Please wait a moment.';
  end if;

  insert into public.rate_log (ip, idx) values (v_ip, new.idx);
  return new;
end
$$;

-- トリガー名を 'aa_' で始めることで、他のBEFOREトリガー（NGチェック等）より先に走る。
-- レート制限は最も外側の門番であるべきなので、無駄なNG照合の前に弾く。
drop trigger if exists aa_rate_limit_pieces on public.pieces;
create trigger aa_rate_limit_pieces
  before insert on public.pieces
  for each row execute function public.aa_rate_limit_pieces();


-- =============================================================================
-- STEP 3: 緊急一括削除 RPC
--   既存の hide_piece(p_id, p_pass) を内部で呼ぶので、パスワード検証や
--   非表示化の実装がどうなっていても整合する。
--
--   使い方（管理画面のボタンから呼ばれるが、SQL Editorからも直接使える）:
--     -- 直近30分の投稿を全部消す
--     select public.hide_pieces_bulk('管理パスワード', now() - interval '30 minutes', null, null);
--     -- 特定IPの投稿を全部消す
--     select public.hide_pieces_bulk('管理パスワード', null, null, '203.0.113.45');
--     -- 時刻範囲を指定
--     select public.hide_pieces_bulk('管理パスワード', '2026-08-02 14:00+09', '2026-08-02 15:00+09', null);
--
--   引数は全て null 可（null = その条件で絞らない）。
--   ★安全装置: 3つとも null（＝全件削除）は明示的に禁止している。
--     全消しをしたい場合は既存の「↺ リセット」を使うこと。
-- =============================================================================

create or replace function public.hide_pieces_bulk(
  p_pass  text,
  p_since timestamptz default null,
  p_until timestamptz default null,
  p_ip    text        default null
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r  record;
  n  int := 0;
  ok boolean;
begin
  -- 安全装置: 条件が1つも無い＝全件削除は事故なので拒否
  if p_since is null and p_until is null and p_ip is null then
    raise exception 'refusing_unfiltered_bulk_delete';
  end if;

  for r in
    select p.id
      from public.pieces p
     where coalesce(p.hidden, false) = false   -- すでに非表示のものは対象外（戻り値の件数を正確に）
       and (p_since is null or p.created_at >= p_since)
       and (p_until is null or p.created_at <= p_until)
       and (p_ip    is null or exists (
              select 1 from public.rate_log rl
               where rl.ip = p_ip
                 and rl.idx = p.idx
                 and rl.created_at between p.created_at - interval '1 minute'
                                       and p.created_at + interval '1 minute'
           ))
     order by p.id
  loop
    -- 既存の hide_piece に委譲（パスワードが違えば false が返り、何も消えない）
    ok := public.hide_piece(r.id, p_pass);
    if ok then n := n + 1; end if;
  end loop;

  return n;
end
$$;

grant execute on function public.hide_pieces_bulk(text, timestamptz, timestamptz, text)
  to anon, authenticated;


-- =============================================================================
-- STEP 4: 事故調査用ビュー（管理者がSQL Editorから使う。anonからは見えない）
--   「今どのIPが何件投稿しているか」を一望する。荒らしの発見に使う。
-- =============================================================================

create or replace view public.rate_log_summary as
select ip,
       count(*)          as submissions,
       min(created_at)   as first_seen,
       max(created_at)   as last_seen
  from public.rate_log
 group by ip
 order by count(*) desc;

revoke all on public.rate_log_summary from anon, authenticated;


-- =============================================================================
-- STEP 5: 適用後の動作確認
-- =============================================================================

-- 5-1. トリガーが付いたか（aa_rate_limit_pieces が居るはず）
select tgname from pg_trigger
 where tgrelid = 'public.pieces'::regclass and not tgisinternal
 order by tgname;

-- 5-2. rate_log に anon が触れないことの確認（0行＝ポリシー無し＝到達不能）
select count(*) as policies_on_rate_log
  from pg_policies where schemaname = 'public' and tablename = 'rate_log';

-- 5-3. 実地テスト（ブラウザで）
--   サイトを開いて、続けて11回ピースを置いてみる。
--   11回目で「短い時間に何度も投稿はできません」と出て巻き戻れば成功。
--   ※ Table Editor からの手動INSERTはIPが取れないため素通しする（仕様）。

-- 5-4. このテストで入ったピースの掃除
--   select public.hide_pieces_bulk('管理パスワード', now() - interval '1 hour', null, null);
--   ※ここで 0 が返る場合は管理パスワードが違う（hide_piece が false を返している）


-- =============================================================================
-- STEP 6: ★8/1（募集開始）の前に必ず — テスト投稿の掃除
--
--   2026-07-18 時点で pieces に 35件 入っている。中身を確認したところ、
--   「あ」「川辺をのんびり歩いてる」「たのしく仕事してる」など、
--   サイトの入力例そのままの文言が並んでおり、運営のテスト投稿と見られる
--   （7/13に25件と集中。動作確認をした日の跡）。
--
--   これを放置して8/1を迎えると:
--     ・テスト投稿が810分の1として本番の輪に混ざる
--     ・8/6の完成絵を生成するAIの素材に「あ」が入る
--     ・参加者が「みんなの想い」一覧を開くと「あ」が読める
--
--   ★消す前に必ずエクスポートしておくこと（管理画面の ⬇CSV / ⬇JSON）。
--     本物の投稿が混ざっていないか、人の目で確認してから実行する。
-- =============================================================================

-- 6-1. まず中身を全部見る（消す前に必ず確認）
select id, created_at, message, name
  from public.pieces
 order by created_at;

-- 6-2. 日別の件数（テストがいつ入ったかを把握）
select date(created_at) as day, count(*)
  from public.pieces
 group by 1 order by 1;

-- 6-3. 掃除の実行（どちらか選ぶ）
--   (a) 7/31以前を全部消す = 8/1のスタートを完全にまっさらにする【推奨】
--       select public.hide_pieces_bulk('管理パスワード', '2000-01-01', '2026-07-31 23:59:59+09', null);
--
--   (b) 特定の1枚だけ消す
--       select public.hide_piece(<id>, '管理パスワード');
--
--   ※hide_piece は「非表示化」であり物理削除ではないので、間違えても
--     Supabaseのダッシュボードから戻せる。

-- 6-4. 掃除後の確認（0件になっているはず）
--   select count(*) from public.pieces;   -- ※hidden を除く条件は既存のRLS/ビュー定義に従う
--   → サイトを ?v=fresh で開き直して、盤面が空になっていることを目視確認する


-- =============================================================================
-- 補足: これで防げないもの
-- =============================================================================
-- ・IPを変えながらの分散攻撃（モバイル回線のIP変更、VPN、ボットネット）
--   → 本気の攻撃者には Turnstile + Edge Function が必要（P0-1(b)、工数1〜2日）。
--     今回の対策は「好奇心の開発者・バグったスクリプト・単独の悪ふざけ」を止め、
--     本気の攻撃に対しても運営が気づいて対処する時間を作ることが目的。
--
-- ・管理パスワードの総当たり（P1-2）
--   → hide_piece / hide_pieces_bulk に試行回数制限が無い。パスワードが短い単語だと
--     ADMIN_HASH（ソースに露出・ソルト無しSHA-256）からオフラインで割られ得る。
--     来週の対応予定だが、パスワードを長いランダム文字列に変えるだけでも
--     辞書攻撃は事実上無効化できる。今すぐやる価値がある。
