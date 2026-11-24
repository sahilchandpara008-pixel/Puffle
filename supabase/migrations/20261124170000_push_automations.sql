-- Automatic notifications for Puffle, like Flixvault's:
--   welcome, daily messages (fixed IST hours, rotating), come back,
--   payment reminder, payment failed, Premium active, Premium ending, Premium ended.
-- Messages go to ONE user (target_user); videos are picked per user with the
-- same ads/organic rules as the app. Admins never get automatic messages.
-- Marketing kinds respect quiet hours and a 2-hour gap; payment kinds don't.
-- Runs inside push_tick every 5 minutes (cheap; dedupe keys stop repeats).

alter table public.push_messages add column if not exists kind text not null default 'manual';
alter table public.push_messages add column if not exists target_user uuid;
alter table public.push_messages add column if not exists ref_post uuid;
alter table public.push_messages add column if not exists dedupe_key text;
create unique index if not exists push_messages_dedupe_idx on public.push_messages (dedupe_key) where dedupe_key is not null;
create index if not exists push_messages_user_idx on public.push_messages (target_user, created_at desc) where target_user is not null;
update public.push_messages set kind = 'new_videos' where auto and kind = 'manual';

alter table public.push_tokens add column if not exists created_at timestamptz not null default now();

create table if not exists public.push_auto (
  kind       text primary key,
  enabled    boolean not null default true,
  title      text not null,
  body       text not null default '',
  title2     text,
  body2      text,
  delay1     int,     -- hours (welcome, reminder) / days (come back)
  delay2     int,     -- second step: hours (reminder) / days (come back, ended, daily window)
  enabled_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.push_auto enable row level security;
revoke all on public.push_auto from anon, authenticated;

insert into public.push_auto (kind, title, body, title2, body2, delay1, delay2) values
  ('welcome', 'Start with today''s most watched 🔥', '{title} · {channel}', null, null, 3, null),
  ('daily', 'Daily messages', '', null, null, null, 14),
  ('come_back', 'New since your last visit', '{title} and {more} more videos are waiting.',
     'You''re missing out 👀', '{count} new videos since your last visit. Start with {title}.', 5, 14),
  ('payment_reminder', 'Your {plan} is waiting', '₹{price} for {duration} of full videos & 2 TB cloud. Tap to finish.',
     'Still want {plan}? ⏳', '₹{price} for {duration} of full videos & 2 TB cloud. It takes 10 seconds.', 1, 24),
  ('payment_failed', 'Payment didn''t go through ❌', '₹{price} for {plan} wasn''t charged. Try again or pick another UPI app.', null, null, null, null),
  ('payment_approved', 'Your {plan} is active ✅', 'Enjoy full videos & 2 TB cloud. Valid till {end_date}.', null, null, null, null),
  ('plan_ending', 'Your Premium ends tomorrow', 'Renew to keep full videos & 2 TB cloud.', null, null, null, null),
  ('plan_ended', 'Your {plan} has ended', 'Renew now to get full videos & 2 TB cloud back.',
     'We miss you on {plan} 💛', 'Come back to full videos & 2 TB cloud from ₹{from_price}.', null, 3)
on conflict (kind) do nothing;

create table if not exists public.push_daily_msgs (
  pos     int primary key,
  source  text not null check (source in ('trending', 'newest', 'premium', 'channel', 'plan')),
  title   text not null,
  body    text not null default '',
  enabled boolean not null default true
);
alter table public.push_daily_msgs enable row level security;
revoke all on public.push_daily_msgs from anon, authenticated;
insert into public.push_daily_msgs (pos, source, title, body) values
  (1, 'trending', '🔥 #1 today: {title}', '{views} views on {channel}. Don''t miss it.'),
  (2, 'plan', 'Unlock full videos today 🔓', 'Premium Trial: {trial_duration} for just ₹{trial_price}.'),
  (3, 'newest', '🆕 Just added: {title}', 'New in {channel}. Be the first to watch it.'),
  (4, 'plan', 'Full videos + 2 TB cloud ⚡', 'Premium plans from ₹{from_price}.'),
  (5, 'premium', '🔒 Unlock {title}', 'Watch the full video with Premium. Start with {trial_duration} for ₹{trial_price}.'),
  (6, 'plan', 'Best value: {best_plan} 💎', '₹{best_price} for {best_duration}. One-time UPI payment, no auto-renewal.'),
  (7, 'channel', '📺 {count} videos in {channel}', 'Including {title}. Tap to binge.')
on conflict (pos) do nothing;

alter table public.push_settings add column if not exists daily_hours int[] not null default '{9,14,19,0}';
-- Same quiet hours as Flixvault (03:00–09:00 IST).
update public.push_settings set quiet_start = 3, quiet_end = 9 where id = 1 and quiet_start = 23 and quiet_end = 9;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.push_render(p_text text, p_vars jsonb)
returns text language plpgsql immutable set search_path = '' as $$
declare k text; v text; r text := coalesce(p_text, '');
begin
  for k, v in select * from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    r := replace(r, '{' || k || '}', coalesce(v, ''));
  end loop;
  return regexp_replace(r, '\{[a-z_]+\}', '', 'g');
end $$;

create or replace function private.push_duration(p_days int, p_hours int default 0)
returns text language sql immutable set search_path = '' as $$
  select case
    when coalesce(p_hours, 0) > 0 and coalesce(p_days, 0) = 0 then p_hours || case when p_hours = 1 then ' hour' else ' hours' end
    when p_days = 365 then '1 year'
    when p_days % 30 = 0 and p_days >= 30 then (p_days / 30) || case when p_days = 30 then ' month' else ' months' end
    when p_days % 7 = 0 and p_days >= 7 then (p_days / 7) || case when p_days = 7 then ' week' else ' weeks' end
    else p_days || case when p_days = 1 then ' day' else ' days' end end
$$;

-- Can this user see plans (app_mode rules)?
create or replace function private.push_plans_ok(p_ads boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select not free_mode and (plans_visible_for = 'everyone'
            or (plans_visible_for = 'ads' and p_ads) or (plans_visible_for = 'organic' and not p_ads))
         from public.app_mode where id = 1), false)
