-- MIXE POS: atomic opening/closing and idempotent payment registration.
-- Functions run as definer with an empty search_path; all table references are schema-qualified.
create or replace function mixe.mixe_open_cash_session(
  p_opening_float numeric,
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
begin
  if p_opening_float is null or p_opening_float < 0 then
    raise exception using errcode = '22023', message = 'El fondo inicial debe ser un importe válido igual o mayor que cero.';
  end if;
  if p_actor_id is null or not exists (
    select 1 from mixe.staff s where s.id = p_actor_id and s.active = true
  ) then
    raise exception using errcode = '42501', message = 'El empleado no tiene autorización activa.';
  end if;

  insert into mixe.cash_sessions (opening_float, notes, opened_by)
  values (p_opening_float, nullif(pg_catalog.left(coalesce(p_notes, ''), 500), ''), p_actor_id)
  returning * into v_session;

  insert into mixe.audit_events (entity, entity_id, action, actor_id, payload)
  values ('cash_session', v_session.id, 'open', p_actor_id,
    pg_catalog.jsonb_build_object('opening_float', v_session.opening_float));

  return pg_catalog.jsonb_build_object('ok', true, 'session', pg_catalog.to_jsonb(v_session));
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'Ya existe una caja abierta. Realiza el corte antes de abrir otra.';
end;
$$;

create or replace function mixe.mixe_pay_order(
  p_order_id uuid,
  p_method text,
  p_amount numeric,
  p_tip_amount numeric,
  p_provider_reference text,
  p_idempotency_key uuid,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order mixe.orders%rowtype;
  v_session mixe.cash_sessions%rowtype;
  v_existing mixe.payments%rowtype;
  v_payment mixe.payments%rowtype;
  v_paid numeric(14,2);
  v_due numeric(14,2);
  v_new_paid numeric(14,2);
  v_closed boolean;
  v_other_count integer;
begin
  if p_order_id is null or p_idempotency_key is null then
    raise exception using errcode = '22023', message = 'Falta la cuenta o la clave única del intento de pago.';
  end if;
  if p_method is null or p_method not in ('cash', 'card', 'codi', 'transfer', 'online')
     or p_amount is null or p_amount <= 0
     or p_tip_amount is null or p_tip_amount < 0 or p_tip_amount > p_amount then
    raise exception using errcode = '22023', message = 'Pago o propina inválidos.';
  end if;
  if p_actor_id is null or not exists (
    select 1 from mixe.staff s where s.id = p_actor_id and s.active = true
  ) then
    raise exception using errcode = '42501', message = 'El empleado no tiene autorización activa.';
  end if;

  select * into v_order
  from mixe.orders
  where id = p_order_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'No encontramos la cuenta indicada.';
  end if;

  -- A retry with the same key returns the original payment, even if the order is now closed.
  select * into v_existing
  from mixe.payments
  where idempotency_key = p_idempotency_key;
  if found then
    if v_existing.order_id is distinct from p_order_id
       or v_existing.method is distinct from p_method
       or v_existing.amount is distinct from p_amount
       or v_existing.tip_amount is distinct from p_tip_amount
       or v_existing.provider_reference is distinct from nullif(p_provider_reference, '') then
      raise exception using errcode = '23505', message = 'La clave de intento ya fue utilizada con datos diferentes.';
    end if;
    select coalesce(sum(p.amount), 0) into v_paid
    from mixe.payments p
    where p.order_id = p_order_id and p.status = 'confirmed';
    return pg_catalog.jsonb_build_object(
      'payment', pg_catalog.to_jsonb(v_existing),
      'paid', v_paid,
      'due', greatest(0, v_order.total - v_paid),
      'tip_amount', v_existing.tip_amount,
      'total_received', v_existing.amount + v_existing.tip_amount,
      'total', v_order.total,
      'closed', v_order.payment_status = 'paid',
      'idempotent', true
    );
  end if;

  if v_order.status in ('closed', 'cancelled') or v_order.payment_status = 'paid' then
    raise exception using errcode = 'P0001', message = 'La cuenta ya está cerrada o cancelada.';
  end if;

  -- Serialize payments against the active session; close locks the same row.
  select * into v_session
  from mixe.cash_sessions
  where closed_at is null
  order by opened_at desc
  limit 1
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'No hay una caja abierta. Abre caja antes de registrar pagos.';
  end if;

  -- Recheck after obtaining the session lock to cover concurrent requests.
  select * into v_existing
  from mixe.payments
  where idempotency_key = p_idempotency_key;
  if found then
    if v_existing.order_id is distinct from p_order_id
       or v_existing.method is distinct from p_method
       or v_existing.amount is distinct from p_amount
       or v_existing.tip_amount is distinct from p_tip_amount
       or v_existing.provider_reference is distinct from nullif(p_provider_reference, '') then
      raise exception using errcode = '23505', message = 'La clave de intento ya fue utilizada con datos diferentes.';
    end if;
    select coalesce(sum(p.amount), 0) into v_paid
    from mixe.payments p
    where p.order_id = p_order_id and p.status = 'confirmed';
    return pg_catalog.jsonb_build_object(
      'payment', pg_catalog.to_jsonb(v_existing),
      'paid', v_paid,
      'due', greatest(0, v_order.total - v_paid),
      'tip_amount', v_existing.tip_amount,
      'total_received', v_existing.amount + v_existing.tip_amount,
      'total', v_order.total,
      'closed', v_order.payment_status = 'paid',
      'idempotent', true
    );
  end if;

  select coalesce(sum(p.amount), 0) into v_paid
  from mixe.payments p
  where p.order_id = p_order_id and p.status = 'confirmed';
  v_due := greatest(0, v_order.total - v_paid);
  if p_amount > v_due + 0.009 then
    raise exception using errcode = '22023', message = 'El pago supera el saldo pendiente.';
  end if;

  insert into mixe.payments (
    order_id, cash_session_id, amount, tip_amount, method, status,
    provider_reference, confirmed_at, idempotency_key
  )
  values (
    p_order_id, v_session.id, p_amount, p_tip_amount, p_method, 'confirmed',
    nullif(p_provider_reference, ''), pg_catalog.now(), p_idempotency_key
  )
  returning * into v_payment;

  v_new_paid := v_paid + p_amount;
  v_closed := v_new_paid + 0.009 >= v_order.total;

  update mixe.orders
  set payment_status = case when v_closed then 'paid' else 'partial' end,
      status = case when v_closed then 'closed' else status end,
      closed_at = case when v_closed then pg_catalog.now() else null end,
      updated_at = pg_catalog.now()
  where id = p_order_id;

  if v_closed and v_order.table_id is not null then
    select count(*) into v_other_count
    from mixe.orders o
    where o.table_id = v_order.table_id
      and o.id <> p_order_id
      and o.status in ('pending_confirmation', 'open', 'sent', 'preparing', 'ready', 'served');
    if v_other_count = 0 then
      update mixe.tables set status = 'free' where id = v_order.table_id;
    end if;
  end if;

  if v_closed and v_order.public_client_token is not null then
    if not exists (
      select 1 from mixe.orders o
      where o.public_client_token = v_order.public_client_token
        and o.status in ('pending_confirmation', 'open', 'sent', 'preparing', 'ready', 'served')
    ) then
      update mixe.orders
      set public_client_token = null, updated_at = pg_catalog.now()
      where public_client_token = v_order.public_client_token;
    end if;
  end if;

  insert into mixe.audit_events (entity, entity_id, action, actor_id, payload)
  values (
    'payment', v_payment.id, 'confirmed', p_actor_id,
    pg_catalog.jsonb_build_object(
      'order_id', p_order_id,
      'cash_session_id', v_session.id,
      'amount', p_amount,
      'tip_amount', p_tip_amount,
      'method', p_method,
      'idempotency_key', p_idempotency_key
    )
  );

  return pg_catalog.jsonb_build_object(
    'payment', pg_catalog.to_jsonb(v_payment),
    'paid', v_new_paid,
    'due', greatest(0, v_order.total - v_new_paid),
    'tip_amount', p_tip_amount,
    'total_received', p_amount + p_tip_amount,
    'total', v_order.total,
    'closed', v_closed,
    'idempotent', false
  );
end;
$$;

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
    select 1 from mixe.staff s where s.id = p_actor_id and s.active = true
  ) then
    raise exception using errcode = '42501', message = 'El empleado no tiene autorización activa.';
  end if;

  select * into v_session
  from mixe.cash_sessions
  where id = p_session_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'No encontramos la sesión de caja.';
  end if;

  v_was_closed := v_session.closed_at is not null;
  if v_was_closed and v_session.closing_cash is distinct from p_closing_cash then
    raise exception using errcode = 'P0001', message = 'La caja ya fue cerrada con otro importe contado.';
  end if;

  select
    count(*)::integer,
    coalesce(sum(p.amount), 0),
    coalesce(sum(p.tip_amount), 0),
    coalesce(sum(case when p.method = 'cash' then p.amount + p.tip_amount else 0 end), 0),
    coalesce(sum(case when p.method = 'card' then p.amount + p.tip_amount else 0 end), 0),
    coalesce(sum(case when p.method = 'codi' then p.amount + p.tip_amount else 0 end), 0),
    coalesce(sum(case when p.method = 'transfer' then p.amount + p.tip_amount else 0 end), 0),
    coalesce(sum(case when p.method = 'online' then p.amount + p.tip_amount else 0 end), 0)
  into v_payment_count, v_sales, v_tips, v_cash, v_card, v_codi, v_transfer, v_online
  from mixe.payments p
  where p.cash_session_id = v_session.id and p.status = 'confirmed';

  v_expected := v_session.opening_float + v_cash;

  if not v_was_closed then
    v_difference := p_closing_cash - v_expected;
    update mixe.cash_sessions
    set closing_cash = p_closing_cash,
        closed_at = pg_catalog.now(),
        notes = coalesce(nullif(pg_catalog.left(coalesce(p_notes, ''), 500), ''), v_session.notes),
        closed_by = p_actor_id
    where id = p_session_id
    returning * into v_session;

    insert into mixe.audit_events (entity, entity_id, action, actor_id, payload)
    values (
      'cash_session', p_session_id, 'close', p_actor_id,
      pg_catalog.jsonb_build_object(
        'opening_float', v_session.opening_float,
        'cash_receipts', v_cash,
        'expected_cash', v_expected,
        'closing_cash', p_closing_cash,
        'difference', v_difference,
        'sales', v_sales,
        'tips', v_tips,
        'payment_count', v_payment_count,
        'card', v_card,
        'codi', v_codi,
        'transfer', v_transfer,
        'online', v_online
      )
    );
  else
    v_difference := v_session.closing_cash - v_expected;
  end if;

  v_summary := pg_catalog.jsonb_build_object(
    'sales', v_sales,
    'tips', v_tips,
    'cash', v_cash,
    'card', v_card,
    'codi', v_codi,
    'transfer', v_transfer,
    'online', v_online,
    'expectedCash', v_expected,
    'closingCash', v_session.closing_cash,
    'difference', v_difference,
    'paymentCount', v_payment_count
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'session', pg_catalog.to_jsonb(v_session),
    'summary', v_summary,
    'idempotent', v_was_closed
  );
end;
$$;

revoke all on function mixe.mixe_open_cash_session(numeric, text, uuid) from public, anon, authenticated;
revoke all on function mixe.mixe_pay_order(uuid, text, numeric, numeric, text, uuid, uuid) from public, anon, authenticated;
revoke all on function mixe.mixe_close_cash_session(uuid, numeric, text, uuid) from public, anon, authenticated;

grant execute on function mixe.mixe_open_cash_session(numeric, text, uuid) to service_role;
grant execute on function mixe.mixe_pay_order(uuid, text, numeric, numeric, text, uuid, uuid) to service_role;
grant execute on function mixe.mixe_close_cash_session(uuid, numeric, text, uuid) to service_role;
