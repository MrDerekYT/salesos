-- Backfill for the live bridge (idempotent). 06's loop used untyped records, so the typed sync functions were skipped.
set search_path to salesos_ai, extensions, public;
do $$
declare v salesos.vehicles; c salesos.customers; l public.leads; n_err int := 0;
begin
  for v in select * from salesos.vehicles loop
    begin perform salesos_ai.bridge_sync_vehicle(v); exception when others then n_err := n_err + 1; raise warning 'vehicle %: %', v.id, sqlerrm; end;
  end loop;
  for c in select * from salesos.customers where duplicate_of is null order by created_at loop
    begin perform salesos_ai.bridge_sync_customer(c, false); exception when others then n_err := n_err + 1; raise warning 'customer %: %', c.id, sqlerrm; end;
  end loop;
  for l in select * from public.leads loop
    begin perform salesos_ai.bridge_sync_public_lead(l, false); exception when others then n_err := n_err + 1; raise warning 'lead %: %', l.id, sqlerrm; end;
  end loop;
  raise notice 'salesos_ai backfill finished with % row errors', n_err;
end $$;
