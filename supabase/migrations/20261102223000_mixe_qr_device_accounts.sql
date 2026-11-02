-- MIXE: one persistent individual account per customer device and table.
create unique index if not exists mixe_one_active_qr_order_per_client
on mixe.orders (table_id, public_client_token)
where source = 'qr'
  and public_client_token is not null
  and status in ('pending_confirmation','open','sent','preparing','ready','served');

create or replace function mixe.mixe_submit_qr_order(
  p_table_id uuid,
  p_client_token uuid,
  p_device_token uuid,
  p_notes text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_order mixe.orders%rowtype;
  v_product mixe.products%rowtype;
  v_line jsonb;
  v_product_id uuid;
  v_quantity integer;
  v_reused boolean := false;
  v_items_added integer := 0;
begin
  if p_table_id is null or p_client_token is null or p_device_token is null then
    raise exception using errcode = '22023', message = 'Falta identificar la mesa o el dispositivo.';
  end if;
  if p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array'
     or pg_catalog.jsonb_array_length(p_items) < 1
     or pg_catalog.jsonb_array_length(p_items) > 12 then
    raise exception using errcode = '22023', message = 'Envía entre 1 y 12 productos por pedido.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_table_id::text || ':' || p_client_token::text, 0)
  );

  if not exists (select 1 from mixe.tables t where t.id = p_table_id and t.active = true) then
    raise exception using errcode = 'P0002', message = 'La mesa no existe o está deshabilitada.';
  end if;

  select * into v_order
  from mixe.orders o
  where o.table_id = p_table_id and o.source = 'qr'
    and o.public_client_token = p_client_token
    and o.status in ('pending_confirmation','open','sent','preparing','ready','served')
  order by o.opened_at desc limit 1 for update;

  if found then
    v_reused := true;
    if v_order.public_device_token is not null and v_order.public_device_token <> p_device_token then
      raise exception using errcode = '42501', message = 'Esta cuenta pertenece a otro dispositivo. Escanea nuevamente el QR de tu mesa.';
    end if;
    if v_order.payment_status = 'paid' or v_order.status in ('closed','cancelled') then
      raise exception using errcode = 'P0001', message = 'Esta cuenta ya está cerrada. Solicita al mesero abrir una nueva cuenta.';
    end if;
    if exists (select 1 from mixe.order_splits s where s.order_id = v_order.id) then
      raise exception using errcode = 'P0001', message = 'La cuenta tiene una división activa. Solicita apoyo al mesero antes de agregar productos.';
    end if;
    update mixe.orders
       set public_device_token = coalesce(public_device_token, p_device_token),
           notes = coalesce(notes, nullif(pg_catalog.left(pg_catalog.btrim(p_notes), 300), '')),
           status = case when status = 'pending_confirmation' then status else 'sent' end,
           updated_at = pg_catalog.now()
     where id = v_order.id;
  else
    update mixe.orders set public_client_token = null, updated_at = pg_catalog.now()
     where table_id = p_table_id and source = 'qr'
       and public_client_token = p_client_token and status in ('closed','cancelled');
    insert into mixe.orders (table_id,source,status,notes,public_client_token,public_device_token)
    values (p_table_id,'qr','pending_confirmation',
      nullif(pg_catalog.left(pg_catalog.btrim(p_notes),300),''),
      p_client_token,p_device_token)
    returning * into v_order;
  end if;

  for v_line in select value from pg_catalog.jsonb_array_elements(p_items) as item(value) loop
    v_product_id := nullif(v_line->>'product_id','')::uuid;
    v_quantity := nullif(v_line->>'quantity','')::integer;
    if v_product_id is null or v_quantity is null or v_quantity < 1 or v_quantity > 20 then
      raise exception using errcode = '22023', message = 'Producto o cantidad inválidos.';
    end if;
    select * into v_product from mixe.products p
     where p.id = v_product_id and p.active = true for share;
    if not found then
      raise exception using errcode = '22023', message = 'Uno de los productos ya no está disponible.';
    end if;
    if not exists (select 1 from mixe.recipes r where r.product_id = v_product.id) then
      raise exception using errcode = '23514', message = 'El platillo no tiene receta configurada: ' || v_product.name;
    end if;
    insert into mixe.order_items (order_id,product_id,quantity,unit_price,option_label,notes,status)
    values (v_order.id,v_product.id,v_quantity,v_product.price,
      nullif(pg_catalog.left(pg_catalog.btrim(v_line->>'option_label'),100),''),
      nullif(pg_catalog.left(pg_catalog.btrim(v_line->>'notes'),160),''),'pending');
    v_items_added := v_items_added + 1;
  end loop;

  select * into v_order from mixe.orders where id = v_order.id;
  return pg_catalog.jsonb_build_object(
    'order_id',v_order.id,'table_id',v_order.table_id,'status',v_order.status,
    'total',v_order.total,'reused',v_reused,'items_added',v_items_added
  );
end;
$function$;

revoke all on function mixe.mixe_submit_qr_order(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function mixe.mixe_submit_qr_order(uuid,uuid,uuid,text,jsonb) to service_role;
