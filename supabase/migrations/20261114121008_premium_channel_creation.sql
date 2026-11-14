alter policy channels_insert on public.channels with check (
  (select public.is_owner()) or (
    (select public.is_member()) and (select public.has_plan()) and created_by = (select auth.uid())
  )
);