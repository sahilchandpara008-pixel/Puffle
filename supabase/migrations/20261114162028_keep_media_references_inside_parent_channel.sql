-- Keep each media reference within its parent channel so a post cannot expose another channel's files.
create or replace function private.guard_media_channel_paths()
returns trigger language plpgsql set search_path = '' as $$
declare channel_id_ uuid; path_key text;
begin
  select p.channel_id into channel_id_ from public.posts p where p.id = new.post_id;
  if channel_id_ is null then
    raise exception 'Post is not available for this media item' using errcode = '42501';
  end if;
  foreach path_key in array array[new.media_key,new.thumbnail_key,new.trailer_key] loop
    if path_key is not null and split_part(path_key,'/',1) <> channel_id_::text then
      raise exception 'Video, thumbnail and trailer must belong to this channel' using errcode = '42501';
    end if;
  end loop;
  return new;
end;
$$;
create trigger post_items_channel_paths before insert or update of post_id,media_key,thumbnail_key,trailer_key
on public.post_items for each row execute function private.guard_media_channel_paths();
