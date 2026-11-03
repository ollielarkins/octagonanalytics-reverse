-- 0138_resolve_job_and_client.sql
-- One ranked lookup for jobs and one for companies, used by every connector tool (octagon-mcp 3.92.0).
--
-- Name lookups were the biggest single source of tool errors (03/11/2026 gap review): job_spec failed
-- on 15 of 171 calls as ambiguous_job, client_status on 11 of 33 as ambiguous or no company. The old
-- lookups took the first five jobs whose title contained the text, across every job ever (5,800+
-- closed), and refused if there was more than one. On 03/11/2026, 93 of the 142 Open jobs could not
-- be found by their own exact title, because an older job shared it. Companies were matched with a
-- bare contains, so "Calnex Solutions" and "Calnex Solutions Ltd" were ambiguous forever, and a typo
-- was simply "no company".
--
-- resolve_job: an ID or slug wins outright. Otherwise every word given must appear in the job title
-- or its client's name, so "Field Service Engineer PDAS" works. One pick when the answer is clear: a
-- single exact-title live job, else a single live job (Open or On Hold), else a single match at all.
-- p_prefer_live false (reopening a job) skips the live preference. Otherwise up to 8 matches, live
-- first, each with client, status, owner and opened date so the recruiter can choose at a glance.
-- No match: up to 5 near titles as did_you_mean.
--
-- resolve_client: names are compared without Ltd, Limited, plc, LLP, Inc, Group, UK, "the" and
-- punctuation. One pick for a slug, a single normalised-exact name, or a single contains-match; among
-- duplicates of the same name, the one with Open jobs. The others come back in also_matches so a
-- duplicate is never hidden. No match: up to 5 near names as did_you_mean.

create or replace function public.company_key(p text)
returns text
language sql
immutable
as $$
  select regexp_replace(lower(coalesce(p, '')), '\m(ltd|limited|plc|llp|inc|group|uk|the)\M|[^a-z0-9]+', '', 'g')
$$;

create or replace function public.resolve_job(p_q text, p_prefer_live boolean default true)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'extensions'
as $function$
  with q as (select trim(coalesce(p_q, '')) s),
  toks as (
    select t from q, regexp_split_to_table(lower(q.s), '[^a-z0-9+#]+') t
    where length(t) >= 2 and t not in ('at', 'for', 'the', 'an', 'and', 'job', 'role', 'in', 'of', 'with', 'to')
  ),
  j as (
    select j.recruitcrm_id, j.slug, j.title, j.status, j.company_slug, j.client_id, j.created_date,
      cl.company_name client, co.name owner, (j.status in ('Open', 'On Hold')) live,
      lower(coalesce(j.title, '') || ' ' || coalesce(cl.company_name, '')) hay
    from jobs j left join clients cl on cl.id = j.client_id left join consultants co on co.id = j.consultant_id
    where j.deleted_at is null
  ),
  direct as (
    select j.* from j, q where (q.s ~ '^[0-9]{1,18}$' and j.recruitcrm_id = q.s::bigint) or j.slug = q.s
  ),
  hits as (
    select j.*, lower(j.title) = lower(q.s) exact, similarity(lower(j.title), lower(q.s)) sim
    from j, q
    where not exists (select 1 from direct) and exists (select 1 from toks)
      and not exists (select 1 from toks where position(toks.t in j.hay) = 0)
  ),
  ranked as (
    select * from hits order by exact desc, (p_prefer_live and live) desc, sim desc, created_date desc nulls last limit 8
  ),
  pick as (
    select * from direct
    union all
    select r.* from (
      select h.recruitcrm_id, h.slug, h.title, h.status, h.company_slug, h.client_id, h.created_date, h.client, h.owner, h.live, h.hay
      from hits h
      where (select count(*) from hits where exact and (live or not p_prefer_live)) = 1 and h.exact and (h.live or not p_prefer_live)
      union all
      select h.recruitcrm_id, h.slug, h.title, h.status, h.company_slug, h.client_id, h.created_date, h.client, h.owner, h.live, h.hay
      from hits h
      where (select count(*) from hits where exact and (live or not p_prefer_live)) <> 1
        and p_prefer_live and (select count(*) from hits where live) = 1 and h.live
      union all
      select h.recruitcrm_id, h.slug, h.title, h.status, h.company_slug, h.client_id, h.created_date, h.client, h.owner, h.live, h.hay
      from hits h
      where (select count(*) from hits where exact and (live or not p_prefer_live)) <> 1
        and not (p_prefer_live and (select count(*) from hits where live) = 1)
        and (select count(*) from hits) = 1
    ) r
    where not exists (select 1 from direct)
    limit 1
  )
  select jsonb_build_object(
    'pick', (select jsonb_build_object('recruitcrm_id', recruitcrm_id, 'slug', slug, 'title', title, 'status', status, 'company_slug', company_slug,
               'client_id', client_id, 'client', client, 'owner', owner, 'opened', created_date::date) from pick limit 1),
    'total', (select count(*) from hits),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('recruitcrm_id', recruitcrm_id, 'slug', slug, 'title', title, 'status', status,
               'company_slug', company_slug, 'client_id', client_id, 'client', client, 'owner', owner, 'opened', created_date::date)) from ranked), '[]'::jsonb),
    'did_you_mean', case when exists (select 1 from direct) or exists (select 1 from hits) then '[]'::jsonb else
      coalesce((select jsonb_agg(jsonb_build_object('job_id', recruitcrm_id, 'title', title, 'client', client, 'status', status))
        from (select j.* from j, q where similarity(lower(j.title), lower(q.s)) >= 0.4
              order by live desc, similarity(lower(j.title), lower(q.s)) desc, created_date desc nulls last limit 5) d), '[]'::jsonb) end
  );
