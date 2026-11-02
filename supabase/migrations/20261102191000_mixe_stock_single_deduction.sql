-- Retain the existing BEFORE trigger as the sole stock-on-preparing trigger.
-- Skip re-consumption if the same order item has already consumed any ingredients.
-- Return only the net quantity not already returned when an item is voided.
create or replace function mixe.handle_recipe_inventory()
returns trigger language plpgsql security definer set search_path='' as $$
declare r record; needed numeric;
begin
 if new.status is not distinct from old.status then return new; end if;
 if new.status='preparing' then
   if old.status='void' then raise exception 'No puedes reactivar un platillo anulado'; end if;
   if not exists(select 1 from mixe.stock_movements where order_item_id=new.id and reason='recipe') then
    for r in select i.id,i.name,i.on_hand,i.unit_cost,rc.quantity
    from mixe.recipes rc join mixe.ingredients i on i.id=rc.ingredient_id
    where rc.product_id=new.product_id order by i.id for update of i loop
     needed:=r.quantity*new.quantity;
     if r.on_hand<needed then raise exception 'Inventario insuficiente para %',r.name; end if;
     update mixe.ingredients set on_hand=on_hand-needed where id=r.id;
     insert into mixe.stock_movements(ingredient_id,order_item_id,quantity_delta,reason,unit_cost_snapshot)
     values(r.id,new.id,-needed,'recipe',r.unit_cost);
    end loop;
   end if;
 end if;
 if new.status='void' then
  for r in select ingredient_id,sum(case when reason in ('recipe','return','adjustment') then -quantity_delta else 0 end) as net_qty,max(unit_cost_snapshot) as unit_cost
  from mixe.stock_movements where order_item_id=new.id and reason in ('recipe','return','adjustment') group by ingredient_id loop
   if r.net_qty>0 then
    perform 1 from mixe.ingredients where id=r.ingredient_id for update;
    update mixe.ingredients set on_hand=on_hand+r.net_qty where id=r.ingredient_id;
    insert into mixe.stock_movements(ingredient_id,order_item_id,quantity_delta,reason,unit_cost_snapshot)
    values(r.ingredient_id,new.id,r.net_qty,'return',r.unit_cost);
   end if;
  end loop;
 end if;
 return new;
end $$;
drop trigger if exists trg_apply_recipe_stock_on_item_status on mixe.order_items;
