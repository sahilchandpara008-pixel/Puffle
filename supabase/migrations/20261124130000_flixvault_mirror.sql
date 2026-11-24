-- Puffle's own copy of Flixvault's channels and posts (same ads/organic and
-- Premium rules), refreshed every 10 minutes by the flixvault-sync function.
--
-- Safety:
-- * Read-only towards Flixvault: the sync only READS Flixvault's partner feed.
-- * No Bunny video ids are stored here, so nothing in Puffle can ever delete
--   or touch a Flixvault video. Videos are signed by Flixvault at play time.
-- * Separate tables: Puffle's own channels/posts/post_items (and their Bunny
--   cleanup triggers) are not used or changed.
-- * If Flixvault can't be reached or sharing is off, the copy is left as is.

create table if not exists public.flixvault_channels (
  id            uuid primary key,
  name          text not null,
  description   text,
  category      text,
  icon_url      text,
  audience      text not null check (audience in ('all', 'ads', 'organic')),
  members_count integer not null default 0,
  rating        numeric not null default 0,
  created_at    timestamptz,
  hidden        boolean not null default false,   -- Puffle admin may hide; sync never changes it
  synced_at     timestamptz not null default now()
);

create table if not exists public.flixvault_posts (
  id           uuid primary key,
  channel_id   uuid not null references public.flixvault_channels (id) on delete cascade,
  title        text not null,
  caption      text,
  audience     text not null check (audience in ('all', 'ads', 'organic')),
  published_at timestamptz not null,
  view_count   bigint not null default 0,
  like_count   bigint not null default 0,
  hidden       boolean not null default false,
  synced_at    timestamptz not null default now()
);
create index if not exists flixvault_posts_channel_idx on public.flixvault_posts (channel_id, published_at desc);
create index if not exists flixvault_posts_published_idx on public.flixvault_posts (published_at desc);

create table if not exists public.flixvault_items (
  id          uuid primary key,
  post_id     uuid not null references public.flixvault_posts (id) on delete cascade,
  kind        text not null,
  is_premium  boolean not null default false,
  thumb_url   text,
  duration_s  integer,
  width       integer,
  height      integer,
  position    integer not null default 0,
  playable    boolean not null default false,
  has_preview boolean not null default false
);
create index if not exists flixvault_items_post_idx on public.flixvault_items (post_id, position);

create table if not exists private.flixvault_sync_state (
  id         int primary key default 1 check (id = 1),
  last_run   timestamptz,
  last_ok    timestamptz,
  channels   int,
  posts      int,
  error      text
);
insert into private.flixvault_sync_state (id) values (1) on conflict do nothing;

