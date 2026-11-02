-- MIXE split accounts and partial payments per person.
create table if not exists mixe.order_splits (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references mixe.orders(id) on delete cascade,
 label text not null check(length(btrim(label)) between 1 and 80),
 amount_due numeric(14,2) not null check(amount_due>0),
 status text not null default 'open' check(status in ('open','partial','paid')),
 created_by uuid not null references mixe.staff(id),
 created_at timestamptz not null default now(),
 unique(order_id,label)
);
alter table mixe.payments add column if not exists split_id uuid references mixe.order_splits(id);
create index if not exists mixe_order_splits_order_idx on mixe.order_splits(order_id,created_at);
create index if not exists mixe_order_splits_created_by_idx on mixe.order_splits(created_by);
create index if not exists mixe_payments_split_status_idx on mixe.payments(split_id,status,created_at);
alter table mixe.order_splits enable row level security;
revoke all on mixe.order_splits from public,anon,authenticated;
grant all on mixe.order_splits to service_role;

create or replace function mixe.mixe_create_equal_splits(p_order_id uuid,p_count integer,p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order mixe.orders%rowtype;v_base_cents bigint;v_remainder bigint;v_total_cents bigint;v_amount numeric(14,2);v_id uuid;v_rows jsonb:='[]'::jsonb;i integer;
begin
 if p_order_id is null or p_count is null or p_count<2 or p_count>12 then raise exception using errcode='22023',message='Divide la cuenta entre 2 y 12 personas.';end if;
 if p_actor_id is null or not exists(select 1 from mixe.staff where id=p_actor_id and active) then raise exception using errcode='42501',message='El empleado no tiene autorización activa.';end if;
 select * into v_order from mixe.orders where id=p_order_id for update;
 if not found then raise exception using errcode='P0002',message='No encontramos la cuenta.';end if;
 if v_order.status in ('closed','cancelled') or v_order.payment_status<>'unpaid' then raise exception using errcode='P0001',message='Solo puedes dividir una cuenta abierta que todavía no tenga pagos.';end if;
 if exists(select 1 from mixe.payments where order_id=p_order_id) then raise exception using errcode='P0001',message='La cuenta ya tiene movimientos de pago. No se puede dividir después de cobrar.';end if;
 if exists(select 1 from mixe.order_splits where order_id=p_order_id) then raise exception using errcode='23505',message='Esta cuenta ya está dividida.';end if;
 if v_order.total<=0 or not exists(select 1 from mixe.order_items where order_id=p_order_id and status<>'void') then raise exception using errcode='22023',message='La cuenta no tiene productos cobrables.';end if;
 v_total_cents:=round(v_order.total*100)::bigint;v_base_cents:=v_total_cents/p_count;v_remainder:=mod(v_total_cents,p_count);
 for i in 1..p_count loop
  v_amount:=(v_base_cents+case when i<=v_remainder then 1 else 0 end)::numeric/100;
  insert into mixe.order_splits(order_id,label,amount_due,created_by) values(p_order_id,'Persona '||i,v_amount,p_actor_id) returning id into v_id;
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object('id',v_id,'label','Persona '||i,'amount_due',v_amount,'status','open'));
 end loop;
 return jsonb_build_object('ok',true,'order_id',p_order_id,'count',p_count,'total',v_order.total,'splits',v_rows);
end $$;

