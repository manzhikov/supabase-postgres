-- Test the standard flow
select
  pgmq.create('Foo');

select
  *
from
  pgmq.send(
    queue_name:='Foo',
    msg:='{"foo": "bar1"}'
  );

-- Test queue is not case sensitive
select
  *
from
  pgmq.send(
    queue_name:='foo', -- note: lowercase useage
    msg:='{"foo": "bar2"}',
    delay:=5
  );

select
  msg_id,
  read_ct,
  message
from
  pgmq.read(
    queue_name:='Foo',
    vt:=30,
    qty:=2
  );

select
  msg_id,
  read_ct,
  message
from
  pgmq.pop('Foo');


-- Archive message with msg_id=2.
select
  pgmq.archive(
    queue_name:='Foo',
    msg_id:=2
  );


select
  pgmq.create('my_queue');

select
  pgmq.send_batch(
  queue_name:='my_queue',
  msgs:=array['{"foo": "bar3"}','{"foo": "bar4"}','{"foo": "bar5"}']::jsonb[]
);

select
  pgmq.archive(
    queue_name:='my_queue',
    msg_ids:=array[3, 4, 5]
  );

select
  pgmq.delete('my_queue', 6);


select
  pgmq.drop_queue('my_queue');

/*
-- Disabled until pg_partman goes back into the image
select
  pgmq.create_partitioned(
    'my_partitioned_queue',
    '5 seconds',
    '10 seconds'
);
*/


-- Make sure SQLI enabling characters are blocked
select pgmq.create('F--oo');
select pgmq.create('F$oo');
select pgmq.create($$F'oo$$);
\echo

-- pgmq schema functions with owners (ownership is modified on ansible/files/postgresql_extension_custom_scripts/pgmq/after-create.sql)
select
  n.nspname as schema_name,
  p.proname as function_name,
  r.rolname as owner
from
  pg_proc p
join
  pg_namespace n on p.pronamespace = n.oid
join
  pg_roles r on p.proowner = r.oid
where
  n.nspname = 'pgmq'
order by
  p.proname;

-- assert search_path is preserved after after-create script is run
show search_path;

-- Regression test: pgmq/after-create.sql runs as superuser and resolves the
-- extension's own oid via an unqualified `select ... from pg_extension
-- where extname = 'pgmq'`, then reassigns ownership of everything pg_depend
-- reports as depending on that oid to postgres. With search_path set to an
-- empty string, pg_temp is implicitly searched first, so a session-local
-- temp table named pg_extension could shadow the real catalog, feeding the
-- script a bogus oid and leaving pgmq's own objects un-reassigned.
drop extension pgmq cascade;

create temp table pg_extension (oid oid, extname text, extversion text, extowner oid);
insert into pg_extension values (0, 'pgmq', '999.999', 'postgres'::regrole);

create extension pgmq cascade;

-- every function in the pgmq schema must be owned by postgres (proves the
-- real catalog row, not the shadowed temp-table row, was used to resolve
-- the extension oid)
select count(*) as pgmq_functions_not_owned_by_postgres
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'pgmq' and p.proowner != 'postgres'::regrole;

drop table pg_extension;

-- restore the 'Foo' queue (and its a_foo/q_foo tables) dropped by the
-- cascade above, so later tests that inspect the full set of extension
-- objects see the same schema as before this regression test ran
select
  pgmq.create('Foo');
