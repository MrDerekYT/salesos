\set ON_ERROR_STOP 1
-- Feature 4: chunking, re-embed queue, hybrid RRF retrieval, dealer scoping, citations, customer facts
create or replace function t.onehot(i int, j int default null) returns vector language sql immutable as $$
  select ('[' || array_to_string(array(select case when g = i then 1 when g = j then 1 else 0 end from generate_series(1,1536) g), ',') || ']')::vector
$$;
insert into dealers(id,name) values ('00000000-0000-0000-0015-0000000000a1','RAG Motors'),('00000000-0000-0000-0015-0000000000a2','Other Motors');
insert into dealer_members(user_id,dealer_id,role) values
 ('00000000-0000-0000-0015-0000000000b1','00000000-0000-0000-0015-0000000000a1','sales'),
 ('00000000-0000-0000-0015-0000000000b2','00000000-0000-0000-0015-0000000000a2','owner');
\set d '\'00000000-0000-0000-0015-0000000000a1\'::uuid'
\set d2 '\'00000000-0000-0000-0015-0000000000a2\'::uuid'

insert into kb_documents(id,dealer_id,kind,title,body) values
 ('00000000-0000-0000-0015-0000000000f1', :d, 'trade_in', 'Trade-ins with a loan', E'We accept trade-ins that still have a loan or lien.\n\nWe pay off the lender directly and apply any equity to your purchase.'),
 ('00000000-0000-0000-0015-0000000000f2', :d, 'financing', 'Financing basics', E'We work with credit unions and national banks.\n\nFirst-time buyers are welcome.'),
 ('00000000-0000-0000-0015-0000000000f3', :d, 'scheduling', 'Service hours', E'Service is open Saturday mornings from 8 to noon.');
insert into kb_documents(id,dealer_id,kind,title,body,valid_until) values
 ('00000000-0000-0000-0015-0000000000f4', :d, 'incentive', 'Expired loyalty cash', 'Loyalty cash of 500 for returning trade-in customers.', '2020-01-01');
insert into kb_documents(id,dealer_id,kind,title,body,status) values
 ('00000000-0000-0000-0015-0000000000f5', :d, 'policy', 'Old trade-in policy', 'We never accept trade-ins with a lien.', 'archived');
insert into kb_documents(id,dealer_id,kind,title,body) values
 ('00000000-0000-0000-0015-0000000000f9', :d2, 'trade_in', 'Other dealer trade-in lien policy', 'Trade-ins with a lien are accepted at the other dealer.');

