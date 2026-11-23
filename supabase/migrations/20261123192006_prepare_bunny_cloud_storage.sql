alter table public.cloud_files
  add column storage_provider text not null default 'supabase'
    check (storage_provider in ('supabase', 'bunny_pending', 'bunny')),
  add column storage_lock_until timestamptz;

-- Keep the provider, object identity, quota and transfer lease server-controlled.
create function private.guard_cloud_storage_provider() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user not in ('authenticated', 'anon') then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.storage_provider <> 'supabase' then
      raise exception 'Use the cloud files service to delete this file' using errcode = '42501';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.storage_provider <> 'supabase' or new.storage_lock_until is not null then
      raise exception 'Cloud storage provider is server controlled' using errcode = '42501';
    end if;
  elsif new.storage_provider is distinct from old.storage_provider
      or new.storage_lock_until is distinct from old.storage_lock_until
      or new.id is distinct from old.id
      or new.user_id is distinct from old.user_id
      or new.storage_path is distinct from old.storage_path
      or new.size_bytes is distinct from old.size_bytes then
    raise exception 'Cloud file identity is server controlled' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger cloud_files_provider_guard
  before insert or update or delete on public.cloud_files
  for each row execute function private.guard_cloud_storage_provider();

-- Serialize new reservations with the existing quota counter trigger.
create function public.reserve_bunny_cloud_file(p_user uuid, p_path text, p_name text, p_size bigint)
returns public.cloud_files language plpgsql security definer set search_path = '' as $$
declare
  used bigint;
  file public.cloud_files;
begin
  if p_size is null or p_size <= 0 or p_name is null or length(p_name) not between 1 and 180
      or p_user is null or split_part(p_path, '/', 1) is distinct from p_user::text then
    raise exception 'Invalid file' using errcode = '22023';
  end if;
  select p.used_bytes into used from public.profiles p where p.id = p_user and not p.is_guest for update;
  if used is null or p_size > private.quota_bytes(p_user) - used then
    raise exception 'Storage quota exceeded' using errcode = '42501';
  end if;
  insert into public.cloud_files (user_id, name, storage_path, size_bytes, mime, storage_provider)
  values (p_user, p_name, p_path, p_size, 'application/octet-stream', 'bunny_pending')
  returning * into file;
  return file;
end;
$$;
revoke all on function public.reserve_bunny_cloud_file(uuid, text, text, bigint) from public, anon, authenticated;
grant execute on function public.reserve_bunny_cloud_file(uuid, text, text, bigint) to service_role;

-- A row can also disappear by account deletion. Keep the object identity after the cascade.
create table private.bunny_cloud_cleanup (
  file_id uuid primary key,
  user_id uuid not null,
  staging_path text not null,
  retry_after timestamptz not null
);

create function private.enqueue_bunny_cloud_cleanup() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.storage_provider <> 'supabase' then
    insert into private.bunny_cloud_cleanup (file_id, user_id, staging_path, retry_after)
    values (old.id, old.user_id, old.storage_path,
      greatest(now(), old.storage_lock_until) + interval '1 minute');
  end if;
  return null;
end;
$$;
revoke all on function private.enqueue_bunny_cloud_cleanup() from public, anon, authenticated;

create trigger cloud_files_enqueue_bunny_cleanup after delete on public.cloud_files
  for each row execute function private.enqueue_bunny_cloud_cleanup();

create function public.next_bunny_cloud_cleanup()
returns table (file_id uuid, user_id uuid, staging_path text)
language sql security definer set search_path = '' as $$
  with due as (
    select c.file_id from private.bunny_cloud_cleanup c
    where c.retry_after <= now()
    order by c.retry_after limit 20 for update skip locked
  )
  update private.bunny_cloud_cleanup c set retry_after = now() + interval '15 minutes'
  from due where c.file_id = due.file_id
  returning c.file_id, c.user_id, c.staging_path;
$$;

create function public.finish_bunny_cloud_cleanup(p_file uuid) returns void
language sql security definer set search_path = '' as $$
  delete from private.bunny_cloud_cleanup where file_id = p_file;
$$;

revoke all on function public.next_bunny_cloud_cleanup(), public.finish_bunny_cloud_cleanup(uuid)
  from public, anon, authenticated;
grant execute on function public.next_bunny_cloud_cleanup(), public.finish_bunny_cloud_cleanup(uuid)
  to service_role;

select cron.schedule('bunny-cloud-cleanup', '*/10 * * * *', $cron$
  delete from public.cloud_files
  where storage_provider = 'bunny_pending' and created_at < now() - interval '24 hours'
    and (storage_lock_until is null or storage_lock_until < now());

  select net.http_post(url := replace(url, '/meta-send', '/bunny-cloud-cleanup'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', key),
    body := '{}'::jsonb, timeout_milliseconds := 110000)
  from private.meta_cron where id = 1 and url like '%/meta-send'
    and exists (select 1 from private.bunny_cloud_cleanup where retry_after <= now());
$cron$);
