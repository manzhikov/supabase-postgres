-- dblink/after-create.sql runs as superuser (via supautils) and revokes
-- execute on dblink_connect_u from everyone but supabase_admin, to stop
-- non-privileged roles connecting to the local server as supabase_admin
-- with no password (dblink_connect_u trusts the calling role).
--
-- The script used to find the grants to revoke via an unqualified
-- `select ... from pg_proc where proname = 'dblink_connect_u'`. With
-- search_path set to an empty string, Postgres implicitly searches pg_temp
-- first, so a session-local temp table named pg_proc could shadow the real
-- catalog and make the loop see zero rows, silently skipping the revoke.
--
-- dblink is already installed by nix/tests/prime.sql, so this attacks a
-- fresh (re)install rather than the very first one.
drop extension dblink;

-- attack: shadow pg_proc with a temp table before creating the extension.
-- If the after-create.sql script resolves the shadowed (empty) relation
-- instead of the real pg_catalog.pg_proc, the revoke loop finds nothing to
-- revoke and postgres keeps execute on dblink_connect_u.
create temp table pg_proc (oid oid, proname text, proacl aclitem[]);

create extension dblink;

select has_function_privilege('postgres', 'dblink_connect_u(text)', 'execute') as postgres_can_connect_after_shadow_attempt;

drop table pg_proc;
