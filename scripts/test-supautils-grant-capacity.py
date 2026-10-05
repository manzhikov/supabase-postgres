#!/usr/bin/env python3
"""Destructive test-cluster regression; pass a psql command after --.

Example: python3 scripts/test-supautils-grant-capacity.py -- \
  docker exec -i supautils-test psql -h 127.0.0.1 -U supabase_admin -d postgres
Never point this script at a production cluster: it replaces grant GUCs and
creates test objects. The server must session-preload the patched supautils.
"""
import json
import subprocess
import sys

command = sys.argv[sys.argv.index("--") + 1:]


def query(sql, check=True):
    proc = subprocess.run(command + ["-X", "-At", "-v", "ON_ERROR_STOP=1"],
                          input=sql, text=True, capture_output=True)
    if check and proc.returncode:
        raise AssertionError(proc.stderr)
    return proc.stdout.strip()


def alter(guc, value, expected="00000"):
    sql = "\\set ON_ERROR_STOP off\n"
    sql += f"ALTER SYSTEM SET {guc} = '{value.replace(chr(39), chr(39)*2)}';\n"
    sql += "SELECT json_build_object('state', :'SQLSTATE')::text;\n"
    result = json.loads(query(sql).splitlines()[-1])
    assert result["state"] == expected, (guc, expected, result)
    assert query("SELECT 1;") == "1", "PostgreSQL crashed"


capacity = int(query("SELECT current_setting('supautils.grant_capacity');"))
assert capacity == 1024, capacity
query("""CREATE ROLE owner_capacity_test;
CREATE TABLE public.capacity_probe (id int);
CREATE FUNCTION public.capacity_noop() RETURNS trigger LANGUAGE plpgsql
AS $$BEGIN RETURN NEW; END$$;
CREATE TRIGGER capacity_trigger BEFORE INSERT ON public.capacity_probe
FOR EACH ROW EXECUTE FUNCTION public.capacity_noop();""")

for guc in ("supautils.policy_grants", "supautils.drop_trigger_grants"):
    for count in (100, 101, capacity):
        grants = {"owner_capacity_test": ["public.capacity_probe"]}
        grants.update({f"capacity_role_{i}": [] for i in range(count - 1)})
        value = json.dumps(grants, separators=(",", ":"))
        alter(guc, value)
        query("SELECT pg_reload_conf();")
        # A new backend must parse all persisted entries, including 101/1024.
        assert len(json.loads(query(f"SELECT current_setting('{guc}');"))) == count
    accepted = query(f"SELECT current_setting('{guc}');")
    overflow = {f"capacity_role_{i}": [] for i in range(capacity + 1)}
    alter(guc, json.dumps(overflow), "22023")
    table_overflow = {"owner_capacity_test": [f"public.table_{i}" for i in range(101)]}
    alter(guc, json.dumps(table_overflow), "22023")
    alter(guc, '{"valid":[],"bad":', "22023")
    assert query(f"SELECT current_setting('{guc}');") == accepted
    print(f"PASS {guc}: 100/101/1024 accepted, 1025 roles/101 tables/invalid JSON rejected")

# Exercise the assign hooks: rejected validation must preserve live grants.
sql = "\\set ON_ERROR_STOP off\n"
sql += "ALTER SYSTEM SET supautils.policy_grants = '{bad';\n"
sql += "\\set ON_ERROR_STOP on\n"
sql += "SET ROLE owner_capacity_test; CREATE POLICY capacity_policy ON public.capacity_probe USING (true);\n"
query(sql)
sql = "\\set ON_ERROR_STOP off\n"
sql += "ALTER SYSTEM SET supautils.drop_trigger_grants = '{bad';\n"
sql += "\\set ON_ERROR_STOP on\n"
sql += "SET ROLE owner_capacity_test; DROP TRIGGER capacity_trigger ON public.capacity_probe;\n"
query(sql)
print("PASS live policy/trigger permissions survive rejected configuration")
print("PASS PostgreSQL remains available after every test")