-- Which Flixvault audience this Puffle user belongs to (Puffle's own rule).
create or replace function public.fv_audience()
returns text language sql stable security definer set search_path = '' as $$
  select case when private.has_ads_access(auth.uid()) then 'ads' else 'organic' end
$$;
revoke execute on function public.fv_audience() from public, anon;
grant execute on function public.fv_audience() to authenticated;

alter table public.flixvault_channels enable row level security;
alter table public.flixvault_posts    enable row level security;
alter table public.flixvault_items    enable row level security;

drop policy if exists fv_channels_read on public.flixvault_channels;
create policy fv_channels_read on public.flixvault_channels for select to authenticated
  using ((select public.is_admin())
         or (not hidden and (audience = 'all' or audience = (select public.fv_audience()))));

drop policy if exists fv_posts_read on public.flixvault_posts;
create policy fv_posts_read on public.flixvault_posts for select to authenticated
  using ((select public.is_admin())
         or (not hidden and (audience = 'all' or audience = (select public.fv_audience()))
             and exists (select 1 from public.flixvault_channels c where c.id = channel_id)));

drop policy if exists fv_items_read on public.flixvault_items;
create policy fv_items_read on public.flixvault_items for select to authenticated
  using (exists (select 1 from public.flixvault_posts p where p.id = post_id));

drop policy if exists fv_channels_admin on public.flixvault_channels;
create policy fv_channels_admin on public.flixvault_channels for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists fv_posts_admin on public.flixvault_posts;
create policy fv_posts_admin on public.flixvault_posts for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

revoke all on public.flixvault_channels, public.flixvault_posts, public.flixvault_items from anon, authenticated;
grant select on public.flixvault_channels, public.flixvault_posts, public.flixvault_items to authenticated;
grant update (hidden) on public.flixvault_channels, public.flixvault_posts to authenticated;

-- ---------------------------------------------------------------------------
-- Sync: replaces the copy with a full snapshot (service role only).
-- ---------------------------------------------------------------------------
create or replace function public.flixvault_apply(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  n_ch int; n_po int;
begin
  -- One sync at a time; a second run just skips.
  if not pg_try_advisory_xact_lock(hashtext('flixvault_apply')) then
    return jsonb_build_object('skipped', true);
  end if;
  n_ch := jsonb_array_length(coalesce(p->'channels', '[]'));
  n_po := jsonb_array_length(coalesce(p->'posts', '[]'));
  -- Never wipe the copy because of an empty/broken answer.
  if n_ch = 0 then
    update private.flixvault_sync_state set last_run = now(), error = 'empty snapshot ignored' where id = 1;
    return jsonb_build_object('skipped', true, 'reason', 'empty');
  end if;

  insert into public.flixvault_channels as t (id, name, description, category, icon_url, audience, members_count, rating, created_at, synced_at)
  select (c->>'id')::uuid, c->>'name', c->>'description', c->>'category', c->>'icon_url', c->>'audience',
         coalesce((c->>'members_count')::int, 0), coalesce((c->>'rating')::numeric, 0),
         (c->>'created_at')::timestamptz, now()
    from jsonb_array_elements(p->'channels') c
  on conflict (id) do update set
    name = excluded.name, description = excluded.description, category = excluded.category,
    icon_url = excluded.icon_url, audience = excluded.audience, members_count = excluded.members_count,
    rating = excluded.rating, created_at = excluded.created_at, synced_at = now();

  insert into public.flixvault_posts as t (id, channel_id, title, caption, audience, published_at, view_count, like_count, synced_at)
  select (x->>'id')::uuid, (x->>'channel_id')::uuid, x->>'title', x->>'caption', x->>'audience',
         (x->>'published_at')::timestamptz, coalesce((x->>'view_count')::bigint, 0),
         coalesce((x->>'like_count')::bigint, 0), now()
    from jsonb_array_elements(coalesce(p->'posts', '[]')) x
   where exists (select 1 from public.flixvault_channels c where c.id = (x->>'channel_id')::uuid)
  on conflict (id) do update set
    channel_id = excluded.channel_id, title = excluded.title, caption = excluded.caption,
    audience = excluded.audience, published_at = excluded.published_at,
    view_count = excluded.view_count, like_count = excluded.like_count, synced_at = now();

  -- Items: replace per synced post.
  delete from public.flixvault_items i
   using jsonb_array_elements(coalesce(p->'posts', '[]')) x
   where i.post_id = (x->>'id')::uuid;
  insert into public.flixvault_items (id, post_id, kind, is_premium, thumb_url, duration_s, width, height, position, playable, has_preview)
  select (i->>'id')::uuid, (x->>'id')::uuid, coalesce(i->>'kind', 'video'), coalesce((i->>'is_premium')::boolean, false),
         i->>'thumb_url', (i->>'duration_s')::int, (i->>'width')::int, (i->>'height')::int,
         coalesce((i->>'position')::int, 0), coalesce((i->>'playable')::boolean, false),
         coalesce((i->>'has_preview')::boolean, false)
    from jsonb_array_elements(coalesce(p->'posts', '[]')) x
    cross join jsonb_array_elements(coalesce(x->'items', '[]')) i
   where exists (select 1 from public.flixvault_posts fp where fp.id = (x->>'id')::uuid)
  on conflict (id) do nothing;

  -- Gone from Flixvault (removed, unpublished, hidden) => gone from the copy.
  delete from public.flixvault_posts fp
   where not exists (select 1 from jsonb_array_elements(coalesce(p->'posts', '[]')) x where (x->>'id')::uuid = fp.id);
  delete from public.flixvault_channels fc
   where not exists (select 1 from jsonb_array_elements(p->'channels') c where (c->>'id')::uuid = fc.id);

  update private.flixvault_sync_state
     set last_run = now(), last_ok = now(), channels = n_ch, posts = n_po, error = null
   where id = 1;
  return jsonb_build_object('channels', n_ch, 'posts', n_po);
end $$;
revoke execute on function public.flixvault_apply(jsonb) from public, anon, authenticated;
grant execute on function public.flixvault_apply(jsonb) to service_role;

create or replace function public.flixvault_sync_failed(p_error text)
returns void language sql security definer set search_path = '' as $$
  update private.flixvault_sync_state set last_run = now(), error = left(p_error, 300) where id = 1
$$;
revoke execute on function public.flixvault_sync_failed(text) from public, anon, authenticated;
grant execute on function public.flixvault_sync_failed(text) to service_role;

-- ---------------------------------------------------------------------------
-- Reads for the app (run as the user, so the policies above decide).
-- Same JSON shape as Flixvault's partner feed.
-- ---------------------------------------------------------------------------
create or replace function public.fv_post_json(p public.flixvault_posts)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'channel_id', p.channel_id, 'title', p.title, 'caption', p.caption,
    'published_at', p.published_at, 'view_count', p.view_count, 'like_count', p.like_count,
    'channel', (select jsonb_build_object('id', c.id, 'name', c.name, 'icon_url', c.icon_url)
                  from public.flixvault_channels c where c.id = p.channel_id),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
               'id', i.id, 'kind', i.kind, 'is_premium', i.is_premium, 'thumb_url', i.thumb_url,
               'duration_s', i.duration_s, 'width', i.width, 'height', i.height,
               'position', i.position, 'playable', i.playable, 'has_preview', i.has_preview)
               order by i.position)
               from public.flixvault_items i where i.post_id = p.id), '[]'::jsonb))
