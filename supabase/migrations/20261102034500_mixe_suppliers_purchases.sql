-- MIXE suppliers and multi-line purchases with moving weighted average inventory cost
create table if not exists mixe.suppliers(id uuid primary key default gen_random_uuid(),name text not null unique,tax_id text,phone text,active boolean not null default true,created_at timestamptz not null default now());
create table if not exists mixe.purchases(id uuid primary key default gen_random_uuid(),supplier_id uuid not null references mixe.suppliers(id),invoice_ref text,purchased_at timestamptz not null default now(),created_by uuid not null references mixe.staff(id),created_at timestamptz not null default now(),total numeric(14,2) not null default 0 check(total>=0));
create table if not exists mixe.purchase_items(id uuid primary key default gen_random_uuid(),purchase_id uuid not null references mixe.purchases(id),ingredient_id uuid not null references mixe.ingredients(id),quantity numeric(14,3) not null check(quantity>0),unit_cost numeric(14,4) not null check(unit_cost>=0),line_total numeric(14,2) not null check(line_total>=0),old_avg_cost numeric(14,4) not null,new_avg_cost numeric(14,4) not null);
alter table mixe.suppliers enable row level security;
alter table mixe.purchases enable row level security;
alter table mixe.purchase_items enable row level security;
revoke all on mixe.suppliers,mixe.purchases,mixe.purchase_items from public,anon,authenticated;
grant all on mixe.suppliers,mixe.purchases,mixe.purchase_items to service_role;
create index if not exists mixe_purchases_supplier_date_idx on mixe.purchases(supplier_id,purchased_at desc);
create index if not exists mixe_purchase_items_purchase_idx on mixe.purchase_items(purchase_id);
create index if not exists mixe_purchase_items_ingredient_idx on mixe.purchase_items(ingredient_id);
create or replace function mixe.record_purchase(p_supplier uuid,p_invoice text,p_items jsonb,p_actor uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_purchase uuid;v_line jsonb;v_ingredient mixe.ingredients%rowtype;v_qty numeric;v_cost numeric;v_new numeric;v_total numeric:=0;v_count int:=0;
begin
if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>50 then raise exception 'Agrega de 1 a 50 insumos';end if;
if not exists(select 1 from mixe.suppliers where id=p_supplier and active) then raise exception 'Proveedor inválido';end if;
if not exists(select 1 from mixe.staff where id=p_actor and active and role in ('admin','manager')) then raise exception 'Responsable no autorizado';end if;
insert into mixe.purchases(supplier_id,invoice_ref,created_by) values(p_supplier,nullif(left(btrim(coalesce(p_invoice,'')),120),''),p_actor) returning id into v_purchase;
for v_line in select value from jsonb_array_elements(p_items) loop
v_qty:=(v_line->>'quantity')::numeric;v_cost:=(v_line->>'unit_cost')::numeric;
if v_qty is null or v_qty<=0 or v_cost is null or v_cost<0 or v_qty>1000000 then raise exception 'Cantidad o precio inválidos';end if;
select * into v_ingredient from mixe.ingredients where id=(v_line->>'ingredient_id')::uuid and active for update;
if not found then raise exception 'Insumo inválido';end if;
v_new:=round(((v_ingredient.on_hand*v_ingredient.unit_cost)+(v_qty*v_cost))/(v_ingredient.on_hand+v_qty),4);
update mixe.ingredients set on_hand=on_hand+v_qty,unit_cost=v_new where id=v_ingredient.id;
insert into mixe.purchase_items(purchase_id,ingredient_id,quantity,unit_cost,line_total,old_avg_cost,new_avg_cost) values(v_purchase,v_ingredient.id,v_qty,v_cost,round(v_qty*v_cost,2),v_ingredient.unit_cost,v_new);
insert into mixe.stock_movements(ingredient_id,quantity_delta,reason,unit_cost_snapshot) values(v_ingredient.id,v_qty,'purchase',v_cost);
v_total:=v_total+round(v_qty*v_cost,2);v_count:=v_count+1;
end loop;
update mixe.purchases set total=v_total where id=v_purchase;
return jsonb_build_object('purchase_id',v_purchase,'total',v_total,'lines',v_count);
end $$;
revoke all on function mixe.record_purchase(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function mixe.record_purchase(uuid,text,jsonb,uuid) to service_role;