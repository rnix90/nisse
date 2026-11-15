// SPDX-License-Identifier: GPL-2.0-or-later
//! A loopback test client for device pairing (ledger N-221): pairs with a code and makes signed calls to the daemon on the
//! session bus, the way a phone would over some other transport. A development tool, not shipped.
//!
//!   device_probe pair SEED CODE                       prints the device id
//!   device_probe call SEED DEVICE_ID METHOD ARGS_JSON prints the result (or the refusal, exit 1)
//!
//! SEED is a number 0 to 255: the private key is that byte repeated 32 times, so a test can use the same key twice.

use std::io::Read;

use ed25519_dalek::{Signer, SigningKey};
use nisse_proto::SignedRequest;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn random_hex(n: usize) -> String {
    let mut bytes = vec![0u8; n];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut bytes);
    }
    hex(&bytes)
}

fn key(seed: &str) -> SigningKey {
    let byte: u8 = seed.parse().expect("SEED is a number 0 to 255");
    SigningKey::from_bytes(&[byte; 32])
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let connection = zbus::Connection::session().await.expect("session bus");
    let proxy = zbus::Proxy::new(
        &connection,
        "org.nisse.Daemon1",
        "/org/nisse/Daemon1",
        "org.nisse.Daemon1",
    )
    .await
    .expect("the daemon is not on the bus");
    match args.get(1).map(String::as_str) {
        Some("pair") if args.len() == 4 => {
            let public = hex(key(&args[2]).verifying_key().as_bytes());
            match proxy
                .call::<_, _, String>("CompletePairing", &(args[3].as_str(), public))
                .await
            {
                Ok(device) => {
                    let v: serde_json::Value = serde_json::from_str(&device).unwrap();
                    println!("{}", v["id"].as_str().unwrap());
                }
                Err(e) => {
                    eprintln!("refused: {e}");
                    std::process::exit(1);
                }
            }
        }
        Some("call") if args.len() == 6 => {
            let ts_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis() as i64;
            let mut req = SignedRequest {
                device_id: args[3].clone(),
                ts_ms,
                nonce: random_hex(16),
                method: args[4].clone(),
                args_json: args[5].clone(),
                signature_hex: String::new(),
            };
            req.signature_hex = hex(&key(&args[2]).sign(&req.message()).to_bytes());
            match proxy
                .call::<_, _, String>("DeviceCall", &(serde_json::to_string(&req).unwrap(),))
                .await
            {
                Ok(result) => println!("{result}"),
                Err(e) => {
                    eprintln!("refused: {e}");
                    std::process::exit(1);
                }
            }
        }
        _ => {
            eprintln!("usage: device_probe pair SEED CODE | device_probe call SEED DEVICE_ID METHOD ARGS_JSON");
            std::process::exit(2);
        }
    }
}