$$;

create or replace function public.fv_explore(p_tab text default 'all', p_offset int default 0,
  p_limit int default 30, p_search text default null)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(public.fv_post_json(x.p) order by x.ord), '[]'::jsonb)
    from (
      select p, row_number() over (order by
               case when p_tab = 'popular'      then p.like_count end desc nulls last,
               case when p_tab = 'most_watched' then p.view_count end desc nulls last,
               p.published_at desc) ord
        from public.flixvault_posts p
        cross join lateral (
          select '%' || replace(replace(replace(btrim(coalesce(p_search, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pat) s
       where btrim(coalesce(p_search, '')) = ''
          or p.title ilike s.pat or p.caption ilike s.pat
          or exists (select 1 from public.flixvault_channels c where c.id = p.channel_id and c.name ilike s.pat)
       order by
         case when p_tab = 'popular'      then p.like_count end desc nulls last,
         case when p_tab = 'most_watched' then p.view_count end desc nulls last,
         p.published_at desc
       limit greatest(1, least(coalesce(p_limit, 30), 100)) offset greatest(0, coalesce(p_offset, 0))
    ) x
$$;

create or replace function public.fv_channels(p_sort text default 'trending', p_search text default null)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'description', c.description, 'category', c.category,
           'icon_url', c.icon_url, 'members_count', c.members_count, 'rating', c.rating,
           'created_at', c.created_at)
           order by
             case when p_sort = 'latest' then c.created_at end desc nulls last,
             case when p_sort = 'top' then c.rating end desc nulls last,
             c.members_count desc), '[]'::jsonb)
    from public.flixvault_channels c
    cross join lateral (
      select '%' || replace(replace(replace(btrim(coalesce(p_search, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pat) s
   where btrim(coalesce(p_search, '')) = ''
      or c.name ilike s.pat or c.description ilike s.pat or c.category ilike s.pat
$$;

create or replace function public.fv_channel(p_channel_id uuid, p_before timestamptz default null)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'channel', jsonb_build_object('id', c.id, 'name', c.name, 'description', c.description,
                 'category', c.category, 'icon_url', c.icon_url,
                 'members_count', c.members_count, 'rating', c.rating),
    'posts', coalesce((select jsonb_agg(public.fv_post_json(p) order by p.published_at desc)
               from (select * from public.flixvault_posts p
                      where p.channel_id = c.id and (p_before is null or p.published_at < p_before)
                      order by p.published_at desc limit 50) p), '[]'::jsonb))
    from public.flixvault_channels c where c.id = p_channel_id
$$;

create or replace function public.fv_post(p_post_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select public.fv_post_json(p) from public.flixvault_posts p where p.id = p_post_id
$$;

create or replace function public.fv_following()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(public.fv_post_json(x) order by x.published_at desc), '[]'::jsonb)
    from (select p.* from public.flixvault_posts p
           where p.channel_id in (select channel_id from public.flixvault_follows where user_id = (select auth.uid()))
             and p.channel_id not in (select channel_id from public.flixvault_blocks where user_id = (select auth.uid()))
           order by p.published_at desc limit 100) x
$$;

revoke execute on function public.fv_post_json(public.flixvault_posts), public.fv_explore(text, int, int, text),
  public.fv_channels(text, text), public.fv_channel(uuid, timestamptz), public.fv_post(uuid), public.fv_following()
  from public, anon;
grant execute on function public.fv_post_json(public.flixvault_posts), public.fv_explore(text, int, int, text),
  public.fv_channels(text, text), public.fv_channel(uuid, timestamptz), public.fv_post(uuid), public.fv_following()
  to authenticated;

-- Every 10 minutes. The edge function takes a few Flixvault reads (~15 ms each).
select cron.unschedule('flixvault-sync') where exists (select 1 from cron.job where jobname = 'flixvault-sync');
select cron.schedule('flixvault-sync', '*/10 * * * *', $cron$
  select net.http_post(url := replace(url, '/meta-send', '/flixvault-sync'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', key),
    body := '{}'::jsonb, timeout_milliseconds := 55000)
  from private.meta_cron where id = 1 and url like '%/meta-send';
$cron$);
