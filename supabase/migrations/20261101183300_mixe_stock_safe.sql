-- Atomic ingredient stock adjustment. Deploy the function in the private mixe schema.
create or replace function mixe.adjust_stock_safe(p_ingredient uuid,p_delta numeric,p_reason text,p_unit_cost numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v mixe.ingredients%rowtype; v_new numeric; v_cost numeric;
begin
 if p_delta is null or p_delta=0 or abs(p_delta)>1000000 or p_reason not in ('purchase','waste','adjustment') then raise exception 'Movimiento inválido'; end if;
 select * into v from mixe.ingredients where id=p_ingredient and active=true for update;
 if not found then raise exception 'Insumo no encontrado'; end if;
 v_new:=v.on_hand+p_delta;
 if v_new<0 then raise exception 'Existencia insuficiente'; end if;
 v_cost:=case when p_reason='purchase' then p_unit_cost else v.unit_cost end;
 if v_cost is null or v_cost<0 then raise exception 'Costo inválido'; end if;
 update mixe.ingredients set on_hand=v_new,unit_cost=v_cost where id=p_ingredient;
 insert into mixe.stock_movements(ingredient_id,quantity_delta,reason,unit_cost_snapshot)
 values(p_ingredient,p_delta,p_reason,v_cost);
 return jsonb_build_object('on_hand',v_new,'unit_cost',v_cost,'reorder_point',v.reorder_point);
end $$;
revoke all on function mixe.adjust_stock_safe(uuid,numeric,text,numeric) from public,anon,authenticated;
grant execute on function mixe.adjust_stock_safe(uuid,numeric,text,numeric) to service_role;