create or replace function mixe.mixe_pay_split_account(p_split_id uuid,p_method text,p_amount numeric,p_tip_amount numeric,p_provider_reference text,p_idempotency_key uuid,p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_split mixe.order_splits%rowtype;v_order mixe.orders%rowtype;v_session mixe.cash_sessions%rowtype;v_existing mixe.payments%rowtype;v_payment mixe.payments%rowtype;v_paid numeric(14,2);v_due numeric(14,2);v_new_paid numeric(14,2);v_order_paid numeric(14,2);v_closed boolean;v_other_count integer;
begin
 if p_split_id is null or p_idempotency_key is null then raise exception using errcode='22023',message='Falta la cuenta dividida o la clave única del pago.';end if;
 if p_method not in ('cash','card','codi','transfer','online') or p_amount is null or p_amount<=0 or p_tip_amount is null or p_tip_amount<0 or p_tip_amount>p_amount then raise exception using errcode='22023',message='Pago o propina inválidos.';end if;
 if p_actor_id is null or not exists(select 1 from mixe.staff where id=p_actor_id and active) then raise exception using errcode='42501',message='El empleado no tiene autorización activa.';end if;
 select o.* into v_order from mixe.orders o join mixe.order_splits s on s.order_id=o.id where s.id=p_split_id for update of o;
 if not found then raise exception using errcode='P0002',message='No encontramos la cuenta dividida.';end if;
 select * into v_split from mixe.order_splits where id=p_split_id for update;
 select * into v_existing from mixe.payments where idempotency_key=p_idempotency_key;
 if found then
  if v_existing.order_id is distinct from v_order.id or v_existing.split_id is distinct from p_split_id or v_existing.method is distinct from p_method or v_existing.amount is distinct from p_amount or v_existing.tip_amount is distinct from p_tip_amount or v_existing.provider_reference is distinct from nullif(p_provider_reference,'') then raise exception using errcode='23505',message='La clave de intento ya se utilizó con datos diferentes.';end if;
  select coalesce(sum(amount),0) into v_paid from mixe.payments where split_id=p_split_id and status='confirmed';
  return jsonb_build_object('payment',to_jsonb(v_existing),'split_id',p_split_id,'paid',v_paid,'due',greatest(0,v_split.amount_due-v_paid),'total',v_split.amount_due,'closed',v_split.status='paid','idempotent',true);
 end if;
 if v_order.status in ('closed','cancelled') then raise exception using errcode='P0001',message='La cuenta general ya está cerrada o cancelada.';end if;
 select coalesce(sum(amount),0) into v_paid from mixe.payments where split_id=p_split_id and status='confirmed';v_due:=greatest(0,v_split.amount_due-v_paid);
 if v_due<=0.009 then raise exception using errcode='P0001',message='Esta cuenta dividida ya está liquidada.';end if;
 if p_amount>v_due+0.009 then raise exception using errcode='22023',message='El pago supera el saldo de esta persona.';end if;
 select * into v_session from mixe.cash_sessions where closed_at is null order by opened_at desc limit 1 for update;
 if not found then raise exception using errcode='P0001',message='No hay una caja abierta. Abre caja antes de registrar pagos.';end if;
 select * into v_existing from mixe.payments where idempotency_key=p_idempotency_key;
 if found then
  if v_existing.order_id is distinct from v_order.id or v_existing.split_id is distinct from p_split_id or v_existing.method is distinct from p_method or v_existing.amount is distinct from p_amount or v_existing.tip_amount is distinct from p_tip_amount or v_existing.provider_reference is distinct from nullif(p_provider_reference,'') then raise exception using errcode='23505',message='La clave de intento ya se utilizó con datos diferentes.';end if;
  select coalesce(sum(amount),0) into v_paid from mixe.payments where split_id=p_split_id and status='confirmed';
  return jsonb_build_object('payment',to_jsonb(v_existing),'split_id',p_split_id,'paid',v_paid,'due',greatest(0,v_split.amount_due-v_paid),'total',v_split.amount_due,'closed',v_split.status='paid','idempotent',true);
 end if;
 insert into mixe.payments(order_id,split_id,cash_session_id,amount,tip_amount,method,status,provider_reference,confirmed_at,idempotency_key)
 values(v_order.id,p_split_id,v_session.id,p_amount,p_tip_amount,p_method,'confirmed',nullif(p_provider_reference,''),now(),p_idempotency_key) returning * into v_payment;
 v_new_paid:=v_paid+p_amount;
 update mixe.order_splits set status=case when v_new_paid+0.009>=v_split.amount_due then 'paid' else 'partial' end where id=p_split_id;
 select coalesce(sum(amount),0) into v_order_paid from mixe.payments where order_id=v_order.id and status='confirmed';v_closed:=v_order_paid+0.009>=v_order.total;
 update mixe.orders set payment_status=case when v_closed then 'paid' when v_order_paid>0 then 'partial' else 'unpaid' end,status=case when v_closed then 'closed' else status end,closed_at=case when v_closed then now() else null end,updated_at=now() where id=v_order.id;
 if v_closed and v_order.table_id is not null then
  select count(*) into v_other_count from mixe.orders o where o.table_id=v_order.table_id and o.id<>v_order.id and o.status in ('pending_confirmation','open','sent','preparing','ready','served');
  if v_other_count=0 then update mixe.tables set status='free' where id=v_order.table_id;end if;
 end if;
 if v_closed and v_order.public_client_token is not null and not exists(select 1 from mixe.orders o where o.public_client_token=v_order.public_client_token and o.status in ('pending_confirmation','open','sent','preparing','ready','served')) then
  update mixe.orders set public_client_token=null,updated_at=now() where public_client_token=v_order.public_client_token;
 end if;
 insert into mixe.audit_events(entity,entity_id,action,actor_id,payload) values('payment',v_payment.id,'confirmed',p_actor_id,jsonb_build_object('order_id',v_order.id,'split_id',p_split_id,'cash_session_id',v_session.id,'amount',p_amount,'tip_amount',p_tip_amount,'method',p_method,'idempotency_key',p_idempotency_key));
 return jsonb_build_object('payment',to_jsonb(v_payment),'split_id',p_split_id,'paid',v_new_paid,'due',greatest(0,v_split.amount_due-v_new_paid),'total',v_split.amount_due,'tip_amount',p_tip_amount,'total_received',p_amount+p_tip_amount,'closed',v_closed,'idempotent',false);
end $$;

create or replace function mixe.guard_split_payment()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from mixe.order_splits where order_id=new.order_id) then
  if new.split_id is null or not exists(select 1 from mixe.order_splits where id=new.split_id and order_id=new.order_id) then raise exception using errcode='23514',message='Esta cuenta está dividida. Registra el pago en una cuenta de persona.';end if;
 elsif new.split_id is not null then raise exception using errcode='23514',message='La cuenta no tiene división activa.';
 end if;
 return new;
