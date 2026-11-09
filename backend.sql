-- Supply Chain Rush: isolated schema, not exposed via Data API. Anon can only call the public.scr_* RPCs.
create schema if not exists scr;
revoke all on schema scr from public, anon, authenticated;

create table if not exists scr.attempts (
  id uuid primary key default gen_random_uuid(),
  secret uuid not null default gen_random_uuid(),
  name text not null,
  started_at timestamptz not null default now(),
  deadline timestamptz not null default now() + interval '240 seconds',
  answers jsonb not null default '{}'::jsonb,   -- {"1":{"c":"B","p":200}, ...}
  score int not null default 0,
  finished_at timestamptz
);
create index if not exists scr_attempts_rank on scr.attempts (score desc, finished_at) where finished_at is not null;
alter table scr.attempts enable row level security;

-- Fixed scoring rubric (max 200 per challenge, 1000 total)
create or replace function scr.points(ch int, choice text) returns int language sql immutable as $$
  select case ch
    when 1 then case choice when 'B' then 200 when 'C' then 80 else 0 end
    when 2 then case choice when 'naoh' then 200 when 'all' then 60 else 0 end
    when 3 then case choice when 'desert' then 200 when 'deadsea' then 80 when 'air' then 40 else 0 end
    when 4 then case choice when 'backup' then 200 when 'partial' then 120 else 0 end
    when 5 then (
      select coalesce(sum(case when s.v = k.v and s.i = k.i then 40 else 0 end),0)::int
      from unnest(string_to_array(choice, ',')) with ordinality s(v,i)
      join unnest(array['qc','pack','docs','load','pod']) with ordinality k(v,i) on s.i = k.i
      where (select count(*) from unnest(string_to_array(choice, ','))) = 5
    )
    else 0 end
$$;

create or replace function scr.state(a scr.attempts) returns jsonb language sql stable as $$
  select jsonb_build_object('id', a.id, 'name', a.name, 'answers', a.answers, 'score', a.score,
    'remaining', greatest(0, extract(epoch from a.deadline - now()))::int,
    'finished', a.finished_at is not null)
$$;

create or replace function scr.finalize(p_id uuid) returns void language sql as $$
  update scr.attempts set finished_at = least(now(), deadline),
    score = (select coalesce(sum((v->>'p')::int),0) from jsonb_each(answers) e(k,v))
  where id = p_id and finished_at is null
$$;

-- Start (returns credentials once)
create or replace function public.scr_start(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := left(regexp_replace(btrim(coalesce(p_name,'')), '[<>\s]+', ' ', 'g'), 24); a scr.attempts;
begin
  if char_length(n) < 2 then raise exception 'invalid name'; end if;
  insert into scr.attempts(name) values (n) returning * into a;
  return scr.state(a) || jsonb_build_object('secret', a.secret);
end $$;

create or replace function public.scr_get(p_id uuid, p_secret uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a scr.attempts;
begin
  select * into a from scr.attempts where id = p_id and secret = p_secret;
  if not found then raise exception 'not found'; end if;
  if a.finished_at is null and now() > a.deadline then perform scr.finalize(a.id); select * into a from scr.attempts where id = a.id; end if;
  return scr.state(a);
end $$;

-- Answer: first submission per challenge only (idempotent), server computes points
create or replace function public.scr_answer(p_id uuid, p_secret uuid, p_ch int, p_choice text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a scr.attempts; pts int;
begin
  select * into a from scr.attempts where id = p_id and secret = p_secret for update;
  if not found then raise exception 'not found'; end if;
  if p_ch not between 1 and 5 then raise exception 'bad challenge'; end if;
  if a.finished_at is null and not a.answers ? p_ch::text and now() <= a.deadline + interval '3 seconds' then
    pts := scr.points(p_ch, left(p_choice, 60));
    update scr.attempts set answers = answers || jsonb_build_object(p_ch::text, jsonb_build_object('c', left(p_choice,60), 'p', pts))
      where id = a.id;
  end if;
  if now() > a.deadline + interval '3 seconds' or p_ch = 5 then perform scr.finalize(a.id); end if;
  select * into a from scr.attempts where id = p_id;
  return scr.state(a) || jsonb_build_object('points', coalesce((a.answers -> p_ch::text ->> 'p')::int, 0));
end $$;

create or replace function public.scr_finish(p_id uuid, p_secret uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a scr.attempts;
begin
  select * into a from scr.attempts where id = p_id and secret = p_secret;
  if not found then raise exception 'not found'; end if;
  perform scr.finalize(a.id);
  select * into a from scr.attempts where id = p_id;
  return scr.state(a);
end $$;

-- Leaderboard: tie-break = score desc, duration asc, finish time asc, id
create or replace function public.scr_leaderboard(p_id uuid default null) returns jsonb
language sql security definer set search_path = '' stable as $$
  with r as (
    select id, name, score, extract(epoch from finished_at - started_at)::int as secs,
      row_number() over (order by score desc, finished_at - started_at asc, finished_at asc, id) as rank
    from scr.attempts where finished_at is not null)
  select jsonb_build_object(
    'top', coalesce((select jsonb_agg(jsonb_build_object('rank',rank,'name',name,'score',score,'secs',secs,'me',id = p_id) order by rank) from r where rank <= 100), '[]'::jsonb),
    'me', (select jsonb_build_object('rank',rank,'name',name,'score',score,'secs',secs,'me',true) from r where id = p_id),
    'total', (select count(*) from r))
$$;

revoke all on function public.scr_start(text), public.scr_get(uuid,uuid), public.scr_answer(uuid,uuid,int,text),
  public.scr_finish(uuid,uuid), public.scr_leaderboard(uuid) from public;
grant execute on function public.scr_start(text), public.scr_get(uuid,uuid), public.scr_answer(uuid,uuid,int,text),
  public.scr_finish(uuid,uuid), public.scr_leaderboard(uuid) to anon, authenticated;
