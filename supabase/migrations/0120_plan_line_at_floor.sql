-- 0120_plan_line_at_floor.sql
-- 0119's Monday line said "Worked back from your £30,000 quarter" for Bhav, whose plan is the flat
-- minimums: his fees mean £30,000 needs only 3 CVs, 2 interview requests and 2 interviews a week. When
-- every figure worked back from billing is below its minimum, the line now says so (Oliver,
-- 26/10/2026). Guarded edit of action_queue; nothing else changes.
do $do$
declare
  def text := pg_get_functiondef('public.action_queue(bigint)'::regprocedure);
  old text := $a$                       else 'Worked back from your £'$a$;
  new text := $b$                       when (pl.x->'from_billing'->>'cv_sent')::numeric < (pl.x->'floor'->>'cv_sent')::numeric
                        and (pl.x->'from_billing'->>'interview_request')::numeric < (pl.x->'floor'->>'interview_request')::numeric
                        and (pl.x->'from_billing'->>'first_interview')::numeric < (pl.x->'floor'->>'first_interview')::numeric
                         then 'Your target needs fewer, so this is the minimum'
                       else 'Worked back from your £'$b$;
begin
  if position('Your target needs fewer' in def) > 0 then
    return;   -- already applied
  end if;
  if (length(def) - length(replace(def, old, ''))) / length(old) <> 1 then
    raise exception '0120: plan line not found exactly once; action_queue has changed since 0119';
  end if;
  execute replace(def, old, new);
end;
$do$;
