-- Space Buro Project Cloud — Phase 1.9 post-frontend security cutover
--
-- Run this migration only after phase1_9_project_control.sql is installed and
-- the Phase 1.9 frontend has been published and verified. The new frontend
-- reads the secure *_v19 views and uses Prefer: return=minimal for protected
-- base-table writes. This separate, idempotent cutover prevents the Phase 1.8
-- frontend from losing its legacy SELECT access during a rolling deployment.

-- The secure views execute under their owner, but every view contains an
-- explicit organization/project predicate and role-based field masking. This
-- setting is repeated here so a partially rerun earlier migration cannot leave
-- one of the views in security-invoker mode after base access is revoked.
alter view public.projects_secure_v19 set (security_invoker=false,security_barrier=true);
alter view public.materials_secure_v19 set (security_invoker=false,security_barrier=true);
alter view public.warehouse_stock_secure_v19 set (security_invoker=false,security_barrier=true);
alter view public.warehouse_documents_secure_v19 set (security_invoker=false,security_barrier=true);
alter view public.warehouse_document_items_secure_v19 set (security_invoker=false,security_barrier=true);

grant select on public.projects_secure_v19,public.materials_secure_v19,
  public.warehouse_stock_secure_v19,public.warehouse_documents_secure_v19,
  public.warehouse_document_items_secure_v19 to authenticated;

-- Remove direct API reads from cost-bearing legacy relations. Revoking both
-- relation- and column-level privileges closes grants left by older phases.
-- SELECT(id) is intentionally retained on writable base tables because
-- PostgREST needs the filter column for PATCH/DELETE by primary key; all actual
-- reads must use the secure views above.
do $$
declare r record;v_columns text;
begin
  for r in select * from (values
    ('projects',true),
    ('materials',true),
    ('warehouse_documents',true),
    ('warehouse_document_items',true),
    ('warehouse_stock',false)
  ) as x(relation_name,retain_id) loop
    select string_agg(format('%I',column_name),',' order by ordinal_position)
      into v_columns
      from information_schema.columns
      where table_schema='public' and table_name=r.relation_name;
    if v_columns is null then
      raise exception 'Required relation public.% is missing; install Phase 1.9 first',r.relation_name;
    end if;
    execute format('revoke select on table public.%I from public,anon,authenticated',r.relation_name);
    execute format('revoke select (%s) on table public.%I from public,anon,authenticated',v_columns,r.relation_name);
    if r.retain_id then
      execute format('grant select (id) on table public.%I to authenticated',r.relation_name);
    end if;
  end loop;
end
$$;

-- The stock ledger is append-only system output. Authenticated clients post
-- and reverse warehouse documents through SECURITY DEFINER functions; they may
-- no longer insert, edit or delete ledger rows directly.
drop policy if exists stock_movements_phase19_insert on public.stock_movements;
revoke insert,update,delete on table public.stock_movements from public,anon,authenticated;

do $$
declare v_columns text;
begin
  select string_agg(format('%I',column_name),',' order by ordinal_position)
    into v_columns
    from information_schema.columns
    where table_schema='public' and table_name='stock_movements';
  if v_columns is null then raise exception 'Required table public.stock_movements is missing';end if;
  execute format('revoke insert (%s),update (%s) on table public.stock_movements from public,anon,authenticated',
    v_columns,v_columns);
end
$$;

-- Defense in depth for privileged SQL callers: even a caller that later
-- receives table INSERT cannot create a movement without a warehouse document.
-- post_warehouse_document(), reverse_warehouse_document_v19() and the automatic
-- reserve-release trigger always propagate warehouse_document_id.
create or replace function public.reject_undocumented_stock_movement_v19()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if new.warehouse_document_id is null then
    raise exception 'Stock movements require a posted warehouse document';
  end if;
  return new;
end;
$$;

drop trigger if exists stock_movements_require_document_v19 on public.stock_movements;
create trigger stock_movements_require_document_v19
before insert on public.stock_movements
for each row execute function public.reject_undocumented_stock_movement_v19();

-- Keep the only supported ledger mutations explicit after any legacy grants.
grant execute on function public.post_warehouse_document(uuid) to authenticated;
grant execute on function public.reverse_warehouse_document_v19(uuid,text) to authenticated;

-- Fail the migration if an older grant still exposes a protected value or a
-- direct ledger write. These assertions are safe and idempotent.
do $$
begin
  if has_column_privilege('authenticated','public.projects','budget','select')
    or has_column_privilege('authenticated','public.materials','purchase_price','select')
    or has_column_privilege('authenticated','public.warehouse_documents','total_cost','select')
    or has_column_privilege('authenticated','public.warehouse_document_items','unit_cost','select') then
    raise exception 'Phase 1.9 privacy cutover failed: a sensitive base column is still readable';
  end if;
  if not has_column_privilege('authenticated','public.projects','id','select')
    or not has_column_privilege('authenticated','public.materials','id','select')
    or not has_column_privilege('authenticated','public.warehouse_documents','id','select')
    or not has_column_privilege('authenticated','public.warehouse_document_items','id','select') then
    raise exception 'Phase 1.9 privacy cutover failed: protected writes lost SELECT(id)';
  end if;
  if has_table_privilege('authenticated','public.stock_movements','insert')
    or has_table_privilege('authenticated','public.stock_movements','update')
    or has_table_privilege('authenticated','public.stock_movements','delete') then
    raise exception 'Phase 1.9 stock cutover failed: direct ledger DML is still granted';
  end if;
end
$$;

notify pgrst,'reload schema';

-- End Phase 1.9 post-frontend security cutover.
