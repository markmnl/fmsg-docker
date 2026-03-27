\connect fmsgid

/****************************************************************
 *
 * PostgreSQL database objects data definition for fmsgid
 *
 ****************************************************************/

-- database with encoding UTF8 should already be created and connected

create table if not exists address (
    address_lower               text 	primary key,
    address 					text 	not null,
    display_name 				text,
    accepting_new 				bool	not null default true,
    limit_recv_size_total 		bigint	not null default -1,
    limit_recv_size_per_msg 	bigint	not null default -1,
    limit_recv_size_per_1d 		bigint	not null default -1,
    limit_recv_count_per_1d 	bigint	not null default -1,
    limit_send_size_total 		bigint	not null default -1,
    limit_send_size_per_msg 	bigint	not null default -1,
    limit_send_size_per_1d 		bigint	not null default -1,
    limit_send_count_per_1d 	bigint	not null default -1
);

create table if not exists address_tx (
	address_lower	text		not null references address (address_lower) ,
	ts		timestamptz			not null,
	type	smallint			not null, -- 1 for recv, 2 for send
	size	int					not null,
	primary key (address_lower, ts)
);

create index address_tx_addr_type_ts
on address_tx (address_lower, type, ts desc);

alter table address_tx set (
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_analyze_scale_factor = 0.01
);
