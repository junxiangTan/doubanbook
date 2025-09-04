#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-./pg_diag.txt}"
DB_NAME="${DB_NAME:-osm_global}"

# Execute SQL against PostgreSQL. Prefer sudo to postgres user; fallback to plain psql.
run_sql() {
  local sql="$1"
  if command -v sudo >/dev/null 2>&1 && sudo -n -u postgres command -v psql >/dev/null 2>&1; then
    sudo -n -u postgres psql -X -d "$DB_NAME" -P pager=off -Atc "$sql"
  elif command -v psql >/dev/null 2>&1; then
    psql -X -d "$DB_NAME" -P pager=off -Atc "$sql"
  else
    return 1
  fi
}

{
  echo "== PG/OS DIAG $(date -Is) =="
  echo "---- OS RELEASE ----"; cat /etc/os-release 2>/dev/null || true; echo
  echo "---- KERNEL ----"; uname -a; echo
  echo "---- CPU ----"; lscpu 2>/dev/null || true; echo
  echo "---- MEMORY ----"; free -h 2>/dev/null || true; echo
  echo "---- DISKS ----"; lsblk -o NAME,MODEL,ROTA,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true; echo
  echo "---- SYSCTL ----"; for k in vm.swappiness vm.dirty_ratio vm.dirty_background_ratio vm.dirty_bytes vm.dirty_background_bytes fs.file-max; do printf "%s=%s\n" "$k" "$(sysctl -n "$k" 2>/dev/null || echo N/A)"; done; echo
  echo "---- LIMITS ----"; (ulimit -n || true); echo
  echo "---- POSTGRES ----"; (psql --version || true); (systemctl status postgresql | head -n 80 || service postgresql status || true) | cat; echo

  echo "---- TRY CONNECT ----";
  if run_sql "select version()" >/dev/null 2>&1; then echo "psql ok"; else echo "psql not available or insufficient privileges"; fi; echo

  if run_sql "select 1" >/dev/null 2>&1; then
    echo "---- PG SETTINGS ----";
    run_sql "select name||'='||setting from pg_settings where name in ('data_directory','config_file','hba_file','ident_file','port','max_connections','shared_buffers','effective_cache_size','work_mem','maintenance_work_mem','wal_level','wal_compression','max_wal_size','min_wal_size','checkpoint_timeout','random_page_cost','seq_page_cost','effective_io_concurrency','synchronous_commit','max_worker_processes','max_parallel_workers','max_parallel_workers_per_gather','track_io_timing','shared_preload_libraries','autovacuum','autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay','autovacuum_analyze_scale_factor','autovacuum_vacuum_scale_factor')" || true; echo

    echo "---- PG EXTENSIONS ----";
    run_sql "select extname||' '||extversion from pg_extension order by 1" || true; echo

    echo "---- DB SIZE ----";
    run_sql "select current_database()||' '||pg_size_pretty(pg_database_size(current_database()))" || true; echo

    echo "---- TOP TABLE SIZES ----";
    run_sql "select n.nspname||'.'||c.relname||E'\t'||pg_size_pretty(pg_total_relation_size(c.oid))||E'\t'||pg_size_pretty(pg_relation_size(c.oid))||E'\t'||pg_size_pretty(pg_indexes_size(c.oid)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' order by pg_total_relation_size(c.oid) desc limit 40" || true; echo

    echo "---- GEOMETRY COLUMNS ----";
    run_sql "select n.nspname||'.'||c.relname||E'\t'||a.attname||E'\t'||coalesce(postgis_typmod_srid(a.atttypmod)::text,'?')||E'\t'||coalesce(postgis_typmod_type(a.atttypmod),'?') from pg_attribute a join pg_class c on a.attrelid=c.oid join pg_namespace n on n.oid=c.relnamespace join pg_type t on a.atttypid=t.oid where t.typname='geometry' and a.attnum>0 and not a.attisdropped order by 1,2" || true; echo

    echo "---- MISSING SPATIAL INDEX ----";
    run_sql "with geoms as (select c.oid as relid, n.nspname, c.relname, a.attname from pg_attribute a join pg_class c on a.attrelid=c.oid join pg_namespace n on n.oid=c.relnamespace join pg_type t on a.atttypid=t.oid where t.typname='geometry' and a.attnum>0 and not a.attisdropped) select g.nspname||'.'||g.relname||E'\t'||g.attname from geoms g where not exists (select 1 from pg_index i join pg_class ic on ic.oid=i.indexrelid join pg_am am on am.oid=ic.relam where i.indrelid=g.relid and am.amname in ('gist','spgist')) order by 1" || true; echo

    echo "---- VACUUM/ANALYZE STATS ----";
    run_sql "select schemaname||'.'||relname||E'\t'||coalesce(to_char(last_vacuum,'YYYY-MM-DD HH24:MI'),'')||E'\t'||coalesce(to_char(last_autoanalyze,'YYYY-MM-DD HH24:MI'),'')||E'\t'||n_dead_tup from pg_stat_user_tables order by n_dead_tup desc limit 40" || true; echo

    echo "---- PG_STAT_STATEMENTS ----";
    run_sql "show shared_preload_libraries" || true;
    run_sql "select 'pg_stat_statements installed='||exists(select 1 from pg_extension where extname='pg_stat_statements')::text" || true; echo
    if run_sql "select exists(select 1 from pg_extension where extname='pg_stat_statements')" 2>/dev/null | grep -q t; then
      echo "---- TOP QUERIES BY MEAN TIME ----";
      run_sql "select replace(regexp_replace(query, E'[\n\r\t]+',' ','g'),'  ',' ')||E'\t'||round(mean_time::numeric,2)||' ms'||E'\t'||calls from pg_stat_statements order by mean_time desc limit 20" || true; echo
    fi

    echo "---- LONG RUNNING QUERIES (>5min) ----";
    run_sql "select now()-xact_start as age, usename, datname, state, left(query,200) from pg_stat_activity where state<>'idle' and xact_start is not null and now()-xact_start>interval '5 min' order by xact_start" || true; echo

    echo "---- SEQ SCAN HEAVY TABLES ----";
    run_sql "select relname||E'\t'||seq_scan||E'\t'||idx_scan from pg_stat_user_tables order by seq_scan desc, idx_scan asc limit 20" || true; echo
  else
    echo "psql not available or insufficient privileges; skipping PG sections."; echo
  fi
} > "$OUT" 2>&1

echo "Saved to $OUT"