$$;

-- A video this user may see (same rules as the app), not sent to them in 7 days.
create or replace function private.push_pick(p_uid uuid, p_ads boolean, p_source text)
returns table (post_id uuid, title text, channel text, channel_id uuid, thumb text, views bigint, n_channel bigint)
language sql stable security definer set search_path = '' as $$
  with vis as (
    select p.*, c.name cname
      from public.flixvault_posts p join public.flixvault_channels c on c.id = p.channel_id
     where not p.hidden and not c.hidden
       and p.audience in ('all', case when p_ads then 'ads' else 'organic' end)
       and c.audience in ('all', case when p_ads then 'ads' else 'organic' end)
       and not exists (select 1 from public.push_messages m
                        where m.target_user = p_uid and m.ref_post = p.id and m.created_at > now() - interval '7 days')),
  pick as (
    select v.* from vis v
     where p_source <> 'premium' or exists (select 1 from public.flixvault_items i where i.post_id = v.id and i.is_premium)
     order by case p_source when 'newest' then extract(epoch from v.published_at) else v.view_count::float8 end desc nulls last,
              case when p_source = 'channel' then random() else 0 end
     limit 1)
  select k.id, k.title, k.cname, k.channel_id,
         (select i.thumb_url from public.flixvault_items i where i.post_id = k.id order by i.position limit 1),
         k.view_count,
         (select count(*) from vis v2 where v2.channel_id = k.channel_id)
    from pick k
$$;

