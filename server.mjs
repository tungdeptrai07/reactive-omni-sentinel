import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';
import ganache from 'ganache';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const WEB_DIR = path.join(__dirname, 'web');
const ARTIFACTS_DIR = path.join(__dirname, 'artifacts');

function loadArtifact(name) {
  return JSON.parse(fs.readFileSync(path.join(ARTIFACTS_DIR, `${name}.json`), 'utf8'));
}

const oracleArt = loadArtifact('OriginMarketOracle');
const reactiveArt = loadArtifact('OmniSentinelReactive');
const vaultArt = loadArtifact('DestinationShieldVault');
const mockSysArt = loadArtifact('MockOmniSystemContract');

const UNICHAIN_SEPOLIA_ID = 1301n;
const BASE_SEPOLIA_ID = 84532n;
const WETH_ADDR = '0x4200000000000000000000000000000000000006';

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.pdf': 'application/pdf',
  '.mp4': 'video/mp4',
  '.svg': 'image/svg+xml',
};

function sendJson(res, status, data) {
  const body = JSON.stringify(data, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 1_000_000) reject(new Error('Body too large'));
    });
    req.on('end', () => {
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

async function initEvmSandbox() {
  const ganacheProvider = ganache.provider({
    logging: { quiet: true },
    wallet: { totalAccounts: 3, defaultBalance: 100 },
    chain: { hardfork: 'shanghai' },
  });
  const provider = new ethers.BrowserProvider(ganacheProvider, undefined, { cacheTimeout: -1 });
  const owner = await provider.getSigner(0);

  const mockSys = await new ethers.ContractFactory(mockSysArt.abi, mockSysArt.bytecode, owner).deploy();
  await mockSys.waitForDeployment();

  const oracle = await new ethers.ContractFactory(oracleArt.abi, oracleArt.bytecode, owner).deploy();
  await oracle.waitForDeployment();

  const reactive = await new ethers.ContractFactory(reactiveArt.abi, reactiveArt.bytecode, owner).deploy(
    await mockSys.getAddress(),
    UNICHAIN_SEPOLIA_ID,
    BASE_SEPOLIA_ID,
    await oracle.getAddress(),
    ethers.ZeroAddress,
    2000_00000000n,
    750n,
    500_000n,
    0n, // 0s cooldown in interactive sandbox so users can test consecutive scenarios immediately
    { value: ethers.parseEther('2.0') },
  );
  await reactive.waitForDeployment();

  const vault = await new ethers.ContractFactory(vaultArt.abi, vaultArt.bytecode, owner).deploy(
    await mockSys.getAddress(),
    await reactive.getAddress(),
    0n,
    { value: ethers.parseEther('2.0') },
  );
  await vault.waitForDeployment();

  await (await reactive.setDestinationVault(await vault.getAddress())).wait();
  await (await vault.openOrFundPosition(WETH_ADDR, 100_000_00000000n, 60_000_00000000n)).wait();

  return {
    ganacheProvider,
    provider,
    owner,
    mockSys,
    oracle,
    reactive,
    vault,
    addresses: {
      systemProxyLocal: await mockSys.getAddress(),
      originOracleLocal: await oracle.getAddress(),
      reactiveSentinelLocal: await reactive.getAddress(),
      destinationVaultLocal: await vault.getAddress(),
      officialLasnaSystem: '0x8888888888888888888888888888888888888888',
      officialUnichainProxy: '0x775c9B990ADe401060B78D0e98684eEf8d2466C1',
      officialBaseProxy: '0x476F44b11F5C942c58f4c8E3d0300E5710743585',
    },
    history: [],
  };
}

export async function createServer() {
  let sandbox = await initEvmSandbox();

  async function getStateSnapshot(blockTag = 'latest') {
    const opts = { blockTag };
    const st = await sandbox.vault.vaults(WETH_ADDR, opts);
    const hfBps = await sandbox.vault.getHealthFactorBps(WETH_ADDR, opts);
    return {
      status: 'ok',
      project: 'OmniSentinel RSC',
      hackathon: 'Reactive Omni Buildathon',
      compiler: reactiveArt.compiler,
      chains: {
        origin: { name: 'Unichain Sepolia', chainId: 1301, blockTimeMs: 1000 },
        reactive: { name: 'Reactive Lasna', chainId: 5318007, blockTimeMs: 1000 },
        destination: { name: 'Base Sepolia', chainId: 84532, blockTimeMs: 200 },
      },
      addresses: sandbox.addresses,
      sentinelMetrics: {
        stopLossThresholdUSD: Number(await sandbox.reactive.stopLossThresholdE8(opts)) / 1e8,
        maxVolatilityBps: Number(await sandbox.reactive.maxVolatilityBps(opts)),
        minLiquidityDepthUSD: Number(await sandbox.reactive.minLiquidityDepthUSD(opts)),
        totalEventsProcessed: Number(await sandbox.reactive.totalEventsProcessed(opts)),
        totalCallbacksRequested: Number(await sandbox.reactive.totalCallbacksRequested(opts)),
        paused: await sandbox.reactive.paused(opts),
      },
      vaultState: {
        asset: WETH_ADDR,
        activeVolatileCollateralUSD: Number(st.activeVolatileCollateralUSD) / 1e8,
        shieldedReserveUSD: Number(st.shieldedReserveUSD) / 1e8,
        debtUSD: Number(st.debtUSD) / 1e8,
        healthFactorX: st.debtUSD === 0n ? 'INF' : (Number(hfBps) / 10_000).toFixed(2),
        protectionCount: Number(st.protectionCount),
      },
      history: sandbox.history.slice(-15).reverse(),
    };
  }

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
      });
      res.end();
      return;
    }

    try {
      if (url.pathname === '/api/health' || url.pathname === '/api/state') {
        return sendJson(res, 200, await getStateSnapshot());
      }

      if (url.pathname === '/api/reset' && req.method === 'POST') {
        await sandbox.ganacheProvider.disconnect();
        sandbox = await initEvmSandbox();
        return sendJson(res, 200, await getStateSnapshot());
      }

      if (url.pathname === '/api/trigger' && req.method === 'POST') {
        const body = await readBody(req);
        const priceUSD = Math.max(100, Number(body.priceUSD ?? 1850));
        const volatilityBps = Math.max(0, Math.min(10000, Math.round(Number(body.volatilityBps ?? 920))));
        const liquidityDepthUSD = Math.max(1000, Math.round(Number(body.liquidityDepthUSD ?? 300000)));
        const priceE8 = BigInt(Math.round(priceUSD * 1e8));

        const t0 = performance.now();
        const originTx = await sandbox.oracle.publishMarketSnapshot(
          WETH_ADDR,
          priceE8,
          BigInt(volatilityBps),
          BigInt(liquidityDepthUSD),
        );
        const originReceipt = await originTx.wait();
        const log = originReceipt.logs[0];

        const logRecord = {
          chain_id: UNICHAIN_SEPOLIA_ID,
          _contract: log.address,
          topic_0: BigInt(log.topics[0]),
          topic_1: BigInt(log.topics[1]),
          topic_2: 0n,
          topic_3: 0n,
          data: log.data,
          block_number: BigInt(log.blockNumber),
          op_code: 3n,
          block_hash: BigInt(log.blockHash),
          tx_hash: BigInt(log.transactionHash),
          log_index: BigInt(log.index),
        };

        const reactTx = await sandbox.mockSys.dispatchLog(await sandbox.reactive.getAddress(), logRecord);
        const reactReceipt = await reactTx.wait();
        const callbackRequestedEvt = reactReceipt.logs
          .map((l) => {
            try {
              return sandbox.mockSys.interface.parseLog(l);
            } catch {
              return null;
            }
          })
          .find((e) => e && e.name === 'CallbackRequested');

        let callbackTxHash = null;
        let callbackSuccess = false;
        let finalBlockNumber = reactReceipt.blockNumber;
        if (callbackRequestedEvt) {
          const cbIdx = sandbox.nextCallbackIndex ?? 0n;
          sandbox.nextCallbackIndex = cbIdx + 1n;
          const cbTx = await sandbox.mockSys.deliverCallback(cbIdx);
          const cbReceipt = await cbTx.wait();
          callbackTxHash = cbReceipt.hash;
          callbackSuccess = cbReceipt.status === 1;
          finalBlockNumber = cbReceipt.blockNumber;
        }

        const elapsedMs = Math.round((performance.now() - t0) * 100) / 100;
        const riskScoreBps = Number(
          await sandbox.reactive.computeRiskScoreBps(
            priceE8,
            BigInt(volatilityBps),
            BigInt(liquidityDepthUSD),
            { blockTag: finalBlockNumber },
          ),
        );

        const entry = {
          timestamp: new Date().toISOString(),
          priceUSD,
          volatilityBps,
          liquidityDepthUSD,
          riskScoreBps,
          callbackDispatched: Boolean(callbackRequestedEvt),
          callbackSuccess,
          originTxHash: originReceipt.hash,
          reactiveTxHash: reactReceipt.hash,
          callbackTxHash,
          localEvmLoopMs: elapsedMs,
          estimatedTestnetLoopMs: 2200, // Unichain 1000ms + Reactive Lasna 1000ms + Base Sepolia 200ms
        };
        sandbox.history.push(entry);

        const snapshot = await getStateSnapshot(finalBlockNumber);
        return sendJson(res, 200, { ok: true, execution: entry, state: snapshot });
      }

      // Static files
      let targetPath = path.join(WEB_DIR, url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/+/, ''));
      if (url.pathname === '/SLIDES.pdf') targetPath = path.join(__dirname, 'SLIDES.pdf');
      if (!targetPath.startsWith(__dirname) || !fs.existsSync(targetPath) || fs.statSync(targetPath).isDirectory()) {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not found');
        return;
      }
      const ext = path.extname(targetPath).toLowerCase();
      res.writeHead(200, { 'Content-Type': MIME_TYPES[ext] || 'application/octet-stream' });
      fs.createReadStream(targetPath).pipe(res);
    } catch (err) {
      sendJson(res, 500, { ok: false, error: err.message });
    }
  });

  server.cleanup = async () => {
    await sandbox.ganacheProvider.disconnect();
  };

  return server;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  const PORT = Number(process.env.PORT || 8098);
  const server = await createServer();
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`OmniSentinel RSC running at http://127.0.0.1:${PORT}`);
  });
}
