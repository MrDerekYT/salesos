create or replace function pg_temp.dummy() returns void language sql as 'select 1';
create schema if not exists t;
create or replace function t.eq(label text, actual anyelement, expected anyelement) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL [%]: expected %, got %', label, expected, actual;
  end if;
  raise notice 'ok   [%]', label;
end $$;
create or replace function t.ok(label text, cond boolean) returns void language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL [%]', label; end if;
  raise notice 'ok   [%]', label;
end $$;
create or replace function t.raises(label text, stmt text, like_msg text default null) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then
    if like_msg is not null and sqlerrm not like like_msg then raise exception 'FAIL [%]: wrong error: %', label, sqlerrm; end if;
    raise notice 'ok   [%] (raised: %)', label, left(sqlerrm, 60); return;
  end;
  raise exception 'FAIL [%]: expected an error', label;
end $$;
grant usage on schema t to public; grant execute on all functions in schema t to public;