create or replace function private.push_user_msg(p_kind text, p_uid uuid, p_title text, p_body text, p_vars jsonb,
  p_type text, p_target text, p_image text, p_ref uuid, p_key text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  insert into public.push_messages (kind, auto, target_user, title, body, image, type, target, ref_post, dedupe_key, audience)
  values (p_kind, true, p_uid,
          left(coalesce(nullif(btrim(private.push_render(p_title, p_vars)), ''), 'Puffle'), 80),
          nullif(left(btrim(private.push_render(p_body, p_vars)), 240), ''),
          p_image, coalesce(p_type, 'none'), p_target, p_ref, p_key, 'all')
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
  return found;
end $$;

-- ---------------------------------------------------------------------------
-- The automations
-- ---------------------------------------------------------------------------
create or replace function private.push_automations()
returns int language plpgsql security definer set search_path = '' as $$
declare
  s public.push_settings; a public.push_auto; u record; o record; v record; m public.push_daily_msgs;
  v_ist timestamp := now() at time zone 'Asia/Kolkata'; v_hour int; quiet boolean; n int := 0;
  plans jsonb; vars jsonb; list public.push_daily_msgs[]; cnt int; i int; k int; plans_ok boolean;
  vp uuid; vt text; vc text; vcid uuid; vth text; vv bigint; vn bigint;
begin
  select * into s from public.push_settings where id = 1;
  v_hour := extract(hour from v_ist)::int;
  quiet := case when s.quiet_start = s.quiet_end then false
                when s.quiet_start < s.quiet_end then v_hour >= s.quiet_start and v_hour < s.quiet_end
                else v_hour >= s.quiet_start or v_hour < s.quiet_end end;

  select jsonb_build_object(
    'trial_price', (select price_inr from public.plans where active order by price_inr limit 1),
    'trial_duration', (select private.push_duration(duration_days, duration_hours) from public.plans where active order by price_inr limit 1),
    'from_price', (select min(price_inr) from public.plans where active),
    'best_plan', (select name from public.plans where active order by duration_days desc, price_inr desc limit 1),
    'best_price', (select price_inr from public.plans where active order by duration_days desc, price_inr desc limit 1),
    'best_duration', (select private.push_duration(duration_days, duration_hours) from public.plans where active
                       order by duration_days desc, price_inr desc limit 1))
    into plans;

  -- ---- Payment kinds (any time) ------------------------------------------
  select * into a from public.push_auto where kind = 'payment_approved';
  if a.enabled then
    for o in select sb.id, sb.user_id, sb.plan_name, sb.ends_at from public.subscriptions sb
              where sb.kind = 'payment' and not sb.revoked and sb.created_at > greatest(now() - interval '1 hour', a.enabled_at)
                and exists (select 1 from public.push_tokens t where t.user_id = sb.user_id) loop
      if private.push_user_msg('payment_approved', o.user_id, a.title, a.body,
           jsonb_build_object('plan', coalesce(o.plan_name, 'Premium'),
                              'end_date', to_char(o.ends_at at time zone 'Asia/Kolkata', 'DD Mon YYYY')),
           'none', null, null, null, 'pa:' || o.id) then n := n + 1; end if;
    end loop;
  end if;

  select * into a from public.push_auto where kind = 'payment_failed';
  if a.enabled then
    for o in select po.id, po.user_id, po.plan_name, po.amount_paise from public.payment_orders po
              where po.status = 'failed' and po.updated_at > greatest(now() - interval '1 hour', a.enabled_at)
                and not private.has_plan(po.user_id)
                and exists (select 1 from public.push_tokens t where t.user_id = po.user_id) loop
      if private.push_user_msg('payment_failed', o.user_id, a.title, a.body,
           jsonb_build_object('plan', coalesce(o.plan_name, 'Premium'), 'price', o.amount_paise / 100),
           'premium', null, null, null, 'pf:' || o.id) then n := n + 1; end if;
    end loop;
  end if;

  select * into a from public.push_auto where kind = 'plan_ending';
  if a.enabled and not quiet then
    for o in select sb.id, sb.user_id, sb.plan_name from public.subscriptions sb
              where not sb.revoked and sb.ends_at between now() + interval '1 hour' and now() + interval '24 hours'
                and not exists (select 1 from public.subscriptions x where x.user_id = sb.user_id and not x.revoked
                                 and x.ends_at > sb.ends_at + interval '1 hour')
                and exists (select 1 from public.push_tokens t where t.user_id = sb.user_id) loop
      if private.push_user_msg('plan_ending', o.user_id, a.title, a.body,
           jsonb_build_object('plan', coalesce(o.plan_name, 'Premium')), 'premium', null, null, null, 'pe:' || o.id)
      then n := n + 1; end if;
    end loop;
  end if;

  -- ---- Marketing kinds (quiet hours, 2-hour gap, never admins / Premium) --
  if quiet then return n; end if;

  for u in
    select t.user_id uid, min(t.created_at) first_token, au.created_at signed_up,
           private.has_ads_access(t.user_id) ads, private.has_plan(t.user_id) premium,
           greatest(max(t.updated_at), (select max(greatest(se.updated_at, se.refreshed_at::timestamptz))
                                          from auth.sessions se where se.user_id = t.user_id)) last_active
      from public.push_tokens t join auth.users au on au.id = t.user_id
     where t.updated_at > now() - interval '60 days'
       and not exists (select 1 from public.admins ad where ad.user_id = t.user_id)
       and not exists (select 1 from public.push_messages pm where pm.target_user = t.user_id and pm.auto
                        and pm.kind not in ('payment_approved', 'payment_failed') and pm.created_at > now() - interval '2 hours')
     group by t.user_id, au.created_at
  loop
    plans_ok := private.push_plans_ok(u.ads);

    -- Premium ended (step 1 the same day, step 2 after delay2 days)
    select * into a from public.push_auto where kind = 'plan_ended';
    if a.enabled and not u.premium and plans_ok then
      select sb.id, sb.plan_name, sb.ends_at into o from public.subscriptions sb
       where sb.user_id = u.uid and not sb.revoked and sb.ends_at < now() and sb.ends_at > now() - interval '30 days'
       order by sb.ends_at desc limit 1;
      if found then
        if o.ends_at > now() - interval '24 hours' and o.ends_at > a.enabled_at then
          if private.push_user_msg('plan_ended', u.uid, a.title, a.body, plans || jsonb_build_object('plan', coalesce(o.plan_name, 'Premium')),
               'premium', null, null, null, 'pd1:' || o.id) then n := n + 1; continue; end if;
        elsif o.ends_at between now() - make_interval(days => coalesce(a.delay2, 3)) - interval '24 hours'
                            and now() - make_interval(days => coalesce(a.delay2, 3)) then
          if private.push_user_msg('plan_ended', u.uid, coalesce(a.title2, a.title), coalesce(a.body2, a.body),
               plans || jsonb_build_object('plan', coalesce(o.plan_name, 'Premium')), 'premium', null, null, null, 'pd2:' || o.id)
          then n := n + 1; continue; end if;
        end if;
      end if;
    end if;

    -- Payment reminder: the newest unfinished order, 1 h and 24 h later.
    select * into a from public.push_auto where kind = 'payment_reminder';
    if a.enabled and not u.premium and plans_ok then
      select po.id, po.plan_name, po.amount_paise, po.duration_days, po.duration_hours, po.created_at into o
        from public.payment_orders po where po.user_id = u.uid order by po.created_at desc limit 1;
      if found and exists (select 1 from public.payment_orders po where po.id = o.id and po.status in ('pending', 'cancelled'))
         and o.created_at > a.enabled_at - interval '2 days' then
        vars := jsonb_build_object('plan', coalesce(o.plan_name, 'Premium'), 'price', o.amount_paise / 100,
                                   'duration', private.push_duration(o.duration_days, o.duration_hours));
        if o.created_at between now() - make_interval(hours => coalesce(a.delay1, 1)) - interval '6 hours'
                            and now() - make_interval(hours => coalesce(a.delay1, 1)) then
          if private.push_user_msg('payment_reminder', u.uid, a.title, a.body, vars, 'premium', null, null, null, 'pr1:' || o.id)
          then n := n + 1; continue; end if;
        elsif o.created_at between now() - make_interval(hours => coalesce(a.delay2, 24)) - interval '24 hours'
                               and now() - make_interval(hours => coalesce(a.delay2, 24)) then
          if private.push_user_msg('payment_reminder', u.uid, coalesce(a.title2, a.title), coalesce(a.body2, a.body), vars,
               'premium', null, null, null, 'pr2:' || o.id) then n := n + 1; continue; end if;
        end if;
      end if;
    end if;

    -- Welcome: a few hours after the phone first registered.
    select * into a from public.push_auto where kind = 'welcome';
    if a.enabled and u.first_token >= a.enabled_at - interval '1 minute'
       and u.first_token < now() - make_interval(hours => coalesce(a.delay1, 3))
       and u.first_token > now() - interval '3 days'
       and not exists (select 1 from public.push_messages pm where pm.target_user = u.uid and pm.kind = 'welcome') then
      select * into v from private.push_pick(u.uid, u.ads, 'trending');
      if v.post_id is not null and private.push_user_msg('welcome', u.uid, a.title, a.body,
           jsonb_build_object('title', v.title, 'channel', v.channel), 'post', v.post_id::text, v.thumb, v.post_id, 'wl:' || u.uid)
      then n := n + 1; continue; end if;
    end if;

    -- Come back: inactive delay1 days (step 1) / delay2 days (step 2).
    select * into a from public.push_auto where kind = 'come_back';
    if a.enabled and u.last_active is not null and u.last_active < now() - make_interval(days => coalesce(a.delay1, 5))
       and u.last_active > now() - interval '45 days' then
      select count(*) cnt,
             (array_agg(p.id order by p.published_at desc))[1] pid
        into o
        from public.flixvault_posts p join public.flixvault_channels c on c.id = p.channel_id
       where not p.hidden and not c.hidden and p.published_at > u.last_active
         and p.audience in ('all', case when u.ads then 'ads' else 'organic' end)
         and c.audience in ('all', case when u.ads then 'ads' else 'organic' end);
      if o.cnt >= 2 then
        select p.title, (select i.thumb_url from public.flixvault_items i where i.post_id = p.id order by i.position limit 1) thumb
          into v from public.flixvault_posts p where p.id = o.pid;
        vars := jsonb_build_object('title', v.title, 'count', o.cnt, 'more', o.cnt - 1);
        if u.last_active < now() - make_interval(days => coalesce(a.delay2, 14)) then
          if private.push_user_msg('come_back', u.uid, coalesce(a.title2, a.title), coalesce(a.body2, a.body), vars,
               'post', o.pid::text, v.thumb, o.pid, 'cb2:' || u.uid || ':' || (u.last_active at time zone 'Asia/Kolkata')::date)
          then n := n + 1; continue; end if;
        elsif private.push_user_msg('come_back', u.uid, a.title, a.body, vars,
               'post', o.pid::text, v.thumb, o.pid, 'cb1:' || u.uid || ':' || (u.last_active at time zone 'Asia/Kolkata')::date)
        then n := n + 1; continue; end if;
      end if;
    end if;

    -- Daily messages: free users in their first delay2 days, at the chosen IST hours.
    select * into a from public.push_auto where kind = 'daily';
    if a.enabled and not u.premium and v_hour = any (s.daily_hours)
       and u.signed_up > now() - make_interval(days => coalesce(a.delay2, 14))
       and not exists (select 1 from public.push_messages pm
                        where pm.dedupe_key = 'dy:' || u.uid || ':' || to_char(v_ist, 'YYYY-MM-DD-HH24')) then
      select array_agg(x order by x.pos) into list from public.push_daily_msgs x
       where x.enabled and (x.source not in ('plan', 'premium') or plans_ok);
      cnt := coalesce(array_length(list, 1), 0);
      if cnt > 0 then
        i := (select count(*) from public.push_messages pm where pm.target_user = u.uid and pm.kind = 'daily')::int;
        for k in 0 .. cnt - 1 loop
          m := list[((i + k) % cnt) + 1];
          vp := null; vt := null; vc := null; vcid := null; vth := null; vv := 0; vn := 0;
          exit when m.source = 'plan';
          select x.post_id, x.title, x.channel, x.channel_id, x.thumb, x.views, x.n_channel
            into vp, vt, vc, vcid, vth, vv, vn from private.push_pick(u.uid, u.ads, m.source) x;
          exit when vp is not null;
          m := null;
        end loop;
        if m.pos is not null then
          vars := plans || case when vp is null then '{}'::jsonb else jsonb_build_object(
                    'title', vt, 'channel', vc, 'views', coalesce(vv, 0), 'count', coalesce(vn, 0)) end;
          if m.source = 'trending' and coalesce(vv, 0) < 20 then
            m.body := 'Today''s most watched on Puffle. Don''t miss it.';
          end if;
          if private.push_user_msg('daily', u.uid, m.title, m.body, vars,
               case m.source when 'plan' then 'premium' when 'channel' then 'channel' else 'post' end,
               case m.source when 'plan' then null when 'channel' then vcid::text else vp::text end,
               vth, vp, 'dy:' || u.uid || ':' || to_char(v_ist, 'YYYY-MM-DD-HH24'))
          then n := n + 1; end if;
        end if;
      end if;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function private.push_render(text, jsonb), private.push_duration(int, int), private.push_plans_ok(boolean),
  private.push_pick(uuid, boolean, text),
  private.push_user_msg(text, uuid, text, text, jsonb, text, text, text, uuid, text), private.push_automations()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fan-out: a message for one user goes only to that user's phones.
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
     and case when m.target_user is not null then t.user_id = m.target_user
         else case m.audience
           when 'all'     then true
           when 'ads'     then private.has_ads_access(t.user_id)
           when 'organic' then not private.has_ads_access(t.user_id)
           when 'premium' then private.has_plan(t.user_id)
           when 'free'    then not private.has_plan(t.user_id)
         end end;
  get diagnostics n = row_count;
  update public.push_messages set status = case when n = 0 then 'sent' else 'sending' end, recipients = n
   where id = m.id;
  return n;
end $$;

create or replace function public.push_tick()
returns void language plpgsql security definer set search_path = '' as $$
declare
  s public.push_settings; p record; ist_hour int; quiet boolean; today_auto int; v_url text; v_key text; mid uuid;
begin
  if not pg_try_advisory_xact_lock(hashtext('puffle_push_tick')) then return; end if;
  select * into s from public.push_settings where id = 1;

  -- 1) New-video announcement (broadcast, optional).
  if s.auto_enabled and exists (select 1 from public.flixvault_posts where first_seen_at > s.auto_seen_at and not hidden) then
    ist_hour := extract(hour from now() at time zone 'Asia/Kolkata');
    quiet := case when s.quiet_start = s.quiet_end then false
                  when s.quiet_start < s.quiet_end then ist_hour >= s.quiet_start and ist_hour < s.quiet_end
                  else ist_hour >= s.quiet_start or ist_hour < s.quiet_end end;
    select count(*) into today_auto from public.push_messages
     where kind = 'new_videos' and created_at >= date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
    if not quiet and today_auto < s.daily_cap then
      select fp.id, fp.title, fp.audience, c.name channel,
             (select i.thumb_url from public.flixvault_items i where i.post_id = fp.id order by i.position limit 1) thumb
        into p
        from public.flixvault_posts fp join public.flixvault_channels c on c.id = fp.channel_id
       where fp.first_seen_at > s.auto_seen_at and not fp.hidden and not c.hidden
       order by fp.published_at desc limit 1;
      if found then
        insert into public.push_messages (kind, title, body, image, type, target, audience, auto)
        values ('new_videos', left('New: ' || p.title, 80), left('Watch now on ' || p.channel, 240), p.thumb, 'post', p.id::text, p.audience, true);
      end if;
      update public.push_settings set auto_seen_at = now() where id = 1;
    end if;
  end if;

  -- 2) Per-user automations, every 5 minutes.
  -- A problem here never stops normal sending.
  if extract(minute from now())::int % 5 = 0 then
    begin
      perform private.push_automations();
    exception when others then
      raise warning 'push_automations failed: %', sqlerrm;
    end;
  end if;

  -- 3) Due messages -> deliveries.
  for mid in select id from public.push_messages where status = 'queued' and scheduled_at <= now() order by scheduled_at limit 300 loop
    perform public.push_fanout(mid);
  end loop;

  -- 4) Wake the sender only when something is waiting.
  if exists (select 1 from public.push_deliveries where status = 'queued') then
    select url, key into v_url, v_key from private.meta_cron where id = 1 and url like '%/meta-send';
    if v_url is not null then
      perform net.http_post(url := replace(v_url, '/meta-send', '/push-send'),
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', v_key),
        body := '{}'::jsonb, timeout_milliseconds := 55000);
    end if;
  end if;
