alter policy media_select on storage.objects using (
  bucket_id = 'media' and (
    (select public.is_admin()) or exists (
      select 1 from public.post_items i
      where i.thumbnail_key = objects.name
         or (
           ((select public.is_member()) or (select public.source_of()) = 'ads')
           and (
             i.trailer_key = objects.name
             or (i.media_key = objects.name and (not i.is_premium or (select public.can_full_premium())))
           )
         )
    )
  )
);