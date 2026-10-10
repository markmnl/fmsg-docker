\connect fmsgid

/****************************************************************
 *
 * PostgreSQL database objects data definition for fmsgid
 *
 * This script is IDEMPOTENT: every statement is safe to re-run
 * (create table/index if not exists; do blocks that check the
 * catalog first; alter table set storage parameters simply
 * reapplies). Migrating an existing database is
 * therefore just re-running the whole script, e.g.:
 *
 *   psql -d fmsgid -v ON_ERROR_STOP=1 -f dd.sql
 *
 * Keep it that way: add new objects and columns only with
 * idempotent statements.
 *
 ****************************************************************/

-- database with encoding UTF8 should already be created and connected

create table if not exists address (
    address_lower               text 	primary key,
    address 					text 	not null,
    display_name 				text,
    accepting_new 				bool	not null default true,
    limit_recv_size_total 		bigint	not null default 102400000,
    limit_recv_size_per_msg 	bigint	not null default 10240,
    limit_recv_size_per_1d 		bigint	not null default 102400,
    limit_recv_count_per_1d 	bigint	not null default 1000,
    limit_send_size_total 		bigint	not null default 102400000,
    limit_send_size_per_msg 	bigint	not null default 10240,
    limit_send_size_per_1d 		bigint	not null default 102400,
    limit_send_count_per_1d 	bigint	not null default 1000
);

-- quota pools: an address whose quota_pool is set (to the address_lower of
-- another address, the pool owner) shares the pool owner's quota: it is
-- checked against the owner's limits and the combined usage of the owner and
-- every address whose quota_pool is the owner. NULL means the address is its
-- own pool; the owner's usage includes its pool members' too. Pools are one
-- level deep, so a pool owner's own quota_pool should be NULL. A nullable
-- column without a default is added without rewriting the table.
alter table address add column if not exists quota_pool text;

do $$
begin
	if not exists (select 1 from pg_constraint
			where conrelid = 'address'::regclass and conname = 'address_quota_pool_fkey') then
		alter table address add constraint address_quota_pool_fkey
			foreign key (quota_pool) references address (address_lower) on delete set null;
	end if;
end $$;

create index if not exists address_quota_pool on address (quota_pool);

-- one row per message sent or received; several may share a timestamp
create table if not exists address_tx (
	id		bigserial			primary key,
	address_lower	text		not null references address (address_lower) ,
	ts		timestamptz			not null,
	type	smallint			not null, -- 1 for recv, 2 for send
	size	int					not null
);

-- migrate address_tx created with primary key (address_lower, ts), which
-- rejected a second message to an address with the same timestamp: give it a
-- surrogate id key instead. The column is added inside the do block, not with
-- add column if not exists, because older PostgreSQL versions create an
-- orphan sequence for a serial column even when the column already exists.
do $$
declare
	pk name;
begin
	if not exists (select 1 from pg_attribute
			where attrelid = 'address_tx'::regclass and attname = 'id' and not attisdropped) then
		alter table address_tx add column id bigserial;
	end if;
	select c.conname into pk
	from pg_constraint c
	join pg_attribute a on a.attrelid = c.conrelid and a.attname = 'id'
	where c.conrelid = 'address_tx'::regclass
		and c.contype = 'p'
		and c.conkey <> array[a.attnum];
	if pk is not null then
		execute format('alter table address_tx drop constraint %I', pk);
	end if;
	if not exists (select 1 from pg_constraint
			where conrelid = 'address_tx'::regclass and contype = 'p') then
		alter table address_tx add primary key (id);
	end if;
end $$;

create index if not exists address_tx_addr_type_ts
on address_tx (address_lower, type, ts desc);

alter table address_tx set (
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_analyze_scale_factor = 0.01
);
