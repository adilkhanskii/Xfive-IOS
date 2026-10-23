-- Ролики портфолио, загруженные в Bunny, но так и не ставшие кейсом (закрыли окно,
-- отменили) — удаляем через сутки, чтобы в Bunny не копилось непроверенное видео.
create or replace function public.portfolio_video_orphans(p_limit integer default 5)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(a.video_id), '[]'::jsonb)
  from (
    select v.video_id
    from public.portfolio_video_assets v
    where v.status = 'uploading'
      and v.created_at < now() - interval '24 hours'
      and not exists (
        select 1 from public.portfolio_items i
        where i.media_url = 'bunny-stream:' || v.video_id::text
      )
    order by v.created_at
    limit greatest(1, least(coalesce(p_limit, 5), 20))
  ) a;
$$;
revoke all on function public.portfolio_video_orphans(integer) from public, anon, authenticated;
grant execute on function public.portfolio_video_orphans(integer) to service_role;
