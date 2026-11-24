-- Meta App promotion ads (like Flixvault):
-- * installs keep the Meta SDK's anonymous ID and the advertising ID (sent by
--   the app only after the user allowed ad measurement; the ad ID only when ad
--   personalisation is not turned off). meta-send adds them to every event
--   (user_data.anon_id / madid) so Meta can match events to the ad click.
-- * A Google Play install from a Meta ad carries a referrer with
--   utm_source=apps.facebook.com (or an instagram/facebook link). It now counts
--   as a Meta ad install (ads audience), and meta-send passes the raw referrer
--   to Meta as app_data.install_referrer.

alter table public.installs add column if not exists fb_anon_id text;
alter table public.installs add column if not exists ad_id text;

create or replace function public.record_ad_ids(p_install_id text, p_fb_anon_id text default null, p_ad_id text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_anon text := nullif(left(trim(coalesce(p_fb_anon_id, '')), 100), '');
  v_ad   text := lower(nullif(trim(coalesce(p_ad_id, '')), ''));
begin
  if auth.uid() is null then return; end if;
  if not exists (select 1 from public.measurement_preferences m where m.user_id = auth.uid() and m.advertising) then
    return;
  end if;
  if v_ad is not null and (v_ad !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                           or v_ad = '00000000-0000-0000-0000-000000000000') then
    v_ad := null;
  end if;
  if v_anon is not null and v_anon !~ '^[A-Za-z0-9_.:-]+$' then v_anon := null; end if;
  update public.installs
     set fb_anon_id = coalesce(v_anon, fb_anon_id),
         ad_id      = v_ad,   -- cleared when the user turns ad personalisation off
         updated_at = now()
   where install_id = p_install_id and user_id = auth.uid();
end $$;
revoke execute on function public.record_ad_ids(text, text, text) from public, anon;
grant execute on function public.record_ad_ids(text, text, text) to authenticated;

-- Meta ad installs from Google Play (apps.facebook.com referrer) count as Meta.
create or replace function private.classify_referrer(p_raw text, p_status text)
returns text language plpgsql immutable set search_path = '' as $$
declare p jsonb := private.parse_referrer(p_raw); s text := lower(coalesce(p->>'utm_source', '')); m text := p->>'utm_medium';
        r text := lower(coalesce(p_raw, ''));
begin
  if s = private.meta_source() or s in ('facebook', 'instagram', 'ig', 'fb', 'messenger', 'threads', 'audience_network')
     or r like '%facebook.com%' or r like '%instagram.com%' then
    return private.meta_source();
  end if;
  if s = 'google-play' and m = 'organic' then return 'organic'; end if;
  if coalesce(trim(p_raw), '') = '' then return case when p_status = 'direct' then 'direct' else 'unknown' end; end if;
  if s <> '' then return 'other'; end if;
  return 'unknown';
end $$;
