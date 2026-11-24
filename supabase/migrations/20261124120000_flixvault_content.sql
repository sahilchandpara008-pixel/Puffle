-- Puffle shows Flixvault's videos (loaded through the flixvault-feed edge
-- function). Flixvault channels/posts are not stored here; Puffle only keeps
-- what belongs to its own users: which Flixvault channels they follow, which
-- they blocked, and their reports. Everything else in Puffle is unchanged.

create table if not exists public.flixvault_follows (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  channel_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, channel_id)
);

create table if not exists public.flixvault_blocks (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  channel_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, channel_id)
);

create table if not exists public.flixvault_reports (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  post_id    uuid not null,
  reason     text not null check (length(reason) between 1 and 80),
  created_at timestamptz not null default now()
);
create index if not exists flixvault_reports_time_idx on public.flixvault_reports (created_at desc);

alter table public.flixvault_follows enable row level security;
alter table public.flixvault_blocks  enable row level security;
alter table public.flixvault_reports enable row level security;

drop policy if exists flixvault_follows_own on public.flixvault_follows;
create policy flixvault_follows_own on public.flixvault_follows
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists flixvault_blocks_own on public.flixvault_blocks;
create policy flixvault_blocks_own on public.flixvault_blocks
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists flixvault_reports_insert on public.flixvault_reports;
create policy flixvault_reports_insert on public.flixvault_reports
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists flixvault_reports_admin on public.flixvault_reports;
create policy flixvault_reports_admin on public.flixvault_reports
  for select to authenticated using (public.is_admin());

revoke all on public.flixvault_follows, public.flixvault_blocks, public.flixvault_reports from anon;
grant select, insert, update, delete on public.flixvault_follows, public.flixvault_blocks to authenticated;
grant select, insert on public.flixvault_reports to authenticated;