select t.eq('trigger chunked docs (f1 has 2 paragraphs -> 1 chunk under 1200 chars)', (select count(*) from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f1')::int, 1);
select t.eq('each new chunk enqueued for embedding', (select count(*) from embed_queue q join kb_chunks c on c.id = q.target_id where c.dealer_id = :d)::int, (select count(*) from kb_chunks where dealer_id = :d)::int);
-- long document: many chunks, none over the limit
insert into kb_documents(id,dealer_id,kind,title,body) values ('00000000-0000-0000-0015-0000000000f6', :d, 'faq', 'Long FAQ',
  (select string_agg(format('Question %s about warranty coverage and maintenance plans. The answer explains the details of item %s in full sentences.', g, g), ' ') from generate_series(1,60) g)
  || E'\n\n' || repeat('x', 3000));
select t.ok('long doc split into several chunks', (select count(*) from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f6') >= 7);
select t.eq('no chunk exceeds 1200 chars', (select max(length(content)) from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f6')::int <= 1200, true);
select t.ok('chunker keeps sentences whole', (select bool_and(content ~ '\.$' or content ~ '^x+$') from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f6'));

-- worker: claim -> complete. Embed the trade-in chunk as dim 1, financing as dim 2, service as dim 3.
do $$ declare r record; v text; n int := 0; begin
  for r in select * from claim_embed_jobs(500, now()) where dealer_id in ('00000000-0000-0000-0015-0000000000a1','00000000-0000-0000-0015-0000000000a2') loop
    select case d.id when '00000000-0000-0000-0015-0000000000f1' then 1 when '00000000-0000-0000-0015-0000000000f2' then 2
                     when '00000000-0000-0000-0015-0000000000f3' then 3 when '00000000-0000-0000-0015-0000000000f9' then 1 else 50 end::text
      into v from kb_chunks c join kb_documents d on d.id = c.document_id where c.id = r.target_id;
    if r.target_kind = 'kb_chunk' then
      perform t.eq('complete stores the vector', complete_embed_job(r.target_kind, r.target_id, t.onehot(v::int), 'test-embed-1', r.content_hash), 'stored');
      n := n + 1;
    end if;
  end loop;
  perform t.ok('claimed and stored every kb chunk', n >= 10);
end $$;
select t.eq('queue drained for kb chunks', (select count(*) from embed_queue where target_kind = 'kb_chunk' and dealer_id = :d)::int, 0);

-- re-embed on change: editing f2 resets only its chunk and bumps the version
update kb_documents set body = E'We work with credit unions and national banks.\n\nFirst-time buyers and students are welcome.' where id = '00000000-0000-0000-0015-0000000000f2';
select t.eq('changed chunk re-queued', (select count(*) from embed_queue q join kb_chunks c on c.id = q.target_id where c.document_id = '00000000-0000-0000-0015-0000000000f2')::int, 1);
select t.ok('its embedding was cleared', (select embedding is null from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f2'));
select t.ok('unchanged doc keeps its embedding', (select embedding is not null from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f1'));
select t.eq('document version bumped', (select version from kb_documents where id = '00000000-0000-0000-0015-0000000000f2'), 2);
update kb_documents set body = 'Short now.' where id = '00000000-0000-0000-0015-0000000000f6';
select t.eq('shrinking a doc deletes surplus chunks', (select count(*) from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f6')::int, 1);
-- stale completion: hash no longer matches
do $$ declare r record; begin
  select * into r from claim_embed_jobs(500, now()) where target_id = (select id from kb_chunks where document_id = '00000000-0000-0000-0015-0000000000f2');
  perform t.eq('completing with an old hash is refused', complete_embed_job('kb_chunk', r.target_id, t.onehot(2), 'test-embed-1', 'not-the-hash'), 'stale');
  perform t.ok('stale job unlocked for retry', (select locked_at is null from embed_queue where target_id = r.target_id));
  perform fail_embed_job('kb_chunk', r.target_id, 'provider 500');
  perform t.ok('failure backs off', (select not_before > now() from embed_queue where target_id = r.target_id));
  perform t.eq('complete with the right hash', complete_embed_job('kb_chunk', r.target_id, t.onehot(2), 'test-embed-1', r.content_hash), 'stored');
end $$;
select t.ok('defer_embed_jobs pushes work out when no provider is configured', defer_embed_jobs(60, 'no provider') >= 0);

-- vehicles: listing chunk excludes price/status; price change does not re-embed, description change does
insert into vehicles(id,dealer_id,vin,year,make,model,trim,price_cents,status,body_style,condition,mileage,features,description) values
 ('00000000-0000-0000-0015-00000000aa01', :d, '1HGCV1F30LA000001', 2022, 'Honda', 'Accord', 'EX-L', 2899500, 'available', 'sedan', 'used', 21000, array['heated seats','apple carplay'], 'One owner, clean history.'),
 ('00000000-0000-0000-0015-00000000aa02', :d, '5YJ3E1EA7KF000002', 2021, 'Tesla', 'Model 3', 'Long Range', 3199500, 'sold', 'sedan', 'used', 30000, array['autopilot'], 'Sold already.');
select t.ok('listing chunk created per vehicle', (select count(*) from vehicle_listing_chunks where dealer_id = :d) = 2);
select t.ok('listing text has trim, mileage and features', (select content ~ 'EX-L' and content ~ '21,000' and content ~ 'heated seats' from vehicle_listing_chunks where vehicle_id = '00000000-0000-0000-0015-00000000aa01'));
select t.ok('listing text never contains the price', (select content !~ '28995|28,995' from vehicle_listing_chunks where vehicle_id = '00000000-0000-0000-0015-00000000aa01'));
select t.eq('vehicle chunks enqueued', (select count(*) from embed_queue where target_kind = 'vehicle_chunk' and dealer_id = :d)::int, 2);
delete from embed_queue where target_kind = 'vehicle_chunk' and dealer_id = :d;
update vehicles set price_cents = 2799500 where id = '00000000-0000-0000-0015-00000000aa01';
select t.eq('price change: no re-embed', (select count(*) from embed_queue where target_kind = 'vehicle_chunk' and dealer_id = :d)::int, 0);
update vehicles set description = 'One owner, clean history, new tires.' where id = '00000000-0000-0000-0015-00000000aa01';
select t.eq('description change: re-embed queued', (select count(*) from embed_queue where target_kind = 'vehicle_chunk' and dealer_id = :d)::int, 1);
update vehicle_listing_chunks set embedding = t.onehot(4), embedding_model = 'test-embed-1' where dealer_id = :d;

-- retrieval: full-text only (no query embedding)
select t.eq('FTS: lien question finds the trade-in doc first', (select document_id::text from match_kb(:d, 'Do you take trade-ins with a loan lien on them?') limit 1), '00000000-0000-0000-0015-0000000000f1');
select t.eq('mode reports fts_only', (select mode from match_kb(:d, 'trade-in lien') limit 1), 'fts_only');
select t.ok('expired incentive never retrieved', not exists (select 1 from match_kb(:d, 'loyalty cash trade-in', null, null, null, 20) where document_id = '00000000-0000-0000-0015-0000000000f4'));
select t.ok('archived policy never retrieved', not exists (select 1 from match_kb(:d, 'never accept trade-ins lien', null, null, null, 20) where document_id = '00000000-0000-0000-0015-0000000000f5'));
select t.ok('other dealer''s docs never retrieved', not exists (select 1 from match_kb(:d, 'other dealer trade-in lien policy', null, null, null, 20) where document_id = '00000000-0000-0000-0015-0000000000f9'));
select t.ok('kind filter', not exists (select 1 from match_kb(:d, 'trade-ins credit unions', null, null, array['financing'], 20) where kind <> 'financing'));
select t.eq('vehicle description search (available only)', (select vehicle_id::text from match_kb(:d, 'accord heated seats carplay') where source_kind = 'vehicle' limit 1), '00000000-0000-0000-0015-00000000aa01');
select t.ok('sold vehicle never retrieved', not exists (select 1 from match_kb(:d, 'tesla autopilot model', null, null, null, 20) where vehicle_id = '00000000-0000-0000-0015-00000000aa02'));
select t.eq('stopword-only query returns nothing (no garbage)', (select count(*) from match_kb(:d, 'the and of'))::int, 0);

-- retrieval: hybrid (vector + text, fused with RRF)
select t.eq('vector-only hit: nonsense text, embedding = financing', (select document_id::text from match_kb(:d, 'zzqx', t.onehot(2), 'test-embed-1') limit 1), '00000000-0000-0000-0015-0000000000f2');
select t.eq('mode reports hybrid', (select mode from match_kb(:d, 'zzqx', t.onehot(2)) limit 1), 'hybrid');
select t.ok('vector-only hits carry vec_rank and no fts_rank', (select vec_rank = 1 and fts_rank is null from match_kb(:d, 'zzqx', t.onehot(2)) limit 1));
select t.eq('agreement wins: text says service, vector says service', (select document_id::text from match_kb(:d, 'saturday service hours', t.onehot(3)) limit 1), '00000000-0000-0000-0015-0000000000f3');
select t.eq('a doc in both lists outranks a text-only match (lien doc is FTS #1 here)',
  (select document_id::text from match_kb(:d, 'trade-in loan lien saturday service', t.onehot(3)) limit 1), '00000000-0000-0000-0015-0000000000f3');
select t.ok('...and the text-only lien doc is still returned', exists (select 1 from match_kb(:d, 'trade-in loan lien saturday service', t.onehot(3)) where document_id = '00000000-0000-0000-0015-0000000000f1' and vec_rank is null));
select t.ok('dissimilar vectors are cut by min similarity', not exists (select 1 from match_kb(:d, 'zzqx', t.onehot(900)) ));
select t.eq('embedding model filter excludes other models', (select count(*) from match_kb(:d, 'zzqx', t.onehot(2), 'other-model'))::int, 0);
select t.ok('match_count is capped at 20', (select count(*) from match_kb(:d, 'trade-ins financing service warranty accord', t.onehot(1, 2), null, null, 500)) <= 20);

-- dealer scoping for authenticated callers
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0015-0000000000b1"}', false);
set role authenticated;
select t.ok('member can search own dealer', (select count(*) from match_kb('00000000-0000-0000-0015-0000000000a1', 'trade-in lien')) >= 1);
select t.raises('member cannot search another dealer', $q$select * from match_kb('00000000-0000-0000-0015-0000000000a2', 'trade-in lien')$q$, '%not a member%');
select t.raises('staff cannot read the embed queue', $q$select * from embed_queue$q$, '%permission denied%');
select t.raises('staff cannot call worker functions', $q$select * from claim_embed_jobs(1)$q$, '%permission denied%');
reset role;
set role anon;
select t.raises('anon cannot search', $q$select * from match_kb('00000000-0000-0000-0015-0000000000a1', 'x')$q$, '%permission denied%');
reset role;
select set_config('request.jwt.claims', '', false);

-- citations
insert into contacts(id,dealer_id,first_name,phone_e164) values ('00000000-0000-0000-0015-0000000000c1', :d, 'Cy', '+15555515001');
insert into leads(id,dealer_id,contact_id) values ('00000000-0000-0000-0015-0000000000e1', :d, '00000000-0000-0000-0015-0000000000c1');
insert into channel_numbers(id,dealer_id,channel,address) values ('00000000-0000-0000-0015-0000000000aa', :d, 'sms', '+15555515999');
insert into outbound_drafts(id,dealer_id,lead_id,contact_id,channel,number_id,body_ai) values
 ('00000000-0000-0000-0015-0000000000d1', :d, '00000000-0000-0000-0015-0000000000e1', '00000000-0000-0000-0015-0000000000c1', 'sms', '00000000-0000-0000-0015-0000000000aa', 'Yes, we take trade-ins with a lien.');
select t.eq('citations: own-dealer chunks kept, foreign chunk dropped', record_draft_citations('00000000-0000-0000-0015-0000000000d1',
  jsonb_build_array(
    jsonb_build_object('source_kind','kb','chunk_id',(select id from kb_chunks where document_id='00000000-0000-0000-0015-0000000000f1'),'score',0.03),
    jsonb_build_object('source_kind','vehicle','chunk_id',(select id from vehicle_listing_chunks where vehicle_id='00000000-0000-0000-0015-00000000aa01'),'score',0.02),
    jsonb_build_object('source_kind','kb','chunk_id',(select id from kb_chunks where document_id='00000000-0000-0000-0015-0000000000f9'),'score',0.9))), 2);
select t.eq('citation pins the document version', (select document_version from draft_citations where draft_id = '00000000-0000-0000-0015-0000000000d1' and kb_chunk_id is not null), 1);

-- customer facts: provenance ranking
select t.eq('AI extracts a budget', upsert_customer_fact(:d, '00000000-0000-0000-0015-0000000000e1', 'budget_max_cents', '3000000', 'ai_extracted', 0.8, 'around 30k'), 'inserted');
select t.eq('same value is a no-op', upsert_customer_fact(:d, '00000000-0000-0000-0015-0000000000e1', 'budget_max_cents', '3000000', 'ai_extracted'), 'unchanged');
select t.eq('rep corrects it', upsert_customer_fact(:d, '00000000-0000-0000-0015-0000000000e1', 'budget_max_cents', '3500000', 'rep_entered'), 'updated');
select t.eq('AI cannot overwrite the rep', upsert_customer_fact(:d, '00000000-0000-0000-0015-0000000000e1', 'budget_max_cents', '2000000', 'ai_extracted'), 'kept_existing');
select t.eq('one current value, history kept', (select count(*) filter (where superseded_at is null) || '/' || count(*) from customer_facts where lead_id = '00000000-0000-0000-0015-0000000000e1'), '1/2');
select t.raises('sensitive keys are impossible (no SSN/credit fields)', $q$select upsert_customer_fact('00000000-0000-0000-0015-0000000000a1','00000000-0000-0000-0015-0000000000e1','ssn','"123"','ai_extracted')$q$, '%check constraint%');
select t.raises('fact for another dealer''s lead refused', $q$select upsert_customer_fact('00000000-0000-0000-0015-0000000000a2','00000000-0000-0000-0015-0000000000e1','preferred_color','"red"','ai_extracted')$q$, '%not in dealer%');

select t.eq('model switch re-queues everything embedded with another model', requeue_embeddings_for_model('test-embed-2'), ((select count(*) from kb_chunks) + (select count(*) from vehicle_listing_chunks))::int);
select 'RAG TESTS PASSED';
