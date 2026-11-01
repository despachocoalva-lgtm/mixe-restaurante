-- MIXE POS: session-bound payments, idempotency and one-open-register invariant.
alter table mixe.payments
  add column if not exists cash_session_id uuid references mixe.cash_sessions(id),
  add column if not exists idempotency_key uuid not null default gen_random_uuid();

alter table mixe.cash_sessions
  add column if not exists opened_by uuid references mixe.staff(id),
  add column if not exists closed_by uuid references mixe.staff(id);

create unique index if not exists mixe_payments_idempotency_key_uidx
  on mixe.payments (idempotency_key);

create index if not exists mixe_payments_cash_session_idx
  on mixe.payments (cash_session_id, status, created_at);

create unique index if not exists mixe_one_open_cash_session_uidx
  on mixe.cash_sessions ((1))
  where closed_at is null;

alter table mixe.payments
  add constraint mixe_payments_amount_positive_check
  check (amount > 0) not valid;

alter table mixe.payments
  add constraint mixe_payments_tip_valid_check
  check (tip_amount >= 0 and tip_amount <= amount) not valid;

alter table mixe.payments validate constraint mixe_payments_amount_positive_check;
alter table mixe.payments validate constraint mixe_payments_tip_valid_check;
