export const DEFAULT_KASPI_PROVIDER_IPS = ['194.187.247.152'];

export function readKaspiProviderQuery(url) {
  const params = new URL(url).searchParams;
  const command = params.get('command') || '';
  const txnId = params.get('txn_id') || '';
  const txnDate = params.get('txn_date') || '';
  const account = params.get('account') || '';
  const rawAmount = params.get('sum') || '';

  if (!['check', 'pay'].includes(command)) throw new Error('invalid_command');
  if (!/^[0-9]{1,18}$/.test(txnId)) throw new Error('invalid_txn_id');
  if (command === 'pay' && !/^[0-9]{14}$/.test(txnDate)) {
    throw new Error('invalid_txn_date');
  }
  if (!/^X5[A-F0-9]{18}$/.test(account)) throw new Error('invalid_account');
  if (!/^[0-9]+(?:\.[0-9]{1,2})?$/.test(rawAmount)) {
    throw new Error('invalid_amount');
  }

  return {
    command,
    txnId,
    txnDate,
    account,
    amount: Number(rawAmount),
  };
}

export function readForwardedClientIp(headers) {
  const trusted = headers.get('cf-connecting-ip') || headers.get('x-real-ip');
  const forwarded = headers.get('x-forwarded-for')?.split(',')[0]?.trim();
  return normalizeIp(trusted || forwarded || '');
}

export function isAllowedKaspiProviderIp(ip, configured) {
  const allowed = (configured || DEFAULT_KASPI_PROVIDER_IPS.join(','))
    .split(',')
    .map((value) => normalizeIp(value.trim()))
    .filter(Boolean);
  return Boolean(ip) && allowed.includes(normalizeIp(ip));
}

function normalizeIp(value) {
  return String(value || '').replace(/^::ffff:/i, '').trim();
}
