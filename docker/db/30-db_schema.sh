#!/bin/bash
set -euxo

psql -v ON_ERROR_STOP=1 --username "system_monitor" --dbname "system_monitor" <<-EOSQL

-----------------------------------------------------------------------------------
-- prc table
-----------------------------------------------------------------------------------

create table if not exists prc (
    node text not null,
    ts timestamp without time zone not null,
    pid text not null,
    dreductions double precision not null,
    dmemory double precision not null,
    reductions bigint not null,
    memory bigint not null,
    message_queue_len bigint not null,
    current_function text,
    initial_call text,
    registered_name text,
    stack_size bigint,
    heap_size bigint,
    total_heap_size bigint,
    current_stacktrace text,
    group_leader text
) partition by range(ts);

alter table prc owner to system_monitor;
grant insert on table prc to system_monitor;
grant select on table prc to grafana;

-----------------------------------------------------------------------------------
-- app_top table
-----------------------------------------------------------------------------------
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_top_unit') THEN
        CREATE TYPE app_top_unit AS
            enum ('reductions', 'memory', 'processes');
    END IF;
END\$\$;

create table if not exists app_top (
    node text,
    ts timestamp without time zone not null,
    application text,
    unit app_top_unit,
    value numeric
) partition by range(ts);

alter table app_top owner to system_monitor;
grant insert on table app_top to system_monitor;
grant select on table app_top to grafana;

-----------------------------------------------------------------------------------
-- fun_top table
-----------------------------------------------------------------------------------
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'fun_type') THEN
        CREATE TYPE fun_type AS
            enum ('initial_call', 'current_function');
    END IF;
END\$\$;

create table if not exists fun_top (
    node text,
    ts timestamp without time zone not null,
    fun text,
    fun_type fun_type,
    num_processes numeric
) partition by range(ts);

alter table fun_top owner to system_monitor;
grant insert on table fun_top to system_monitor;
grant select on table fun_top to grafana;

-----------------------------------------------------------------------------------
-- node_role table
-----------------------------------------------------------------------------------

create table if not exists node_role (
    node text not null,
    ts timestamp without time zone not null,
    data text
) partition by range(ts);

alter table node_role owner to system_monitor;
grant delete on table node_role to system_monitor;
grant select on table node_role to system_monitor;
grant insert on table node_role to system_monitor;
grant select on table node_role to grafana;

create index if not exists node_role_ts_idx on node_role(ts);

-----------------------------------------------------------------------------------
-- node table
-----------------------------------------------------------------------------------

create table if not exists node (
    node text not null primary key
);

alter table node owner to system_monitor;
grant select on table node to system_monitor;
grant insert on table node to system_monitor;
grant select on table node to grafana;

create or replace function update_nodes()
   returns trigger
   language plpgsql as
\$\$
begin
  insert into node(node) values (NEW.node) on conflict do nothing;
  return null;
end;
\$\$;

drop trigger if exists update_nodes_trigger on node_role;
create trigger update_nodes_trigger
       after insert on node_role
       for each row
       execute procedure update_nodes();

EOSQL