end $$;
revoke all on function mixe.guard_split_payment() from public,anon,authenticated;
drop trigger if exists trg_guard_split_payment on mixe.payments;
create trigger trg_guard_split_payment before insert or update of order_id,split_id on mixe.payments for each row execute function mixe.guard_split_payment();

create or replace function mixe.guard_split_order_items()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_order uuid;
begin
 if tg_op='INSERT' then
  if exists(select 1 from mixe.order_splits where order_id=new.order_id) then raise exception using errcode='23514',message='La cuenta ya está dividida. Cancela la división antes de agregar productos.';end if;
  return new;
 elsif tg_op='DELETE' then
  if exists(select 1 from mixe.order_splits where order_id=old.order_id) then raise exception using errcode='23514',message='La cuenta ya está dividida. Cancela la división antes de quitar productos.';end if;
  return old;
 else
  if exists(select 1 from mixe.order_splits where order_id=old.order_id or order_id=new.order_id)
   and (old.order_id is distinct from new.order_id or old.product_id is distinct from new.product_id or old.quantity is distinct from new.quantity or old.unit_price is distinct from new.unit_price or new.status='void') then
   raise exception using errcode='23514',message='La cuenta ya está dividida. No puedes modificar o cancelar productos hasta cancelar la división sin pagos.';
  end if;
  return new;
 end if;
end $$;
revoke all on function mixe.guard_split_order_items() from public,anon,authenticated;
drop trigger if exists trg_guard_split_order_items on mixe.order_items;
create trigger trg_guard_split_order_items before insert or update or delete on mixe.order_items for each row execute function mixe.guard_split_order_items();

create or replace function mixe.mixe_cancel_order_splits(p_order_id uuid,p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
 if not exists(select 1 from mixe.orders where id=p_order_id for update) then raise exception using errcode='P0002',message='No encontramos la cuenta.';end if;
 if not exists(select 1 from mixe.staff where id=p_actor_id and active and role in ('admin','manager','cashier','server')) then raise exception using errcode='42501',message='No tienes autorización para cancelar la división.';end if;
 if exists(select 1 from mixe.payments where order_id=p_order_id) then raise exception using errcode='P0001',message='No puedes cancelar la división después de registrar un pago.';end if;
 delete from mixe.order_splits where order_id=p_order_id;get diagnostics v_count=row_count;
 return jsonb_build_object('ok',true,'cancelled_splits',v_count);
end $$;

revoke all on function mixe.mixe_create_equal_splits(uuid,integer,uuid) from public,anon,authenticated;
revoke all on function mixe.mixe_pay_split_account(uuid,text,numeric,numeric,text,uuid,uuid) from public,anon,authenticated;
revoke all on function mixe.mixe_cancel_order_splits(uuid,uuid) from public,anon,authenticated;
grant execute on function mixe.mixe_create_equal_splits(uuid,integer,uuid) to service_role;
grant execute on function mixe.mixe_pay_split_account(uuid,text,numeric,numeric,text,uuid,uuid) to service_role;
grant execute on function mixe.mixe_cancel_order_splits(uuid,uuid) to service_role;
