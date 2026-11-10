# The Deno release the runtime embeds: every pin that moves with it is here.
# DENO_VERSION's declarations are what rule code is checked against, and its
# license is in THIRD_PARTY_NOTICES (Tools/Notices). A test in src/worker.rs
# fails when the linked deno_runtime is not DENO_RUNTIME_VERSION, the one that
# release is built on (its Cargo.toml), so the exact pin in
# buck2/third_party/rust/Cargo.toml cannot move without this version and the
# hashes below.
DENO_VERSION = "2.9.8"

DENO_RUNTIME_VERSION = "0.268.0"

# The SHA-256 of the release's LICENSE.md.
DENO_LICENSE = "f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588"

# Deno's own libraries, unchanged, at that release.
DENO_LIBRARIES = {
    "lib.deno.ns.d.ts": "8e8348a4c8762c5cedfe4c9b9673ba01f79ea49b9f1d3b9a91bbe2e69c316504",
    "lib.deno.shared_globals.d.ts": "dd15d55184d1158f1bcdf849f392293ca2dbfac6f2918f780b90b6fc0607bda4",
    "lib.deno.unstable.d.ts": "5993271718a0562ea8725884c12d0cd5f97c5e7174cede5540899fee529b4b6a",
    "lib.deno.window.d.ts": "65deeb96e59b827bda5fcbeb999c0b8ded931870abb40e7a5b1a58623c46d6ae",
    "lib.deno_broadcast_channel.d.ts": "b86ebfee46d72bdb537b64f9cb459e1af87de6aa0c66d1d13578f9c62c1fd9a2",
    "lib.deno_cache.d.ts": "50566f60b3f769e542e2794a1649ac3efd261bb9c1ef818c838cef7544d9daca",
    "lib.deno_canvas.d.ts": "d2799497f1fc7c6ae9ea59666c84e7ed253d4b2893c50cf454e1360958ed1291",
    "lib.deno_console.d.ts": "28db5d664ef4451e1c2c520b4a10336c275add9a740b53b3eeb63c052980ce97",
    "lib.deno_crypto.d.ts": "b7deddab4103d60043f869cd2532571bd496ba37e623b779733114de824b342d",
    "lib.deno_fetch.d.ts": "5487bfb2636096851007b5fd1b57d2bef9317ccb17ae66c725eaa44fef559435",
    "lib.deno_net.d.ts": "6444509e83bfb0de78e4c435ceb8b9f33f4fe12f2540b2bbf618ddc210da75a9",
    "lib.deno_url.d.ts": "34b36a51db5d10fcb509e12c7c7a22272cc1230b67e2cda31521ae411af7e3fc",
    "lib.deno_web.d.ts": "dc26fb30cf8d2a23db534c335491b22ecab03d05d8ac573b155d46b2fca7d7d1",
    "lib.deno_webgpu.d.ts": "cf8488b888b6c29c8bda1f7129e1d77fd7f299b22a0d7eadd035cad48bb1a662",
    "lib.deno_websocket.d.ts": "a523a4cec5c6909f9fff1798e21a49dabf36e64f619cf6f0635fe56caf0319c5",
    "lib.deno_webstorage.d.ts": "1a9528f05d15fa448b9b4d0fd2295cf98a8b66400248e3ff9f0bf3fbb34dd49f",
}