$function$;

create or replace function public.resolve_client(p_q text)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'extensions'
as $function$
  with q as (select trim(coalesce(p_q, '')) s, company_key(p_q) k),
  c as (
    select cl.id, cl.company_slug, cl.company_name, cl.company_status, company_key(cl.company_name) k,
      (select count(*) from jobs j where j.client_id = cl.id and j.deleted_at is null and j.status = 'Open') open_jobs,
      (select max(j.created_date) from jobs j where j.client_id = cl.id and j.deleted_at is null) last_job
    from clients cl, q
    where cl.deleted_at is null and (cl.company_slug = q.s or (length(q.k) >= 2 and company_key(cl.company_name) like '%' || q.k || '%'))
  ),
  scored as (
    select c.*, c.company_slug = q.s by_slug, c.k = q.k exact, similarity(c.k, q.k) sim from c, q
  ),
  tier as (
    select * from scored
    where by_slug or (not exists (select 1 from scored where by_slug) and (exact or not exists (select 1 from scored where exact)))
  ),
  pick as (
    select * from tier
    where (select count(*) from tier) = 1
       or ((select count(*) from tier where open_jobs > 0) = 1 and open_jobs > 0)
    order by by_slug desc, open_jobs desc limit 1
  ),
  ranked as (
    select * from scored order by by_slug desc, exact desc, open_jobs desc, last_job desc nulls last, sim desc limit 8
  )
  select jsonb_build_object(
    'pick', (select jsonb_build_object('company_slug', company_slug, 'company_name', company_name, 'company_status', company_status, 'open_jobs', open_jobs) from pick),
    'also_matches', coalesce((select jsonb_agg(company_name) from ranked where company_slug <> coalesce((select company_slug from pick), '')), '[]'::jsonb),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('company_slug', company_slug, 'company_name', company_name, 'company_status', company_status,
               'open_jobs', open_jobs, 'last_job', last_job::date)) from ranked), '[]'::jsonb),
    'did_you_mean', case when exists (select 1 from scored) then '[]'::jsonb else
      coalesce((select jsonb_agg(company_name) from (select cl.company_name from clients cl, q where cl.deleted_at is null and length(q.k) >= 3
          and similarity(company_key(cl.company_name), q.k) >= 0.35 order by similarity(company_key(cl.company_name), q.k) desc limit 5) d), '[]'::jsonb) end
  );
$function$;

revoke execute on function public.resolve_job(text, boolean) from public, anon, authenticated;
revoke execute on function public.resolve_client(text) from public, anon, authenticated;
