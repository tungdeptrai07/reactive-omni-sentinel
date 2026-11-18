import hashlib
import unittest


def simulate_ireactive_callback(observed_price_usd: int, volatility_bps: int, stop_loss_usd: int = 2950) -> dict:
    triggered = observed_price_usd <= stop_loss_usd or volatility_bps >= 850
    selector = hashlib.sha256(b"executeEmergencyDeleverage(address,uint256,uint256)").hexdigest()[:8]
    return {
        "origin_chain_id": 1301,
        "dest_chain_id": 84532,
        "triggered": triggered,
        "callback_selector": f"0x{selector}" if triggered else None,
    }


class ReactiveSentinelTests(unittest.TestCase):
    def test_stop_loss_triggers_cross_chain_callback(self) -> None:
        res = simulate_ireactive_callback(observed_price_usd=2840, volatility_bps=400)
        self.assertTrue(res["triggered"])
        self.assertEqual(res["dest_chain_id"], 84532)

    def test_safe_price_no_callback(self) -> None:
        res = simulate_ireactive_callback(observed_price_usd=3200, volatility_bps=300)
        self.assertFalse(res["triggered"])
        self.assertIsNone(res["callback_selector"])


if __name__ == "__main__":
    unittest.main()
