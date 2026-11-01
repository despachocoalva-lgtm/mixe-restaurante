import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"GET,POST,OPTIONS"};
const out=(v,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 try{
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,secret=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!secret)return out({error:"Falta configurar la clave de servicio en los secretos de la función."},500);
  const body=req.method==="POST"?await req.json():{},action=req.method==="GET"?(new URL(req.url).searchParams.get("action")||"bootstrap"):body.action;
  if(action==="public_order"){
   if(req.method!=="POST")return out({error:"Método inválido."},405);
   const admin=createClient(url,secret),db=admin.schema("mixe");
   const tableCode=String(body.table_code||"").replace(/[^0-9A-Za-z_-]/g,"").slice(0,12);
   const clientToken=String(body.client_token||"");
   const deviceToken=String(body.device_token||"");
   if(!/^[0-9a-f-]{36}$/i.test(clientToken))return out({error:"Identificador de visita inválido."},400);
   if(deviceToken&&!/^[0-9a-f-]{36}$/i.test(deviceToken))return out({error:"Identificador de dispositivo inválido."},400);
   const items=Array.isArray(body.items)?body.items:[];
   if(!tableCode||items.length<1||items.length>12)return out({error:"Selecciona una mesa válida y entre 1 y 12 productos."},400);
   const {data:table,error:te}=await db.from("tables").select("id,code,active").eq("code",tableCode).eq("active",true).maybeSingle();
   if(te)throw te;if(!table)return out({error:"La mesa no existe o está deshabilitada."},404);
   const clean=[];
   for(const raw of items){
    const name=String(raw.name||"").trim().slice(0,120),quantity=Number(raw.quantity);
    if(!name||!Number.isInteger(quantity)||quantity<1||quantity>20)return out({error:"Producto o cantidad inválidos."},400);
    const {data:p,error:pe}=await db.from("products").select("id,name,price,active").eq("name",name).eq("active",true).maybeSingle();
    if(pe)throw pe;if(!p)return out({error:"Producto no disponible: "+name},400);
    const {data:recipes,error:re}=await db.from("recipes").select("ingredient_id,quantity,ingredients(id,name,on_hand,active)").eq("product_id",p.id);
    if(re)throw re;if(!recipes?.length)return out({error:"El platillo no tiene receta configurada: "+name},409);
    clean.push({product:p,quantity,option_label:String(raw.option_label||"").slice(0,100)||null,notes:String(raw.notes||"").slice(0,160)||null});
   }
   const {data:order,error:oe}=await db.from("orders").insert({table_id:table.id,source:"qr",status:"pending_confirmation",notes:String(body.notes||"").slice(0,300)||null,public_client_token:clientToken,public_device_token:deviceToken||null}).select("id,table_id,status,opened_at").single();
   if(oe)throw oe;
   let total=0;
   for(const line of clean){
    const {data:item,error:ie}=await db.from("order_items").insert({order_id:order.id,product_id:line.product.id,quantity:line.quantity,unit_price:line.product.price,option_label:line.option_label,notes:line.notes,status:"pending"}).select("id").single();
    if(ie){await db.from("orders").update({status:"cancelled"}).eq("id",order.id);throw ie;}
    total+=Number(line.product.price)*line.quantity;
   }
   const {error:up}=await db.from("orders").update({subtotal:total,total:total,updated_at:new Date().toISOString()}).eq("id",order.id);if(up)throw up;
   const {data:finalOrder,error:fo}=await db.from("orders").select("id,status,total,source,opened_at,tables(code),order_items(id,product_id,quantity,unit_price,option_label,notes,status,products(name))").eq("id",order.id).single();if(fo)throw fo;
   return out({ok:true,order:finalOrder,message:"Pedido recibido. Espera la confirmación del mesero."},201);
  }
  if(action==="public_resume_session"){
   if(req.method!=="POST")return out({error:"Método inválido."},405);
   const admin=createClient(url,secret),db=admin.schema("mixe");
   const tableCode=String(body.table_code||"").replace(/[^0-9A-Za-z_-]/g,"").slice(0,12);
   const deviceToken=String(body.device_token||"");
   if(!tableCode||!/^[0-9a-f-]{36}$/i.test(deviceToken))return out({error:"Mesa o identificador de dispositivo inválido."},400);
   const {data:table,error:te}=await db.from("tables").select("id,code").eq("code",tableCode).eq("active",true).maybeSingle();
   if(te)throw te;if(!table)return out({error:"La mesa no existe o está deshabilitada."},404);
   const cutoff=new Date(Date.now()-4*60*60*1000).toISOString();
   const {data:latest,error:le}=await db.from("orders").select("id,public_client_token,opened_at").eq("table_id",table.id).eq("public_device_token",deviceToken).gte("opened_at",cutoff).in("status",["pending_confirmation","open","sent","preparing","ready","served"]).not("public_client_token","is",null).order("opened_at",{ascending:false}).limit(1).maybeSingle();
   if(le)throw le;
   if(!latest?.public_client_token)return out({ok:true,resumed:false,orders:[]});
   const clientToken=String(latest.public_client_token);
   const {data:orders,error:oe}=await db.from("orders").select("id,status,total,payment_status,opened_at,updated_at,tables(code),order_items(id,quantity,unit_price,option_label,notes,status,products(name,category))").eq("table_id",table.id).eq("public_client_token",clientToken).order("opened_at",{ascending:false}).limit(10);
   if(oe)throw oe;
   return out({ok:true,resumed:true,client_token:clientToken,orders:orders||[]});
  }
  if(action==="public_client_orders"){
   if(req.method!=="POST")return out({error:"Método inválido."},405);
   const admin=createClient(url,secret),db=admin.schema("mixe");
   const tableCode=String(body.table_code||"").replace(/[^0-9A-Za-z_-]/g,"").slice(0,12);
   const clientToken=String(body.client_token||"");
   if(!tableCode||!/^[0-9a-f-]{36}$/i.test(clientToken))return out({error:"Mesa o identificador de cliente inválido."},400);
   const {data:table,error:te}=await db.from("tables").select("id,code").eq("code",tableCode).eq("active",true).maybeSingle();
   if(te)throw te;if(!table)return out({error:"La mesa no existe o está deshabilitada."},404);
   const {data:orders,error:oe}=await db.from("orders").select("id,status,total,payment_status,opened_at,updated_at,tables(code),order_items(id,quantity,unit_price,option_label,notes,status,products(name,category))").eq("table_id",table.id).eq("public_client_token",clientToken).order("opened_at",{ascending:false}).limit(10);
   if(oe)throw oe;
   return out({ok:true,orders:orders||[]});
  }
  if(action==="public_order_status"){
   if(req.method!=="POST")return out({error:"Método inválido."},405);
   const admin=createClient(url,secret),db=admin.schema("mixe");
   const tableCode=String(body.table_code||"").replace(/[^0-9A-Za-z_-]/g,"").slice(0,12);
   const orderId=String(body.order_id||"");
   if(!tableCode||!/^[0-9a-f-]{36}$/i.test(orderId))return out({error:"Mesa o folio inválido."},400);
   const {data:table,error:te}=await db.from("tables").select("id,code").eq("code",tableCode).eq("active",true).maybeSingle();
   if(te)throw te;if(!table)return out({error:"La mesa no existe o está deshabilitada."},404);
   const clientToken=String(body.client_token||"");
   if(!/^[0-9a-f-]{36}$/i.test(clientToken))return out({error:"Identificador de visita inválido."},400);
   const {data:order,error:oe}=await db.from("orders").select("id,status,total,payment_status,opened_at,updated_at,tables(code),order_items(id,quantity,unit_price,option_label,notes,status,products(name,category))").eq("id",orderId).eq("table_id",table.id).eq("public_client_token",clientToken).maybeSingle();
   if(oe)throw oe;if(!order)return out({error:"No encontramos ese pedido para esta mesa."},404);
   return out({ok:true,order});
  }
  const auth=req.headers.get("Authorization")||"", userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const {data:{user},error:authError}=await userClient.auth.getUser();
  if(authError||!user)return out({error:"Inicia sesión con tu teléfono para usar MIXE POS."},401);
  const admin=createClient(url,secret),db=admin.schema("mixe");
  const {data:staff,error:staffError}=await db.from("staff").select("id,display_name,role,active").eq("auth_user_id",user.id).maybeSingle();
  if(staffError)return out({error:"No se pudo consultar el acceso del empleado: "+staffError.message},500);
  if(!staff||!staff.active)return out({error:"Tu usuario aún no está autorizado. Pide al administrador que te registre en MIXE POS."},403);
  const allow=(roles)=>roles.includes(staff.role);
  if(action==="register_device"){
   const fingerprint=String(body.device_hash||"");if(!/^[a-f0-9]{64}$/.test(fingerprint))return out({error:"Huella inválida."},400);
   const {data:existing,error:de}=await db.from("staff_devices").select("id,revoked_at").eq("staff_id",staff.id).eq("device_fingerprint_hash",fingerprint).maybeSingle();if(de)throw de;if(existing?.revoked_at)return out({error:"Dispositivo revocado."},403);
   const {data,error}=await db.from("staff_devices").upsert({staff_id:staff.id,device_fingerprint_hash:fingerprint,device_label:String(body.device_label||"Dispositivo MIXE").slice(0,80),last_seen_at:new Date().toISOString(),revoked_at:null},{onConflict:"staff_id,device_fingerprint_hash"}).select("id,device_label,approved_at").single();if(error)throw error;return out({device:data});
  }
  if(action==="list_devices"){
   if(!["admin","manager"].includes(staff.role))return out({error:"Solo administración."},403);
   const {data,error}=await db.from("staff_devices").select("id,staff_id,device_label,approved_at,last_seen_at,revoked_at,staff(display_name,role)").order("approved_at",{ascending:false});if(error)throw error;return out({devices:data});
  }
  if(action==="revoke_device"){
   if(!["admin","manager"].includes(staff.role))return out({error:"Solo administración."},403);
   const {error}=await db.from("staff_devices").update({revoked_at:new Date().toISOString()}).eq("id",body.device_id);if(error)throw error;return out({ok:true});
  }
  if(action==="cancel_order"){
   if(!allow(["admin","manager","server"]))return out({error:"Solo un mesero o encargado puede cancelar cuentas."},403);
   const {data:before,error:be}=await db.from("orders").select("id,public_client_token").eq("id",body.order_id).maybeSingle();if(be)throw be;
   const {data,error}=await admin.rpc("mixe_cancel_order",{p_order_id:body.order_id});
   if(error)return out({error:error.message||"No se pudo cancelar la cuenta."},409);
   if(before?.public_client_token){const {data:active,error:ae}=await db.from("orders").select("id").eq("public_client_token",before.public_client_token).in("status",["pending_confirmation","open","sent","preparing","ready","served"]);if(ae)throw ae;if(!active?.length){const {error:clear}=await db.from("orders").update({public_client_token:null,updated_at:new Date().toISOString()}).eq("public_client_token",before.public_client_token);if(clear)throw clear}}
   return out(data);
  }
  if(action==="send_order_to_kitchen"){
   if(!allow(["admin","manager","server"]))return out({error:"Solo un mesero o encargado puede confirmar y enviar pedidos a cocina."},403);
   const {data,error}=await admin.rpc("mixe_send_order_to_kitchen",{p_order_id:body.order_id});
   if(error)return out({error:error.message||"No se pudo enviar el pedido a cocina."},409);
   return out(data);
  }
  if(action==="confirm_qr_order"){
   if(!allow(["admin","manager","server"]))return out({error:"Solo un mesero o encargado puede confirmar pedidos QR."},403);
   const {data,error}=await admin.rpc("mixe_confirm_qr_order",{p_order_id:body.order_id});
   if(error)return out({error:error.message||"No se pudo confirmar el pedido."},409);
   return out(data);
  }
  if(action==="reject_qr_order"){
   if(!allow(["admin","manager","server"]))return out({error:"Solo un mesero o encargado puede rechazar pedidos QR."},403);
   const db=admin.schema("mixe"),id=body.order_id;
   const {data:o,error:oe}=await db.from("orders").select("id,status,public_client_token").eq("id",id).single();if(oe)throw oe;
   if(o.status!=="pending_confirmation")return out({error:"Solo pueden rechazarse pedidos pendientes."},409);
   const {error}=await db.from("orders").update({status:"cancelled",updated_at:new Date().toISOString()}).eq("id",id);if(error)throw error;
   if(o.public_client_token){const {data:active,error:ae}=await db.from("orders").select("id").eq("public_client_token",o.public_client_token).in("status",["pending_confirmation","open","sent","preparing","ready","served"]);if(ae)throw ae;if(!active?.length){const {error:clear}=await db.from("orders").update({public_client_token:null,updated_at:new Date().toISOString()}).eq("public_client_token",o.public_client_token);if(clear)throw clear}}
   return out({ok:true,status:"cancelled"});
  }
  if(action==="register_cash_movement"){
   if(!allow(["admin","manager","cashier"]))return out({error:"Solo caja o administración puede registrar movimientos de efectivo."},403);
   const amount=Number(body.amount),sessionId=String(body.session_id||"");
   if(!sessionId||!Number.isFinite(amount)||amount<=0)return out({error:"Selecciona una caja abierta e indica un importe válido."},400);
   const {data,error}=await db.rpc("mixe_register_cash_movement",{
    p_session_id:sessionId,p_direction:String(body.direction||""),p_category:String(body.category||""),
    p_amount:amount,p_notes:String(body.notes||"").slice(0,500),p_actor_id:staff.id
   });
   if(error)return out({error:error.message||"No se pudo registrar el movimiento de efectivo."},409);
   return out(data);
  }
  if(action==="cash_history"){
   if(!allow(["admin","manager","cashier"]))return out({error:"Solo caja o administración puede consultar el historial de cortes."},403);
   const {data:sessions,error:sessionError}=await db.from("cash_sessions").select("*").not("closed_at","is",null).order("closed_at",{ascending:false}).limit(30);
   if(sessionError)throw sessionError;
   const sessionIds=(sessions||[]).map(s=>s.id);
   const staffIds=[...new Set((sessions||[]).flatMap(s=>[s.opened_by,s.closed_by]).filter(Boolean))];
   const [paymentResult,staffResult,legacyResult,movementResult]=await Promise.all([
    sessionIds.length?db.from("payments").select("id,order_id,cash_session_id,amount,tip_amount,method,status,created_at,provider_reference").in("cash_session_id",sessionIds).eq("status","confirmed").order("created_at",{ascending:false}):Promise.resolve({data:[],error:null}),
    staffIds.length?db.from("staff").select("id,display_name,role").in("id",staffIds):Promise.resolve({data:[],error:null}),
    db.from("payments").select("id,amount,tip_amount").is("cash_session_id",null).eq("status","confirmed"),
    sessionIds.length?db.from("cash_movements").select("id,cash_session_id,direction,category,amount,notes,created_by,created_at").in("cash_session_id",sessionIds).order("created_at",{ascending:false}):Promise.resolve({data:[],error:null})
   ]);
   if(paymentResult.error)throw paymentResult.error;
   if(staffResult.error)throw staffResult.error;
   if(legacyResult.error)throw legacyResult.error;
   if(movementResult.error)throw movementResult.error;
   const people=new Map((staffResult.data||[]).map(x=>[x.id,x]));
   const movementStaffIds=[...new Set((movementResult.data||[]).map(m=>m.created_by).filter(Boolean))].filter(id=>!people.has(id));
   if(movementStaffIds.length){const {data:extraStaff,error}=await db.from("staff").select("id,display_name,role").in("id",movementStaffIds);if(error)throw error;for(const person of extraStaff||[])people.set(person.id,person);}
   const paymentsBySession=new Map(),movementsBySession=new Map();
   for(const p of paymentResult.data||[]){const list=paymentsBySession.get(p.cash_session_id)||[];list.push(p);paymentsBySession.set(p.cash_session_id,list);}
   for(const m of movementResult.data||[]){const list=movementsBySession.get(m.cash_session_id)||[];list.push({...m,created_by_name:people.get(m.created_by)?.display_name||"No identificado"});movementsBySession.set(m.cash_session_id,list);}
   const methodKeys=["cash","card","codi","transfer","online"];
   const history=(sessions||[]).map(s=>{
    const payments=paymentsBySession.get(s.id)||[],movements=movementsBySession.get(s.id)||[];
    const summary={sales:0,tips:0,cash:0,cashIn:0,cashOut:0,card:0,codi:0,transfer:0,online:0,paymentCount:payments.length};
    for(const p of payments){const amount=Number(p.amount||0),tip=Number(p.tip_amount||0);summary.sales+=amount;summary.tips+=tip;if(methodKeys.includes(p.method))summary[p.method]+=amount+tip;}
    for(const m of movements){if(m.direction==="in")summary.cashIn+=Number(m.amount||0);else summary.cashOut+=Number(m.amount||0);}
    summary.expectedCash=Number(s.opening_float||0)+summary.cash+summary.cashIn-summary.cashOut;
    summary.closingCash=s.closing_cash===null?null:Number(s.closing_cash);
    summary.difference=summary.closingCash===null?null:summary.closingCash-summary.expectedCash;
    return {...s,opened_by_name:people.get(s.opened_by)?.display_name||"No identificado",closed_by_name:people.get(s.closed_by)?.display_name||"No identificado",summary,payments,movements};
   });
   const legacy=legacyResult.data||[];
   return out({sessions:history,limit:30,unassigned:{count:legacy.length,sales:legacy.reduce((n,p)=>n+Number(p.amount||0),0),tips:legacy.reduce((n,p)=>n+Number(p.tip_amount||0),0)}});
  }
  if(action==="cash_summary"){
   if(!allow(["admin","manager","cashier"]))return out({error:"Solo caja o administración puede consultar el corte."},403);
   const {data:openSession,error:se}=await db.from("cash_sessions").select("*").is("closed_at",null).order("opened_at",{ascending:false}).limit(1).maybeSingle();if(se)throw se;
   const {data:lastSession,error:le}=await db.from("cash_sessions").select("*").not("closed_at","is",null).order("closed_at",{ascending:false}).limit(1).maybeSingle();if(le)throw le;
   const reportSession=openSession||lastSession;
   let payments=[],movements=[];
   if(reportSession){
    const [pr,mr]=await Promise.all([
     db.from("payments").select("id,order_id,cash_session_id,amount,tip_amount,method,status,created_at").eq("cash_session_id",reportSession.id).eq("status","confirmed").order("created_at"),
     db.from("cash_movements").select("id,cash_session_id,direction,category,amount,notes,created_by,created_at").eq("cash_session_id",reportSession.id).order("created_at",{ascending:false})
    ]);
    if(pr.error)throw pr.error;if(mr.error)throw mr.error;payments=pr.data||[];movements=mr.data||[];
    const movementStaffIds=[...new Set(movements.map(m=>m.created_by).filter(Boolean))];
    if(movementStaffIds.length){const {data:people,error}=await db.from("staff").select("id,display_name").in("id",movementStaffIds);if(error)throw error;const names=new Map((people||[]).map(x=>[x.id,x.display_name]));movements=movements.map(m=>({...m,created_by_name:names.get(m.created_by)||"No identificado"}));}
   }
   const summary={sales:0,tips:0,cash:0,cashIn:0,cashOut:0,card:0,codi:0,transfer:0,online:0,paymentCount:payments.length};
   for(const p of payments){const amount=Number(p.amount||0),tip=Number(p.tip_amount||0);summary.sales+=amount;summary.tips+=tip;if(["cash","card","codi","transfer","online"].includes(p.method))summary[p.method]+=amount+tip;}
   for(const m of movements){if(m.direction==="in")summary.cashIn+=Number(m.amount||0);else summary.cashOut+=Number(m.amount||0);}
   summary.expectedCash=Number(reportSession?.opening_float||0)+summary.cash+summary.cashIn-summary.cashOut;
   summary.closingCash=reportSession?.closing_cash===null||reportSession?.closing_cash===undefined?null:Number(reportSession.closing_cash);
   summary.difference=summary.closingCash===null?null:summary.closingCash-summary.expectedCash;
   return out({session:openSession||null,lastSession:lastSession||null,summary,movements});
  }
  if(action==="open_cash_session"){
   if(!allow(["admin","manager","cashier"]))return out({error:"Solo caja o administración puede abrir caja."},403);
   const opening=Number(body.opening_float);
   if(!Number.isFinite(opening)||opening<0)return out({error:"El fondo inicial debe ser un importe válido igual o mayor que cero."},400);
   const {data,error}=await db.rpc("mixe_open_cash_session",{p_opening_float:opening,p_notes:String(body.notes||"").slice(0,500)||null,p_actor_id:staff.id});
   if(error)return out({error:error.message||"No se pudo abrir caja."},409);
   return out(data);
  }
  if(action==="close_cash_session"){
   if(!allow(["admin","manager","cashier"]))return out({error:"Solo caja o administración puede cerrar caja."},403);
   const closing=Number(body.closing_cash),sessionId=String(body.session_id||"");
   if(!sessionId||!Number.isFinite(closing)||closing<0)return out({error:"Captura el efectivo contado y una sesión válida."},400);
   const {data,error}=await db.rpc("mixe_close_cash_session",{p_session_id:sessionId,p_closing_cash:closing,p_notes:String(body.notes||"").slice(0,500)||null,p_actor_id:staff.id});
   if(error)return out({error:error.message||"No se pudo cerrar caja."},409);
   return out(data);
  }

    if(action==="bootstrap"){
   const [tables,products,orders,ingredients,employees,recipes]=await Promise.all([
    db.from("tables").select("*").eq("active",true).order("code"),
    db.from("products").select("*").eq("active",true).order("category").order("name"),
    db.from("orders").select("*,tables(code),order_items(*,products(name,category))").in("status",["pending_confirmation","open","sent","preparing","ready","served"]).order("opened_at"),
    db.from("ingredients").select("*").eq("active",true).order("name"),
    staff.role==="admin"||staff.role==="manager"?db.from("staff").select("id,auth_user_id,display_name,phone_e164,role,active,created_at").order("display_name"):Promise.resolve({data:[],error:null}),
    db.from("recipes").select("product_id,ingredient_id,quantity,products(name),ingredients(name,unit,unit_cost)").order("product_id")]);
   for(const q of [tables,products,orders,ingredients,employees,recipes])if(q.error)throw q.error;
   const activeOrderIds=(orders.data||[]).map(o=>o.id);
   let payments=[];
   if(activeOrderIds.length){
    const {data:paymentRows,error:paymentError}=await db.from("payments").select("id,order_id,cash_session_id,amount,tip_amount,method,status,confirmed_at,created_at,idempotency_key").in("order_id",activeOrderIds).order("created_at");
    if(paymentError)throw paymentError;
    payments=paymentRows||[];
   }
   return out({staff,tables:tables.data,products:products.data,orders:orders.data,payments,ingredients:ingredients.data,employees:employees.data,recipes:recipes.data});
  }
  if(action==="create_staff"){
   if(staff.role!=="admin")return out({error:"Solo el administrador principal puede dar de alta personal."},403);
   const {auth_user_id,display_name,phone_e164,role}=body;
   if(!auth_user_id||!String(display_name||"").trim()||!/^\\+[1-9]\\d{7,14}$/.test(String(phone_e164||""))||!["admin","manager","cashier","server","kitchen"].includes(role))return out({error:"Completa usuario Auth, nombre, teléfono internacional y puesto."},400);
   const {data:au,error:ae}=await admin.auth.admin.getUserById(auth_user_id);if(ae||!au?.user)return out({error:"No se encontró el usuario en Supabase Auth."},404);
   if(au.user.phone!==phone_e164)return out({error:"El teléfono debe coincidir con el usuario verificado de Supabase Auth."},409);
   const {data,error}=await db.from("staff").insert({auth_user_id,display_name:String(display_name).trim().slice(0,100),phone_e164,role,active:true}).select("id,display_name,phone_e164,role,active").single();if(error)throw error;return out({staff:data});
  }
  if(action==="set_staff_active"){
   if(staff.role!=="admin")return out({error:"Solo el administrador principal puede cambiar accesos."},403);
   if(staff.id===body.staff_id&&body.active===false)return out({error:"No puedes desactivar tu propio acceso."},400);
   const {data,error}=await db.from("staff").update({active:!!body.active}).eq("id",body.staff_id).select("id,display_name,phone_e164,role,active").single();if(error)throw error;return out({staff:data});
  }
  if(action==="create_order"){
   if(!allow(["admin","manager","cashier","server"]))return out({error:"Tu rol no puede abrir cuentas."},403);
   const {table_id,source="staff",customer_id,notes}=body;
   if(!["staff","qr","web"].includes(source))return out({error:"Origen inválido."},400);
   const {data,error}=await db.from("orders").insert({table_id:table_id||null,customer_id:customer_id||null,source,notes:notes||null,status:"open"}).select().single();if(error)throw error;
   if(table_id){const {error:e}=await db.from("tables").update({status:"occupied"}).eq("id",table_id);if(e)throw e}
   return out({order:data});
  }
  if(action==="add_item"){
   if(!allow(["admin","manager","cashier","server"]))return out({error:"Tu rol no puede agregar productos."},403);
   const {order_id,product_id,quantity=1,option_label,notes}=body;
   if(!order_id||!product_id||!Number.isInteger(quantity)||quantity<1||quantity>99)return out({error:"Datos de producto inválidos."},400);
   const {data:itemResult,error:itemError}=await admin.rpc("mixe_add_order_item",{p_order_id:order_id,p_product_id:product_id,p_quantity:quantity,p_option_label:option_label||null,p_notes:notes||null});
   if(itemError)return out({error:itemError.message||"No se pudo registrar el producto."},409);
   return out(itemResult);
  }
  if(action==="update_item_status"){
   if(!allow(["admin","manager","kitchen","server"]))return out({error:"Tu rol no puede cambiar estados de cocina."},403);
   if(!["pending","sent","preparing","ready","served","void"].includes(body.status))return out({error:"Estado inválido."},400);
   const {data:itemResult,error:itemError}=await admin.rpc("mixe_update_item_status",{p_item_id:body.item_id,p_status:body.status});
   if(itemError)return out({error:itemError.message||"No se pudo actualizar el estado."},409);
   return out({item:itemResult});
  }
  if(action==="pay_order"){
   if(!allow(["admin","manager","cashier"]))return out({error:"Solo caja o administración puede registrar pagos."},403);
   const {order_id,method,amount,tip_amount=0,provider_reference,idempotency_key}=body;
   const amt=Number(amount),tip=Number(tip_amount);
   if(![ "cash","card","codi","transfer","online" ].includes(method)||!Number.isFinite(amt)||amt<=0||!Number.isFinite(tip)||tip<0||tip>amt)return out({error:"Pago o propina inválidos. La propina debe ser entre $0 y el importe del pago."},400);
   if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(idempotency_key||"")))return out({error:"Falta una clave válida para proteger el intento de pago contra duplicados."},400);
   const {data,error}=await db.rpc("mixe_pay_order",{
    p_order_id:order_id,
    p_method:method,
    p_amount:amt,
    p_tip_amount:tip,
    p_provider_reference:provider_reference||null,
    p_idempotency_key:idempotency_key,
    p_actor_id:staff.id
   });
   if(error)return out({error:error.message||"No se pudo registrar el pago."},409);
   return out(data);
  }

    if(action==="save_recipe_item"){
   if(!allow(["admin","manager"]))return out({error:"Solo administración puede modificar recetas."},403);
   const {product_id,ingredient_id,quantity}=body; const qty=Number(quantity);
   if(!product_id||!ingredient_id||!Number.isFinite(qty)||qty<=0)return out({error:"Selecciona platillo, ingrediente y cantidad mayor que cero."},400);
   const {data:existing,error:findError}=await db.from("recipes").select("product_id,ingredient_id").eq("product_id",product_id).eq("ingredient_id",ingredient_id).maybeSingle();
   if(findError)throw findError;
   const result=existing?await db.from("recipes").update({quantity:qty}).eq("product_id",product_id).eq("ingredient_id",ingredient_id).select().single():await db.from("recipes").insert({product_id,ingredient_id,quantity:qty}).select().single();
   if(result.error)throw result.error;
   return out({recipe:result.data,message:existing?"Cantidad actualizada.":"Ingrediente agregado a la receta."});
  }
  if(action==="delete_recipe_item"){
   if(!allow(["admin","manager"]))return out({error:"Solo administración puede modificar recetas."},403);
   const {product_id,ingredient_id}=body;if(!product_id||!ingredient_id)return out({error:"Falta platillo o ingrediente."},400);
   const {error}=await db.from("recipes").delete().eq("product_id",product_id).eq("ingredient_id",ingredient_id);if(error)throw error;
   return out({ok:true,message:"Ingrediente eliminado de la receta."});
  }
  if(action==="add_ingredient"){
   if(!allow(["admin","manager"]))return out({error:"Solo administración puede editar inventario."},403);
   const {name,unit,on_hand=0,reorder_point=0,unit_cost=0}=body;if(!name||!["g","kg","ml","l","piece"].includes(unit)||Number(on_hand)<0||Number(unit_cost)<0)return out({error:"Datos de insumo inválidos."},400);
   const {data,error}=await db.from("ingredients").insert({name,unit,on_hand,reorder_point,unit_cost}).select().single();if(error)throw error;
   if(Number(on_hand)!==0){const {error:me}=await db.from("stock_movements").insert({ingredient_id:data.id,quantity_delta:on_hand,reason:"adjustment",unit_cost_snapshot:unit_cost});if(me)throw me}
   return out({ingredient:data});
  }
  if(action==="report"){
   if(!allow(["admin","manager","cashier"]))return out({error:"Sin permiso para reportes."},403);
   const {data:items,error}=await db.from("order_items").select("product_id,quantity,unit_price,unit_cost_snapshot,status,products(name,category),orders!inner(status)").eq("orders.status","closed").neq("status","void");if(error)throw error;
   const agg={};for(const x of items){const k=x.product_id;agg[k]??={product:x.products?.name,category:x.products?.category,units:0,revenue:0,ingredient_cost:0};agg[k].units+=Number(x.quantity);agg[k].revenue+=Number(x.quantity)*Number(x.unit_price);agg[k].ingredient_cost+=Number(x.quantity)*Number(x.unit_cost_snapshot)}
   const {data:tips,error:tipError}=await db.from("payments").select("tip_amount,method,confirmed_at,orders!inner(status)").eq("status","confirmed").eq("orders.status","closed");if(tipError)throw tipError;const tipTotal=(tips||[]).reduce((sum,p)=>sum+Number(p.tip_amount||0),0);const tipsByMethod={};for(const p of tips||[]){tipsByMethod[p.method]=(tipsByMethod[p.method]||0)+Number(p.tip_amount||0)}return out({products:Object.values(agg).map(x=>({...x,contribution:x.revenue-x.ingredient_cost})).sort((a,b)=>b.contribution-a.contribution),tips:{total:tipTotal,by_method:tipsByMethod}});
  }
  return out({error:"Acción desconocida."},400);
 }catch(e){return out({error:e?.message||"Error interno"},500)}
});