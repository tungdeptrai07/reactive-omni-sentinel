let apiOnline = false;

function fmtUsd(n) {
  return `$${Number(n).toLocaleString('en-US', { maximumFractionDigits: 2 })}`;
}

function updateUI(state) {
  const v = state.vaultState;
  const m = state.sentinelMetrics;
  document.getElementById('kpi-active').textContent = fmtUsd(v.activeVolatileCollateralUSD);
  document.getElementById('kpi-shield').textContent = fmtUsd(v.shieldedReserveUSD);
  document.getElementById('kpi-debt').textContent = fmtUsd(v.debtUSD);
  document.getElementById('kpi-hf').textContent = v.healthFactorX === 'INF' ? 'INF' : `${v.healthFactorX}x`;
  document.getElementById('kpi-callbacks').textContent = `${m.totalCallbacksRequested} / ${m.totalEventsProcessed}`;
}

async function fetchState() {
  const badge = document.getElementById('engine-status');
  try {
    const res = await fetch('/api/state');
    if (!res.ok) throw new Error('offline');
    const state = await res.json();
    apiOnline = true;
    badge.textContent = `LIVE EVM SANDBOX (${state.compiler.split('+')[0]})`;
    updateUI(state);
    document.getElementById('tx-output').textContent = JSON.stringify(state, null, 2);
  } catch {
    apiOnline = false;
    badge.textContent = 'Static Browser Preview';
  }
}

async function triggerMarketEvent(priceUSD, volatilityBps, liquidityDepthUSD) {
  document.getElementById('in-price').value = priceUSD;
  document.getElementById('in-vol').value = volatilityBps;
  document.getElementById('in-liq').value = liquidityDepthUSD;

  if (!apiOnline) {
    document.getElementById('tx-output').textContent = JSON.stringify(
      {
        mode: 'static-preview',
        hint: 'Run `npm run serve` locally to execute real compiled Solidity contracts on Ganache EVM.',
        simulatedInput: { priceUSD, volatilityBps, liquidityDepthUSD },
        expectedAction: priceUSD <= 2000 ? 'ACTION_STOP_LOSS_DELEVERAGE (80% shield / 75% debt cut)' : volatilityBps >= 750 ? 'ACTION_VOLATILITY_REBALANCE (40% hedge)' : 'NO_ACTION (healthy)',
      },
      null,
      2,
    );
    return;
  }

  const res = await fetch('/api/trigger', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ priceUSD, volatilityBps, liquidityDepthUSD }),
  });
  const data = await res.json();
  if (data.ok) {
    updateUI(data.state);
  }
  document.getElementById('tx-output').textContent = JSON.stringify(data.execution || data, null, 2);
}

async function resetSandbox() {
  if (!apiOnline) return;
  const res = await fetch('/api/reset', { method: 'POST' });
  const state = await res.json();
  updateUI(state);
  document.getElementById('tx-output').textContent = JSON.stringify({ reset: true, vaultState: state.vaultState }, null, 2);
}

document.addEventListener('DOMContentLoaded', () => {
  fetchState();

  document.getElementById('btn-custom').addEventListener('click', () => {
    triggerMarketEvent(
      Number(document.getElementById('in-price').value),
      Number(document.getElementById('in-vol').value),
      Number(document.getElementById('in-liq').value),
    );
  });
  document.getElementById('btn-healthy').addEventListener('click', () => triggerMarketEvent(2480, 190, 2200000));
  document.getElementById('btn-vol').addEventListener('click', () => triggerMarketEvent(2150, 860, 420000));
  document.getElementById('btn-crash').addEventListener('click', () => triggerMarketEvent(1820, 940, 280000));
  document.getElementById('btn-reset').addEventListener('click', resetSandbox);
});