end $$;
revoke execute on function public.push_fanout(uuid), public.push_tick() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Admin (owner only)
-- ---------------------------------------------------------------------------
create or replace function public.admin_push_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) - 'id' from public.push_settings s where id = 1),
    'phones', (select count(*) from public.push_tokens where updated_at > now() - interval '60 days'),
    'users', (select count(distinct user_id) from public.push_tokens where updated_at > now() - interval '60 days'),
    'autos', coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object(
               'sent_7d', (select count(*) from public.push_messages m where m.kind = a.kind and m.created_at > now() - interval '7 days'),
               'opened_7d', (select coalesce(sum(m.opened), 0) from public.push_messages m where m.kind = a.kind and m.created_at > now() - interval '7 days'))
               order by array_position(array['welcome','daily','come_back','payment_reminder','payment_failed','payment_approved','plan_ending','plan_ended'], a.kind))
               from public.push_auto a), '[]'::jsonb),
    'daily_msgs', coalesce((select jsonb_agg(to_jsonb(d) order by d.pos) from public.push_daily_msgs d), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at desc)
                  from (select id, title, body, type, target, url, audience, status, scheduled_at, auto, kind,
                               created_at, recipients, sent, failed, opened
                          from public.push_messages where target_user is null order by created_at desc limit 50) m), '[]'::jsonb));
