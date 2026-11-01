-- MIXE POS: auditable cash inflows/outflows and cash-session reconciliation.
create table if not exists mixe.cash_movements (
  id uuid primary key default gen_random_uuid(),
  cash_session_id uuid not null references mixe.cash_sessions(id),
  direction text not null check (direction in ('in','out')),
  category text not null check (category in ('deposit','change_fund','expense','withdrawal','correction')),
  amount numeric(14,2) not null check (amount > 0),
  notes text not null,
  created_by uuid not null references mixe.staff(id),
  created_at timestamptz not null default now(),
  constraint mixe_cash_movements_direction_category_check check (
    (direction='in' and category in ('deposit','change_fund','correction'))
    or
    (direction='out' and category in ('expense','withdrawal','correction'))
  )
);
alter table mixe.cash_movements enable row level security;
revoke all on mixe.cash_movements from public, anon, authenticated;
grant all on mixe.cash_movements to service_role;
create index if not exists mixe_cash_movements_session_created_idx
  on mixe.cash_movements(cash_session_id, created_at desc);
create index if not exists mixe_cash_movements_created_by_idx
  on mixe.cash_movements(created_by);

create or replace function mixe.mixe_register_cash_movement(
  p_session_id uuid,
  p_direction text,
  p_category text,
  p_amount numeric,
  p_notes text,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session mixe.cash_sessions%rowtype;
  v_movement mixe.cash_movements%rowtype;
  v_cash_sales numeric(14,2);
  v_cash_in numeric(14,2);
  v_cash_out numeric(14,2);
  v_balance numeric(14,2);
  v_notes text;
begin
  if p_session_id is null or p_direction not in ('in','out')
     or p_category not in ('deposit','change_fund','expense','withdrawal','correction')
     or p_amount is null or p_amount <= 0 then
    raise exception using errcode = '22023', message = 'Tipo, concepto o importe de movimiento inválido.';
  end if;
  if not (
    (p_direction='in' and p_category in ('deposit','change_fund','correction'))
    or
    (p_direction='out' and p_category in ('expense','withdrawal','correction'))
  ) then
    raise exception using errcode = '22023', message = 'El concepto no corresponde al tipo de movimiento seleccionado.';
  end if;
  v_notes := nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_notes,'')),500),'');
  if v_notes is null then
    raise exception using errcode = '22023', message = 'Describe el motivo del movimiento de efectivo.';
  end if;
  if p_actor_id is null or not exists (
    select 1 from mixe.staff s where s.id=p_actor_id and s.active=true
  ) then
    raise exception using errcode = '42501', message = 'El empleado no tiene autorización activa.';
  end if;

  select * into v_session from mixe.cash_sessions where id=p_session_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'No encontramos la sesión de caja.'; end if;
  if v_session.closed_at is not null then raise exception using errcode = 'P0001', message = 'La caja ya está cerrada; no admite movimientos.'; end if;

  select coalesce(sum(p.amount+p.tip_amount),0)
  into v_cash_sales
  from mixe.payments p
  where p.cash_session_id=v_session.id and p.status='confirmed' and p.method='cash';

  select
    coalesce(sum(m.amount) filter(where m.direction='in'),0),
    coalesce(sum(m.amount) filter(where m.direction='out'),0)
  into v_cash_in,v_cash_out
  from mixe.cash_movements m where m.cash_session_id=v_session.id;

  v_balance := v_session.opening_float+v_cash_sales+v_cash_in-v_cash_out;
  if p_direction='out' and p_amount>v_balance then
    raise exception using errcode = '22023', message = 'El retiro supera el efectivo disponible en caja ('||v_balance::text||').';
  end if;

  insert into mixe.cash_movements(cash_session_id,direction,category,amount,notes,created_by)
  values(p_session_id,p_direction,p_category,p_amount,v_notes,p_actor_id)
  returning * into v_movement;

  if p_direction='in' then v_cash_in:=v_cash_in+p_amount; else v_cash_out:=v_cash_out+p_amount; end if;
  v_balance:=v_session.opening_float+v_cash_sales+v_cash_in-v_cash_out;

  insert into mixe.audit_events(entity,entity_id,action,actor_id,payload)
  values('cash_movement',v_movement.id,'registered',p_actor_id,
    pg_catalog.jsonb_build_object('cash_session_id',p_session_id,'direction',p_direction,'category',p_category,'amount',p_amount,'cash_balance',v_balance));

  return pg_catalog.jsonb_build_object('ok',true,'movement',pg_catalog.to_jsonb(v_movement),'cashBalance',v_balance);
end;
$$;

