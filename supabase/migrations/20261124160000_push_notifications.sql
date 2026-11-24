-- Push notifications for Puffle (Firebase Cloud Messaging), like Flixvault's:
-- * phones register a token;  * the owner sends messages from admin (now or
--   scheduled) to everyone / ads / organic / Premium / free users;
-- * automation: a new Flixvault video in Puffle's copy is announced to the
--   users allowed to see it, outside quiet hours and up to a daily cap.
-- push_tick runs every minute but is cheap (exists-checks, advisory lock).

create table if not exists public.push_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  updated_at timestamptz not null default now()
);
create index if not exists push_tokens_user_idx on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon, authenticated;

create table if not exists public.push_settings (
  id            int primary key default 1 check (id = 1),
  auto_enabled  boolean not null default false,
  quiet_start   int not null default 23 check (quiet_start between 0 and 23),  -- IST hour
  quiet_end     int not null default 9  check (quiet_end between 0 and 23),
  daily_cap     int not null default 2  check (daily_cap between 0 and 10),
  auto_seen_at  timestamptz not null default now()   -- posts first seen after this are "new"
);
insert into public.push_settings (id) values (1) on conflict do nothing;
alter table public.push_settings enable row level security;
revoke all on public.push_settings from anon, authenticated;

create table if not exists public.push_messages (
  id           uuid primary key default gen_random_uuid(),
  title        text not null check (length(title) between 1 and 80),
  body         text check (length(body) <= 240),
  image        text,
  type         text not null default 'none' check (type in ('none', 'post', 'channel', 'premium', 'url')),
  target       text,
  url          text,
  audience     text not null default 'all' check (audience in ('all', 'ads', 'organic', 'premium', 'free')),
  status       text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'cancelled')),
  scheduled_at timestamptz not null default now(),
  auto         boolean not null default false,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  recipients   int not null default 0,
  sent         int not null default 0,
  failed       int not null default 0,
  opened       int not null default 0
);
create index if not exists push_messages_due_idx on public.push_messages (scheduled_at) where status = 'queued';
create index if not exists push_messages_auto_idx on public.push_messages (created_at) where auto;
alter table public.push_messages enable row level security;
revoke all on public.push_messages from anon, authenticated;

create table if not exists public.push_deliveries (
  id         bigint generated always as identity primary key,
  message_id uuid not null references public.push_messages (id) on delete cascade,
  token      text not null,
  status     text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed')),
  tries      int not null default 0,
  error      text,
  updated_at timestamptz not null default now()
);
create index if not exists push_deliveries_queued_idx on public.push_deliveries (id) where status = 'queued';
create index if not exists push_deliveries_sending_idx on public.push_deliveries (updated_at) where status = 'sending';
create index if not exists push_deliveries_message_idx on public.push_deliveries (message_id);
alter table public.push_deliveries enable row level security;
revoke all on public.push_deliveries from anon, authenticated;

-- New videos in Puffle's copy: when Puffle first saw them.
alter table public.flixvault_posts add column if not exists first_seen_at timestamptz not null default now();
create index if not exists flixvault_posts_first_seen_idx on public.flixvault_posts (first_seen_at desc);