end $$;

create or replace function public.admin_push_auto_save(p_kind text, p_enabled boolean, p_title text, p_body text,
  p_title2 text default null, p_body2 text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  if coalesce(btrim(p_title), '') = '' then raise exception 'Write a title'; end if;
  update public.push_auto
     set enabled = coalesce(p_enabled, false),
         title = left(btrim(p_title), 80), body = left(coalesce(btrim(p_body), ''), 240),
         title2 = case when title2 is null then null else left(coalesce(nullif(btrim(p_title2), ''), title2), 80) end,
         body2 = case when body2 is null then null else left(coalesce(nullif(btrim(p_body2), ''), body2), 240) end,
         -- turning one on never sends for things that happened before
         enabled_at = case when coalesce(p_enabled, false) and not enabled then now() else enabled_at end,
         updated_at = now()
   where kind = p_kind;
  if not found then raise exception 'Unknown automation'; end if;
end $$;

create or replace function public.admin_push_daily_save(p_hours int[], p_msgs jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare x jsonb;
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  if coalesce(array_length(p_hours, 1), 0) = 0 or exists (select 1 from unnest(p_hours) h where h not between 0 and 23) then
    raise exception 'Pick at least one time';
  end if;
  update public.push_settings set daily_hours = (select array_agg(distinct h order by h) from unnest(p_hours) h) where id = 1;
  for x in select * from jsonb_array_elements(coalesce(p_msgs, '[]'::jsonb)) loop
    if coalesce(btrim(x->>'title'), '') = '' then raise exception 'Every message needs a title'; end if;
    update public.push_daily_msgs
       set title = left(btrim(x->>'title'), 80), body = left(coalesce(btrim(x->>'body'), ''), 240),
           enabled = coalesce((x->>'enabled')::boolean, true)
     where pos = (x->>'pos')::int;
  end loop;
end $$;

revoke execute on function public.admin_push_overview(), public.admin_push_auto_save(text, boolean, text, text, text, text),
  public.admin_push_daily_save(int[], jsonb) from public, anon;
grant execute on function public.admin_push_overview(), public.admin_push_auto_save(text, boolean, text, text, text, text),
  public.admin_push_daily_save(int[], jsonb) to authenticated;