revoke all on function mixe.mixe_register_cash_movement(uuid,text,text,numeric,text,uuid) from public,anon,authenticated;
grant execute on function mixe.mixe_register_cash_movement(uuid,text,text,numeric,text,uuid) to service_role;

create or replace function mixe.mixe_close_cash_session(
  p_session_id uuid,
  p_closing_cash numeric,
  p_notes text,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session mixe.cash_sessions%rowtype;
  v_was_closed boolean;
  v_payment_count integer;
  v_sales numeric(14,2);
  v_tips numeric(14,2);
  v_cash numeric(14,2);
  v_cash_in numeric(14,2);
  v_cash_out numeric(14,2);
  v_card numeric(14,2);
  v_codi numeric(14,2);
  v_transfer numeric(14,2);
  v_online numeric(14,2);
  v_expected numeric(14,2);
  v_difference numeric(14,2);
  v_summary jsonb;
begin
  if p_session_id is null or p_closing_cash is null or p_closing_cash < 0 then
    raise exception using errcode = '22023', message = 'Captura el efectivo contado y una sesión válida.';
  end if;
  if p_actor_id is null or not exists (
    select 1 from mixe.staff s where s.id=p_actor_id and s.active=true
  ) then
    raise exception using errcode = '42501', message = 'El empleado no tiene autorización activa.';
  end if;

  select * into v_session from mixe.cash_sessions where id=p_session_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'No encontramos la sesión de caja.'; end if;

  v_was_closed := v_session.closed_at is not null;
  if v_was_closed and v_session.closing_cash is distinct from p_closing_cash then
    raise exception using errcode = 'P0001', message = 'La caja ya fue cerrada con otro importe contado.';
  end if;

  select
    count(*)::integer,
    coalesce(sum(p.amount),0),
    coalesce(sum(p.tip_amount),0),
    coalesce(sum(case when p.method='cash' then p.amount+p.tip_amount else 0 end),0),
    coalesce(sum(case when p.method='card' then p.amount+p.tip_amount else 0 end),0),
    coalesce(sum(case when p.method='codi' then p.amount+p.tip_amount else 0 end),0),
    coalesce(sum(case when p.method='transfer' then p.amount+p.tip_amount else 0 end),0),
    coalesce(sum(case when p.method='online' then p.amount+p.tip_amount else 0 end),0)
  into v_payment_count,v_sales,v_tips,v_cash,v_card,v_codi,v_transfer,v_online
  from mixe.payments p
  where p.cash_session_id=v_session.id and p.status='confirmed';

  select
    coalesce(sum(m.amount) filter(where m.direction='in'),0),
    coalesce(sum(m.amount) filter(where m.direction='out'),0)
  into v_cash_in,v_cash_out
  from mixe.cash_movements m where m.cash_session_id=v_session.id;

  v_expected:=v_session.opening_float+v_cash+v_cash_in-v_cash_out;

  if not v_was_closed then
    v_difference:=p_closing_cash-v_expected;
    update mixe.cash_sessions
    set closing_cash=p_closing_cash,
        closed_at=pg_catalog.now(),
        notes=coalesce(nullif(pg_catalog.left(coalesce(p_notes,''),500),''),v_session.notes),
        closed_by=p_actor_id
    where id=p_session_id returning * into v_session;

    insert into mixe.audit_events(entity,entity_id,action,actor_id,payload)
    values('cash_session',p_session_id,'close',p_actor_id,
      pg_catalog.jsonb_build_object(
        'opening_float',v_session.opening_float,'cash_receipts',v_cash,
        'cash_in',v_cash_in,'cash_out',v_cash_out,'expected_cash',v_expected,
        'closing_cash',p_closing_cash,'difference',v_difference,'sales',v_sales,
        'tips',v_tips,'payment_count',v_payment_count,'card',v_card,
        'codi',v_codi,'transfer',v_transfer,'online',v_online
      ));
  else
    v_difference:=v_session.closing_cash-v_expected;
  end if;

  v_summary:=pg_catalog.jsonb_build_object(
    'sales',v_sales,'tips',v_tips,'cash',v_cash,'cashIn',v_cash_in,'cashOut',v_cash_out,
    'card',v_card,'codi',v_codi,'transfer',v_transfer,'online',v_online,
    'expectedCash',v_expected,'closingCash',v_session.closing_cash,
    'difference',v_difference,'paymentCount',v_payment_count
  );

  return pg_catalog.jsonb_build_object('ok',true,'session',pg_catalog.to_jsonb(v_session),'summary',v_summary,'idempotent',v_was_closed);
end;
$$;
