-- Flixvault parity: channel folders in Puffle's copy, plus admin read-outs
-- (copy status, follow/block counts). Additive only.

create table if not exists public.flixvault_folders (
  id         uuid primary key,
  channel_id uuid not null references public.flixvault_channels (id) on delete cascade,
  name       text not null,
  cover_url  text,
  position   integer not null default 0
);
create index if not exists flixvault_folders_channel_idx on public.flixvault_folders (channel_id, position);
alter table public.flixvault_folders enable row level security;
drop policy if exists fv_folders_read on public.flixvault_folders;
create policy fv_folders_read on public.flixvault_folders for select to authenticated
  using (exists (select 1 from public.flixvault_channels c where c.id = channel_id));
revoke all on public.flixvault_folders from anon, authenticated;
grant select on public.flixvault_folders to authenticated;

alter table public.flixvault_posts add column if not exists folder_id uuid;

-- Snapshot now may carry "folders" (all channels) and posts carry folder_id.
create or replace function public.flixvault_apply(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  n_ch int; n_po int;
begin
  if not pg_try_advisory_xact_lock(hashtext('flixvault_apply')) then
    return jsonb_build_object('skipped', true);
  end if;
  n_ch := jsonb_array_length(coalesce(p->'channels', '[]'));
  n_po := jsonb_array_length(coalesce(p->'posts', '[]'));
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

  if p ? 'folders' then
    insert into public.flixvault_folders as t (id, channel_id, name, cover_url, position)
    select (f->>'id')::uuid, (f->>'channel_id')::uuid, f->>'name', f->>'cover_url', coalesce((f->>'position')::int, 0)
      from jsonb_array_elements(p->'folders') f
     where exists (select 1 from public.flixvault_channels c where c.id = (f->>'channel_id')::uuid)
    on conflict (id) do update set channel_id = excluded.channel_id, name = excluded.name,
      cover_url = excluded.cover_url, position = excluded.position;
    delete from public.flixvault_folders ff
     where not exists (select 1 from jsonb_array_elements(p->'folders') f where (f->>'id')::uuid = ff.id);
  end if;

  insert into public.flixvault_posts as t (id, channel_id, folder_id, title, caption, audience, published_at, view_count, like_count, synced_at)
  select (x->>'id')::uuid, (x->>'channel_id')::uuid, nullif(x->>'folder_id', '')::uuid, x->>'title', x->>'caption', x->>'audience',
         (x->>'published_at')::timestamptz, coalesce((x->>'view_count')::bigint, 0),
         coalesce((x->>'like_count')::bigint, 0), now()
    from jsonb_array_elements(coalesce(p->'posts', '[]')) x
   where exists (select 1 from public.flixvault_channels c where c.id = (x->>'channel_id')::uuid)
  on conflict (id) do update set
    channel_id = excluded.channel_id, folder_id = excluded.folder_id, title = excluded.title, caption = excluded.caption,
    audience = excluded.audience, published_at = excluded.published_at,
    view_count = excluded.view_count, like_count = excluded.like_count, synced_at = now();

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

create or replace function public.fv_post_json(p public.flixvault_posts)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'channel_id', p.channel_id, 'folder_id', p.folder_id, 'title', p.title, 'caption', p.caption,
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

create or replace function public.fv_channel(p_channel_id uuid, p_before timestamptz default null)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'channel', jsonb_build_object('id', c.id, 'name', c.name, 'description', c.description,
                 'category', c.category, 'icon_url', c.icon_url,
                 'members_count', c.members_count, 'rating', c.rating),
    'folders', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name,
                 'cover_url', f.cover_url, 'position', f.position) order by f.position)
                 from public.flixvault_folders f where f.channel_id = c.id), '[]'::jsonb),
    'posts', coalesce((select jsonb_agg(public.fv_post_json(p) order by p.published_at desc)
               from (select * from public.flixvault_posts p
                      where p.channel_id = c.id and (p_before is null or p.published_at < p_before)
                      order by p.published_at desc limit 50) p), '[]'::jsonb))
    from public.flixvault_channels c where c.id = p_channel_id
$$;

-- ---------------------------------------------------------------------------
-- Admin read-outs (Puffle admins only)
-- ---------------------------------------------------------------------------
create or replace function public.admin_flixvault_sync()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return (select jsonb_build_object(
    'last_run', s.last_run, 'last_ok', s.last_ok, 'channels', s.channels, 'posts', s.posts, 'error', s.error,
    'hidden_channels', (select count(*) from public.flixvault_channels where hidden),
    'hidden_posts', (select count(*) from public.flixvault_posts where hidden),
    'follows', (select count(*) from public.flixvault_follows),
    'reports_7d', (select count(*) from public.flixvault_reports where created_at > now() - interval '7 days'))
    from private.flixvault_sync_state s where s.id = 1);
end $$;

create or replace function public.admin_flixvault_channel_stats()
returns table (channel_id uuid, follows bigint, blocks bigint, reports bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select c.id,
           (select count(*) from public.flixvault_follows f where f.channel_id = c.id),
           (select count(*) from public.flixvault_blocks b where b.channel_id = c.id),
           (select count(*) from public.flixvault_reports r join public.flixvault_posts p on p.id = r.post_id
             where p.channel_id = c.id)
      from public.flixvault_channels c;
end $$;

revoke execute on function public.admin_flixvault_sync(), public.admin_flixvault_channel_stats() from public, anon;
grant execute on function public.admin_flixvault_sync(), public.admin_flixvault_channel_stats() to authenticated;
