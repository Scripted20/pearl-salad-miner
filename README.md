# pearl-salad-miner

Minimal Pearl (PRL) miner image for SaladCloud NVIDIA GPUs: krig-miner (Kryptex, pinned by sha256) plus a watchdog entrypoint that reallocates unhealthy nodes through the Salad IMDS.

Run with `WALLET=prl1...` set. Optional: `POOLS`, `PORT`, `STARTUP_GRACE`, `NO_POOL_TIMEOUT`, `LOG_STALE_TIMEOUT`, `MIN_GPU_UTIL`, `GPU_IDLE_TIMEOUT`, `STATUS_EVERY`, `LOG_LEVEL`, `OK_REGEX`.
