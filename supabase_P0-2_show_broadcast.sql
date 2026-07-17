-- =============================================================================
-- Piece Project P0-2: お披露目の同時配信（show_state）
-- 作成: 2026-07-18 / 対象: Supabase (Postgres + PostgREST)
--
-- 【なぜ必要か】
--   8/6のプレスリリース: 「会場に来られない方も、このサイト上で同じ絵をリアルタイムで
--   ご覧いただけます」「オンラインでも同時公開」
--   ところが現状の assemble() は「押した端末の中だけ」で完結し、サーバ側に
--   「お披露目した」という状態が存在しない。つまり運営PCで再生しても、
--   メルパルク前の広場でスマホを見ている人にも、家で見ている人にも、何も起きない。
--   これは「あったら良い機能」ではなく、告知した内容を成立させる前提条件。
--
-- 【設計: なぜ「合図」ではなく「時刻」を配るのか】
--   素朴に phase='revealed' を配ってポーリングで拾うと、各端末は
--   最大でポーリング間隔ぶん(数秒)バラバラに光る。大画面より先にスマホが光る、
--   隣の人と数秒ズレる、という状態は演出として台無しになる。
--
--   そこで「今から始めろ」ではなく「◯時◯分◯秒に始めろ」という未来時刻を配る。
--   各端末はそれを受け取ったら、自分のローカル時計との差を補正して、
--   その瞬間ちょうどに再生する。ポーリングが3秒間隔でも、実際の発火は1秒以内で揃う。
--
--   時計のズレは、クライアントがHTTPの Date ヘッダから推定する（±0.5秒精度）。
--   端末の時計が何分もズレていても、サーバ時刻を基準に揃うので問題ない。
--
-- 【適用手順】
--   Supabase ダッシュボード → SQL Editor → 貼って Run。
--   ※ supabase_P0-1_rate_limit_and_bulk_hide.sql（admin_secret / hide_piece）が
--     適用済みであることが前提。
-- =============================================================================


-- =============================================================================
-- STEP 1: 演出の状態を持つテーブル（1行だけ）
-- =============================================================================

create table if not exists public.show_state (
  id         int primary key default 1,
  phase      text        not null default 'waiting',   -- waiting | armed | revealed
  reveal_at  timestamptz,                              -- armed のとき、この時刻ちょうどに全員が再生
  note       text,                                     -- 運営メモ（任意）
  updated_at timestamptz not null default now(),
  constraint show_state_single_row check (id = 1),
  constraint show_state_phase_ok   check (phase in ('waiting','armed','revealed'))
);

insert into public.show_state (id, phase) values (1, 'waiting')
  on conflict (id) do nothing;

alter table public.show_state enable row level security;

-- 誰でも読める（これを全端末がポーリングする）。書き込みは誰にも許可しない。
drop policy if exists show_state_public_read on public.show_state;
create policy show_state_public_read
  on public.show_state for select
  to anon, authenticated
  using (true);


-- =============================================================================
-- STEP 2: 運営だけが状態を変えられるRPC
--   パスワード照合は既存の hide_piece と同じ admin_secret を使う。
--   ※2026-07-18 実機確認: hide_piece の中身は
--       if not exists (select 1 from admin_secret where value = p_pass) then return false;
--     照合列は `secret` ではなく **`value`**。ここも同じ列名で揃えてある。
--
--   使い方:
--     -- 8秒後に全員でお披露目（本番はこれ）
--     select public.set_show_state('管理パスワード', 'armed', 8);
--     -- 待機状態に戻す（リハの繰り返し用）
--     select public.set_show_state('管理パスワード', 'waiting', 0);
--     -- 既に終わった扱いにする（遅れて開いた人にも完成絵を見せる）
--     select public.set_show_state('管理パスワード', 'revealed', 0);
-- =============================================================================

create or replace function public.set_show_state(
  p_pass  text,
  p_phase text,
  p_delay_seconds int default 8
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok   boolean := false;
  v_at   timestamptz;
  v_note text;
begin
  -- パスワード照合（既存 hide_piece と同一: admin_secret.value と突き合わせ）
  select exists (select 1 from public.admin_secret where value = p_pass) into v_ok;
  if not v_ok then
    return json_build_object('ok', false, 'error', 'bad_password');
  end if;

  if p_phase not in ('waiting','armed','revealed') then
    return json_build_object('ok', false, 'error', 'bad_phase');
  end if;

  -- armed のときだけ、未来の発火時刻を決める
  if p_phase = 'armed' then
    v_at := now() + make_interval(secs => greatest(coalesce(p_delay_seconds, 8), 3));
    v_note := 'armed at ' || now()::text;
  else
    v_at := null;
    v_note := p_phase || ' at ' || now()::text;
  end if;

  update public.show_state
     set phase = p_phase,
         reveal_at = v_at,
         note = v_note,
         updated_at = now()
   where id = 1;

  return json_build_object(
    'ok', true,
    'phase', p_phase,
    'reveal_at', v_at,
    'server_now', now()
  );
end
$$;

grant execute on function public.set_show_state(text, text, int) to anon, authenticated;


-- =============================================================================
-- STEP 3: 確認
-- =============================================================================

-- 3-1. 現在の状態（誰でも読める。これをサイトがポーリングする）
select * from public.show_state;

-- 3-2. 匿名から直接UPDATEできないことの確認
--   → サイト側から fetch で PATCH してみて 401/403 が返れば正しい

-- 3-3. リハの手順
--   1) select public.set_show_state('管理パスワード', 'waiting', 0);   -- 待機に戻す
--   2) サイトを2つの端末（PCとスマホ）で開く
--   3) select public.set_show_state('管理パスワード', 'armed', 8);     -- 8秒後に発火
--   4) 両方の画面が「同じ瞬間」に光れば成功
--   5) select public.set_show_state('管理パスワード', 'waiting', 0);   -- 片付け


-- =============================================================================
-- 補足: 8/6当日の運用
-- =============================================================================
-- ・ゆきなさん・そらさんのトークが終わる → 運営が管理画面の「▶ お披露目（全員に配信）」
--   を押す → 8秒後に、会場の投影も、広場のスマホも、家のPCも、同時に光る。
--
-- ・8秒の猶予は「押してから全端末に伝わるまでの余裕」。長すぎると間延びし、
--   短すぎるとポーリングが間に合わない端末が出る。3秒が下限（RPC側で強制）。
--
-- ・遅れて開いた人には phase='revealed' が伝わり、演出なしで完成絵が出る。
--   「来たときにはもう終わっていた」ではなく「完成した絵が見られる」状態になる。
--
-- ・当日ネットが死んだ場合は、この配信も止まる。会場の投影は
--   ?rehearsal=1（またはUSBのローカルHTML）に切り替えれば単独で再生できる。
--   オンライン視聴者は救えないが、会場だけは必ず成立する。