-- ---------------------------------------------------------------------------
-- App side
-- ---------------------------------------------------------------------------
create or replace function public.register_push_token(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or length(coalesce(p_token, '')) not between 20 and 4096 then return; end if;
  insert into public.push_tokens (token, user_id, updated_at) values (p_token, auth.uid(), now())
  on conflict (token) do update set user_id = excluded.user_id, updated_at = now();
end $$;
revoke execute on function public.register_push_token(text) from public, anon;
grant execute on function public.register_push_token(text) to authenticated;

create or replace function public.push_opened(p_mid uuid)
returns void language sql security definer set search_path = '' as $$
  update public.push_messages set opened = opened + 1 where id = p_mid and auth.uid() is not null
$$;
revoke execute on function public.push_opened(uuid) from public, anon;
grant execute on function public.push_opened(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Fan-out and sending (service role / cron only)
-- ---------------------------------------------------------------------------
create or replace function public.push_fanout(p_message uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare
  m public.push_messages; n int;
begin
  select * into m from public.push_messages where id = p_message and status = 'queued' for update;
  if not found then return 0; end if;
  insert into public.push_deliveries (message_id, token)
  select m.id, t.token
    from public.push_tokens t
   where t.updated_at > now() - interval '60 days'
     and case m.audience
           when 'all'     then true
           when 'ads'     then private.has_ads_access(t.user_id)
           when 'organic' then not private.has_ads_access(t.user_id)
           when 'premium' then private.has_plan(t.user_id)
           when 'free'    then not private.has_plan(t.user_id)
         end;
  get diagnostics n = row_count;
  update public.push_messages set status = case when n = 0 then 'sent' else 'sending' end, recipients = n
   where id = m.id;
  return n;
end $$;

create or replace function public.push_claim(p_limit int default 500)
returns table (id bigint, token text, mid text, title text, body text, image text, type text, target text, url text)
language plpgsql security definer set search_path = '' as $$
begin
  -- Anything stuck in "sending" for 10 minutes goes back to the queue.
  update public.push_deliveries d set status = 'queued'
   where d.status = 'sending' and d.updated_at < now() - interval '10 minutes';
  return query
  with c as (
    select d.id from public.push_deliveries d
     where d.status = 'queued' order by d.id limit greatest(1, least(p_limit, 1000))
     for update skip locked)
  update public.push_deliveries d set status = 'sending', tries = d.tries + 1, updated_at = now()
    from c, public.push_messages m
   where d.id = c.id and m.id = d.message_id
  returning d.id, d.token, m.id::text, m.title, coalesce(m.body, ''), m.image, m.type, m.target, m.url;
end $$;

create or replace function public.push_finish(p_results jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  with r as (
    select (x->>'id')::bigint id, coalesce((x->>'ok')::boolean, false) ok,
           coalesce((x->>'retry')::boolean, false) retry,
           coalesce((x->>'unregistered')::boolean, false) unreg, left(x->>'error', 300) err
      from jsonb_array_elements(coalesce(p_results, '[]')) x)
  update public.push_deliveries d
     set status = case when r.ok then 'sent' when r.retry and d.tries < 3 then 'queued' else 'failed' end,
         error = r.err, updated_at = now()
    from r where d.id = r.id;

  -- Tokens of uninstalled apps are removed.
  delete from public.push_tokens t
   using public.push_deliveries d, jsonb_array_elements(coalesce(p_results, '[]')) x
   where (x->>'unregistered')::boolean and d.id = (x->>'id')::bigint and t.token = d.token;

  -- Message totals; finished when nothing is waiting.
  update public.push_messages m
     set sent = s.sent, failed = s.failed,
         status = case when s.open = 0 then 'sent' else m.status end
    from (select d.message_id,
                 count(*) filter (where d.status = 'sent') sent,
                 count(*) filter (where d.status = 'failed') failed,
                 count(*) filter (where d.status in ('queued', 'sending')) open
            from public.push_deliveries d
           where d.message_id in (select dd.message_id from public.push_deliveries dd
                                   join jsonb_array_elements(coalesce(p_results, '[]')) x on dd.id = (x->>'id')::bigint)
           group by d.message_id) s
   where m.id = s.message_id and m.status = 'sending';
end $$;

-- Every minute. Cheap: returns at once when there is nothing to do.
create or replace function public.push_tick()
returns void language plpgsql security definer set search_path = '' as $$
declare
  s public.push_settings; p record; ist_hour int; quiet boolean; today_auto int; v_url text; v_key text; mid uuid;
begin
  if not pg_try_advisory_xact_lock(hashtext('puffle_push_tick')) then return; end if;
  select * into s from public.push_settings where id = 1;

  -- 1) Automation: announce the newest Flixvault video Puffle hasn't announced yet.
  if s.auto_enabled and exists (select 1 from public.flixvault_posts where first_seen_at > s.auto_seen_at and not hidden) then
    ist_hour := extract(hour from now() at time zone 'Asia/Kolkata');
    quiet := case when s.quiet_start = s.quiet_end then false
                  when s.quiet_start < s.quiet_end then ist_hour >= s.quiet_start and ist_hour < s.quiet_end
                  else ist_hour >= s.quiet_start or ist_hour < s.quiet_end end;
    select count(*) into today_auto from public.push_messages
     where auto and created_at >= date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
    if not quiet and today_auto < s.daily_cap then
      select fp.id, fp.title, fp.audience, c.name channel,
             (select i.thumb_url from public.flixvault_items i where i.post_id = fp.id order by i.position limit 1) thumb
        into p
        from public.flixvault_posts fp join public.flixvault_channels c on c.id = fp.channel_id
       where fp.first_seen_at > s.auto_seen_at and not fp.hidden and not c.hidden
       order by fp.published_at desc limit 1;
      if found then
        insert into public.push_messages (title, body, image, type, target, audience, auto)
        values (left('New: ' || p.title, 80), left('Watch now on ' || p.channel, 240), p.thumb, 'post', p.id::text, p.audience, true);
      end if;
      update public.push_settings set auto_seen_at = now() where id = 1;
    end if;
  end if;

  -- 2) Due messages -> deliveries.
  for mid in select id from public.push_messages where status = 'queued' and scheduled_at <= now() order by scheduled_at limit 5 loop
    perform public.push_fanout(mid);
  end loop;

  -- 3) Wake the sender only when something is waiting.
  if exists (select 1 from public.push_deliveries where status = 'queued') then
    select url, key into v_url, v_key from private.meta_cron where id = 1 and url like '%/meta-send';
    if v_url is not null then
      perform net.http_post(url := replace(v_url, '/meta-send', '/push-send'),
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', v_key),
        body := '{}'::jsonb, timeout_milliseconds := 55000);
    end if;
  end if;
end $$;

revoke execute on function public.push_fanout(uuid), public.push_claim(int), public.push_finish(jsonb), public.push_tick()
  from public, anon, authenticated;
grant execute on function public.push_claim(int), public.push_finish(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Admin (owner only)
-- ---------------------------------------------------------------------------
create or replace function public.admin_push_create(
  p_title text, p_body text, p_image text, p_type text, p_target text, p_url text,
  p_audience text, p_scheduled_at timestamptz default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  insert into public.push_messages (title, body, image, type, target, url, audience, scheduled_at, created_by)
  values (btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), nullif(btrim(coalesce(p_image, '')), ''),
          coalesce(nullif(p_type, ''), 'none'), nullif(btrim(coalesce(p_target, '')), ''),
          nullif(btrim(coalesce(p_url, '')), ''), coalesce(nullif(p_audience, ''), 'all'),
          coalesce(p_scheduled_at, now()), auth.uid())
  returning id into v;
  return v;
end $$;

create or replace function public.admin_push_cancel(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  update public.push_messages set status = 'cancelled' where id = p_id and status = 'queued';
end $$;

create or replace function public.admin_push_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) - 'id' from public.push_settings s where id = 1),
    'phones', (select count(*) from public.push_tokens where updated_at > now() - interval '60 days'),
    'users', (select count(distinct user_id) from public.push_tokens where updated_at > now() - interval '60 days'),
    'messages', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at desc)
                  from (select id, title, body, type, target, url, audience, status, scheduled_at, auto,
                               created_at, recipients, sent, failed, opened
                          from public.push_messages order by created_at desc limit 50) m), '[]'::jsonb));
end $$;

create or replace function public.admin_push_settings_save(p_auto boolean, p_quiet_start int, p_quiet_end int, p_daily_cap int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  update public.push_settings
     set auto_enabled = p_auto, quiet_start = p_quiet_start, quiet_end = p_quiet_end, daily_cap = p_daily_cap,
         -- turning automation on never announces old videos
         auto_seen_at = case when p_auto and not auto_enabled then now() else auto_seen_at end
   where id = 1;
end $$;

revoke execute on function public.admin_push_create(text, text, text, text, text, text, text, timestamptz),
  public.admin_push_cancel(uuid), public.admin_push_overview(), public.admin_push_settings_save(boolean, int, int, int)
  from public, anon;
grant execute on function public.admin_push_create(text, text, text, text, text, text, text, timestamptz),
  public.admin_push_cancel(uuid), public.admin_push_overview(), public.admin_push_settings_save(boolean, int, int, int)
  to authenticated;

select cron.unschedule('push-tick') where exists (select 1 from cron.job where jobname = 'push-tick');
select cron.schedule('push-tick', '* * * * *', $cron$ select public.push_tick(); $cron$);
