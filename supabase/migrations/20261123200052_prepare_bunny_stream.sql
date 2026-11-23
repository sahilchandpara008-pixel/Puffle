create table public.bunny_videos (
  id uuid primary key,
  library_id text not null,
  channel_id uuid references public.channels(id) on delete set null,
  uploader_id uuid references auth.users(id) on delete set null,
  purpose text check (purpose in ('main', 'trailer')),
  state text not null default 'waiting' check (state in ('waiting', 'processing', 'ready', 'failed', 'deleting')),
  created_at timestamptz not null default now(),
  upload_expires_at timestamptz,
  next_check_at timestamptz not null default now(),
  delete_requested_at timestamptz
);
alter table public.bunny_videos enable row level security;
revoke all on public.bunny_videos from anon, authenticated, public;
grant select, insert, update, delete on public.bunny_videos to service_role;
create index bunny_videos_worker on public.bunny_videos (next_check_at) where state in ('waiting', 'processing', 'deleting');

create function private.bunny_key_id(p_key text) returns uuid
language sql immutable strict set search_path = '' as $$
  select case when p_key ~ '^[0-9a-f-]{36}/bunny/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then split_part(p_key, '/', 3)::uuid end;
$$;
grant execute on function private.bunny_key_id(text) to authenticated, service_role;

alter table public.post_items
  add column bunny_video_id uuid generated always as (private.bunny_key_id(media_key)) stored references public.bunny_videos(id),
  add column trailer_bunny_video_id uuid generated always as (private.bunny_key_id(trailer_key)) stored references public.bunny_videos(id);
create unique index post_items_bunny_main on public.post_items (bunny_video_id) where bunny_video_id is not null;
create unique index post_items_bunny_trailer on public.post_items (trailer_bunny_video_id) where trailer_bunny_video_id is not null;

create function private.guard_bunny_media_binding() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  item_channel uuid;
  main_id uuid := private.bunny_key_id(new.media_key);
  trailer_id uuid := private.bunny_key_id(new.trailer_key);
  thumbnail_id uuid := private.bunny_key_id(new.thumbnail_key);
  video public.bunny_videos;
begin
  if thumbnail_id is not null and thumbnail_id is distinct from main_id then
    raise exception 'Bunny thumbnail must come from the main video' using errcode = '42501';
  end if;
  if main_id is null and trailer_id is null then return new; end if;
  select p.channel_id into item_channel from public.posts p where p.id = new.post_id;
  for video in select * from public.bunny_videos where id in (main_id, trailer_id) order by id for update loop
    if video.channel_id is distinct from item_channel or video.state = 'deleting'
      or video.delete_requested_at is not null
      or (video.id = main_id and video.purpose is distinct from 'main')
      or (video.id = trailer_id and video.purpose is distinct from 'trailer')
      or (auth.uid() is not null and video.uploader_id is distinct from auth.uid()
        and (tg_op = 'INSERT' or new.post_id is distinct from old.post_id
          or (video.id = main_id and new.media_key is distinct from old.media_key)
          or (video.id = trailer_id and new.trailer_key is distinct from old.trailer_key))) then
      raise exception 'Bunny video cannot be attached to this post' using errcode = '42501';
    end if;
    if video.id = main_id and video.state = 'ready' and new.thumbnail_key is null then
      new.thumbnail_key := new.media_key;
    end if;
  end loop;
  return new;
end;
$$;
revoke all on function private.guard_bunny_media_binding() from public, anon, authenticated;
create trigger post_items_bunny_binding before insert or update of post_id,media_key,trailer_key,thumbnail_key
on public.post_items for each row execute function private.guard_bunny_media_binding();

create function private.enqueue_bunny_stream_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.bunny_videos set delete_requested_at = now(), next_check_at = now()
  where (id = old.bunny_video_id and (tg_op = 'DELETE' or old.bunny_video_id is distinct from new.bunny_video_id))
     or (id = old.trailer_bunny_video_id and (tg_op = 'DELETE' or old.trailer_bunny_video_id is distinct from new.trailer_bunny_video_id));
  return null;
end;
$$;
revoke all on function private.enqueue_bunny_stream_delete() from public, anon, authenticated;
create trigger post_items_bunny_cleanup after delete or update of media_key,trailer_key
on public.post_items for each row execute function private.enqueue_bunny_stream_delete();

create function private.owner_delete_bunny_media() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user = 'authenticated' and (old.bunny_video_id is not null or old.trailer_bunny_video_id is not null)
    and not public.is_owner() then
    raise exception 'Only the owner can permanently delete this Bunny media' using errcode = '42501';
  end if;
  return old;
end;
$$;
create trigger post_items_owner_delete_bunny before delete on public.post_items
for each row execute function private.owner_delete_bunny_media();

create function private.bunny_post_ready(p_post uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (
    select 1 from public.post_items i join public.bunny_videos v on v.id = i.bunny_video_id
    where i.post_id = p_post and v.state <> 'ready'
  );
$$;
revoke all on function private.bunny_post_ready(uuid) from public, anon;
grant execute on function private.bunny_post_ready(uuid) to authenticated;
create policy posts_bunny_encoding on public.posts as restrictive for select to authenticated using (
  (select public.is_admin()) or created_by = (select auth.uid()) or private.bunny_post_ready(id)
);

create function private.set_post_publication_time() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status = 'published' then
    if tg_op = 'INSERT' or old.status is distinct from new.status then new.publish_at := now();
    else new.publish_at := old.publish_at;
    end if;
  end if;
  return new;
end;
$$;
create trigger posts_publication_time before insert or update of status,publish_at on public.posts
for each row execute function private.set_post_publication_time();

-- The row lock serializes cleanup with a concurrent attachment.
create function public.claim_bunny_video_delete(p_id uuid, p_library text, p_manual boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare video public.bunny_videos;
begin
  select * into video from public.bunny_videos where id = p_id and library_id = p_library for update;
  if not found or coalesce(video.upload_expires_at > now(), false) then return false; end if;
  if not p_manual and video.delete_requested_at is null then return false; end if;
  if p_manual and video.created_at > now() - interval '24 hours' then return false; end if;
  if exists(select 1 from public.post_items where bunny_video_id = p_id or trailer_bunny_video_id = p_id) then return false; end if;
  update public.bunny_videos set state = 'deleting', delete_requested_at = coalesce(delete_requested_at, now()),
    next_check_at = now() + interval '10 minutes' where id = p_id;
  return true;
end;
$$;
revoke all on function public.claim_bunny_video_delete(uuid,text,boolean) from public, anon, authenticated;
grant execute on function public.claim_bunny_video_delete(uuid,text,boolean) to service_role;

select cron.schedule('bunny-stream-sync', '* * * * *', $cron$
  select net.http_post(url := replace(url, '/meta-send', '/bunny-stream'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', key),
    body := '{"action":"sync"}'::jsonb, timeout_milliseconds := 55000)
  from private.meta_cron where id = 1 and url like '%/meta-send'
    and exists (select 1 from public.bunny_videos where next_check_at <= now()
      and (state in ('waiting','processing','deleting') or delete_requested_at is not null));
$cron$);
