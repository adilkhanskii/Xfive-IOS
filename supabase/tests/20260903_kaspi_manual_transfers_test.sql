-- Exercises the manual Kaspi transfer flow end to end on a scratch database.
-- Run after applying 20260903150000_kaspi_manual_transfers.sql.
begin;

do $test$
declare
  v_buyer uuid := '11111111-1111-1111-1111-111111111111';
  v_dev uuid := '22222222-2222-2222-2222-222222222222';
  v_order jsonb;
  v_payment_id uuid;
  v_result jsonb;
  v_credits integer;
  v_code text;
  v_failed boolean;
begin
  insert into auth.users (id) values (v_buyer), (v_dev)
    on conflict (id) do nothing;
  insert into public.profiles (id, name, credits)
  values (v_buyer, 'Buyer', 0), (v_dev, 'Dev', 0)
  on conflict (id) do update set credits = 0;

  -- Manual checkout stays closed until the merchant details are stored.
  perform set_config('x5.uid', v_buyer::text, true);
  perform set_config('x5.developer', 'off', true);
  v_failed := false;
  begin
    perform public.create_kaspi_manual_payment('x5_credits_1000_v2');
  exception when others then
    v_failed := true;
    if sqlerrm <> 'kaspi_manual_not_configured' then
      raise exception 'unconfigured_manual_checkout_wrong_error: %', sqlerrm;
    end if;
  end;
  if not v_failed then
    raise exception 'unconfigured_manual_checkout_was_allowed';
  end if;

  update public.kaspi_payment_settings
  set manual_enabled = true,
      recipient_name = 'ИП СЕЙДАХМЕТОВ',
      recipient_phone = '+7 700 774 4401',
      recipient_iban = 'KZ04722S000022520163'
  where singleton = true;

  -- The server owns the amount and the reference code.
  v_order := public.create_kaspi_manual_payment('x5_credits_2000_v2');
  v_payment_id := (v_order ->> 'id')::uuid;
  v_code := v_order ->> 'paymentCode';
  if (v_order ->> 'amountKzt')::numeric <> 2000 or (v_order ->> 'credits')::integer <> 2000 then
    raise exception 'manual_order_amount_not_server_priced: %', v_order;
  end if;
  if v_code !~ '^X5-[A-F0-9]{10}$' then
    raise exception 'manual_order_code_invalid: %', v_code;
  end if;
  if (v_order ->> 'recipientPhone') <> '+7 700 774 4401' then
    raise exception 'manual_order_missing_recipient';
  end if;

  -- Asking again reuses the open order instead of minting a second code.
  if (public.create_kaspi_manual_payment('x5_credits_2000_v2') ->> 'id')::uuid <> v_payment_id then
    raise exception 'manual_order_duplicated';
  end if;

  -- Nothing is granted before review.
  perform public.submit_kaspi_manual_payment(v_payment_id);
  select credits into v_credits from public.profiles where id = v_buyer;
  if v_credits <> 0 then
    raise exception 'submit_granted_credits_without_review: %', v_credits;
  end if;

  -- A buyer cannot approve their own transfer.
  v_failed := false;
  begin
    perform public.review_kaspi_manual_payment(v_payment_id, true, null);
  exception when others then
    v_failed := true;
    if sqlerrm <> 'developer_only' then
      raise exception 'self_review_wrong_error: %', sqlerrm;
    end if;
  end;
  if not v_failed then
    raise exception 'buyer_reviewed_own_payment';
  end if;

  -- Neither can they read the review queue.
  v_failed := false;
  begin
    perform public.list_kaspi_manual_payments('awaiting_review');
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'buyer_read_review_queue';
  end if;

  -- A developer approves once and the credits land once.
  perform set_config('x5.uid', v_dev::text, true);
  perform set_config('x5.developer', 'on', true);

  if jsonb_array_length(public.list_kaspi_manual_payments('awaiting_review')) <> 1 then
    raise exception 'review_queue_missing_submitted_payment';
  end if;

  v_result := public.review_kaspi_manual_payment(v_payment_id, true, 'проверено в Kaspi');
  if (v_result ->> 'creditsGranted')::integer <> 2000 or (v_result ->> 'status') <> 'confirmed' then
    raise exception 'approve_did_not_grant: %', v_result;
  end if;

  v_result := public.review_kaspi_manual_payment(v_payment_id, true, null);
  if (v_result ->> 'creditsGranted')::integer <> 0
     or (v_result ->> 'alreadyReviewed')::boolean is not true then
    raise exception 'second_approval_granted_again: %', v_result;
  end if;

  select credits into v_credits from public.profiles where id = v_buyer;
  if v_credits <> 2000 then
    raise exception 'credits_not_granted_exactly_once: %', v_credits;
  end if;

  -- A rejected transfer grants nothing.
  perform set_config('x5.uid', v_buyer::text, true);
  perform set_config('x5.developer', 'off', true);
  v_payment_id := (public.create_kaspi_manual_payment('x5_credits_1000_v2') ->> 'id')::uuid;
  perform public.submit_kaspi_manual_payment(v_payment_id);

  perform set_config('x5.uid', v_dev::text, true);
  perform set_config('x5.developer', 'on', true);
  v_result := public.review_kaspi_manual_payment(v_payment_id, false, 'перевод не найден');
  if (v_result ->> 'status') <> 'rejected' or (v_result ->> 'creditsGranted')::integer <> 0 then
    raise exception 'rejection_granted_credits: %', v_result;
  end if;

  select credits into v_credits from public.profiles where id = v_buyer;
  if v_credits <> 2000 then
    raise exception 'rejection_changed_balance: %', v_credits;
  end if;

  raise notice 'kaspi manual transfer flow: all assertions passed';
end;
$test$;

rollback;
