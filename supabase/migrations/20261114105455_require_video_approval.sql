create or replace function private.guard_posts() returns trigger language plpgsql set search_path = '' as $$
declare ch_aud text;
begin
  if current_user not in ('authenticated','anon') then return new; end if;
  if tg_op = 'INSERT' then
    if public.can_manage_channel(new.channel_id) then
      new.created_by := coalesce(new.created_by, auth.uid());
    else
      select audience into ch_aud from public.channels where id = new.channel_id;
      new.created_by := auth.uid(); new.hidden := false; new.audience := coalesce(ch_aud, 'all');
      new.status := 'draft'; new.publish_at := null;
    end if;
    return new;
  end if;
  if new.channel_id is distinct from old.channel_id or new.created_by is distinct from old.created_by then
    raise exception 'protected post fields' using errcode = '42501';
  end if;
  if not public.is_owner() then
    if new.hidden is distinct from old.hidden then raise exception 'protected post fields' using errcode = '42501'; end if;
    if not public.can_manage_channel(old.channel_id) then
      if new.audience is distinct from old.audience then raise exception 'protected post fields' using errcode = '42501'; end if;
      new.status := 'draft'; new.publish_at := null;
    end if;
  end if;
  return new;
end $$;