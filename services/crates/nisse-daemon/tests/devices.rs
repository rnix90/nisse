// SPDX-License-Identifier: GPL-2.0-or-later
//! Device pairing, daemon side (ledger N-221): a one-time code pairs a device, which then signs every call with its own
//! key; the daemon keeps only public keys, refuses unpaired, revoked, stale, replayed and tampered calls, and says who
//! did what. Mechanism: Ed25519 signatures (the build VM fetched and built `ed25519-dalek` in the spike; the daemon only
//! verifies, so a stolen state file cannot sign anything).

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use ed25519_dalek::{Signer, SigningKey};
use nisse_daemon::devices::{AuthError, DeviceRegistry, PairError, Role, SignedRequest};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-devices-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir.join("devices.json")
}

/// A registry on a clock the test moves by hand (unix milliseconds).
fn registry() -> (DeviceRegistry, Arc<AtomicI64>) {
    let now = Arc::new(AtomicI64::new(1_794_700_000_000));
    let clock = Arc::clone(&now);
    (
        DeviceRegistry::in_memory().with_clock(Arc::new(move || clock.load(Ordering::SeqCst))),
        now,
    )
}

fn key(seed: u8) -> SigningKey {
    SigningKey::from_bytes(&[seed; 32])
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn public_hex(k: &SigningKey) -> String {
    hex(k.verifying_key().as_bytes())
}

/// What a client does: sign `method` and `args` with its key.
fn signed(k: &SigningKey, device_id: &str, ts_ms: i64, nonce: &str, method: &str, args_json: &str) -> SignedRequest {
    let mut req = SignedRequest {
        device_id: device_id.into(),
        ts_ms,
        nonce: nonce.into(),
        method: method.into(),
        args_json: args_json.into(),
        signature_hex: String::new(),
    };
    req.signature_hex = hex(&k.sign(&req.message()).to_bytes());
    req
}

fn pair(reg: &DeviceRegistry, name: &str, role: Role, k: &SigningKey) -> nisse_daemon::devices::Device {
    let offer = reg.start_pairing(name, role).unwrap();
    reg.complete_pairing(&offer.code, &public_hex(k)).unwrap()
}

// ---- pairing

#[test]
fn a_pairing_gives_an_eight_digit_code_that_lasts_five_minutes() {
    let (reg, now) = registry();
    let offer = reg.start_pairing("Bert's phone", Role::Full).unwrap();
    assert_eq!(offer.code.len(), 8);
    assert!(offer.code.chars().all(|c| c.is_ascii_digit()), "{}", offer.code);
    assert_eq!(offer.expires_at, now.load(Ordering::SeqCst) / 1000 + 300);
}

#[test]
fn the_right_code_registers_the_device_once() {
    let (reg, _) = registry();
    let phone = key(1);
    let offer = reg.start_pairing("phone", Role::Full).unwrap();
    let device = reg.complete_pairing(&offer.code, &public_hex(&phone)).unwrap();
    assert_eq!(device.name, "phone");
    assert_eq!(device.role, Role::Full);
    assert_eq!(device.id.len(), 32);
    assert_eq!(device.public_key_hex, public_hex(&phone));
    assert!(device.revoked_at.is_none());
    assert_eq!(reg.list().len(), 1);
    assert_eq!(
        reg.complete_pairing(&offer.code, &public_hex(&key(2))),
        Err(PairError::NoPairing),
        "a code works once"
    );
}

#[test]
fn a_wrong_code_is_refused_and_five_wrong_ones_cancel_the_pairing() {
    let (reg, _) = registry();
    let offer = reg.start_pairing("phone", Role::Full).unwrap();
    let wrong = if offer.code == "00000000" {
        "11111111"
    } else {
        "00000000"
    };
    for left in (0..5).rev() {
        let err = reg.complete_pairing(wrong, &public_hex(&key(1))).unwrap_err();
        if left > 0 {
            assert_eq!(err, PairError::WrongCode { attempts_left: left });
        } else {
            assert_eq!(err, PairError::TooManyTries);
        }
    }
    assert_eq!(
        reg.complete_pairing(&offer.code, &public_hex(&key(1))),
        Err(PairError::NoPairing),
        "even the right code is dead after too many tries"
    );
    assert!(reg.list().is_empty());
}

#[test]
fn a_code_that_has_expired_is_refused() {
    let (reg, now) = registry();
    let offer = reg.start_pairing("phone", Role::Full).unwrap();
    now.fetch_add(301_000, Ordering::SeqCst);
    assert_eq!(
        reg.complete_pairing(&offer.code, &public_hex(&key(1))),
        Err(PairError::Expired)
    );
    assert!(reg.list().is_empty());
}

#[test]
fn a_new_pairing_replaces_the_old_one_and_a_pairing_can_be_cancelled() {
    let (reg, _) = registry();
    let first = reg.start_pairing("a", Role::Full).unwrap();
    let second = reg.start_pairing("b", Role::Approver).unwrap();
    if first.code != second.code {
        assert!(reg.complete_pairing(&first.code, &public_hex(&key(1))).is_err());
    }
    reg.cancel_pairing();
    assert_eq!(
        reg.complete_pairing(&second.code, &public_hex(&key(1))),
        Err(PairError::NoPairing)
    );
}

#[test]
fn the_role_chosen_at_pairing_is_kept() {
    let (reg, _) = registry();
    let device = pair(&reg, "watch", Role::Approver, &key(3));
    assert_eq!(device.role, Role::Approver);
    assert_eq!(Role::parse("full"), Some(Role::Full));
    assert_eq!(Role::parse("approver"), Some(Role::Approver));
    assert_eq!(Role::parse("root"), None);
    assert_eq!(Role::Approver.as_str(), "approver");
}

#[test]
fn a_key_that_is_not_a_key_is_refused_and_so_is_the_same_key_twice() {
    let (reg, _) = registry();
    for bad in ["", "zz", &"ab".repeat(31), &"ab".repeat(33), &"g".repeat(64)] {
        let offer = reg.start_pairing("p", Role::Full).unwrap();
        assert_eq!(
            reg.complete_pairing(&offer.code, bad),
            Err(PairError::BadKey),
            "{bad:?}"
        );
    }
    pair(&reg, "first", Role::Full, &key(5));
    let offer = reg.start_pairing("second", Role::Full).unwrap();
    assert_eq!(
        reg.complete_pairing(&offer.code, &public_hex(&key(5))),
        Err(PairError::BadKey),
        "one key, one device"
    );
}

#[test]
fn the_device_name_must_be_a_short_plain_label() {
    let (reg, _) = registry();
    assert!(reg.start_pairing("", Role::Full).is_err());
    assert!(reg.start_pairing(&"x".repeat(41), Role::Full).is_err());
    assert!(reg.start_pairing("line\nbreak", Role::Full).is_err());
    assert!(reg.start_pairing("  phone  ", Role::Full).is_ok());
}

// ---- signed calls

#[test]
fn a_call_signed_by_a_paired_device_is_accepted_and_marks_it_seen() {
    let (reg, now) = registry();
    let phone = key(1);
    let device = pair(&reg, "phone", Role::Full, &phone);
    now.fetch_add(5_000, Ordering::SeqCst);
    let req = signed(
        &phone,
        &device.id,
        now.load(Ordering::SeqCst),
        "00112233445566778899aabbccddeeff",
        "Approve",
        r#"["a1"]"#,
    );
    let who = reg.authenticate(&req).unwrap();
    assert_eq!(who.id, device.id);
    assert_eq!(who.name, "phone");
    assert_eq!(reg.list()[0].last_seen, Some(now.load(Ordering::SeqCst) / 1000));
}

#[test]
fn an_unknown_device_is_refused() {
    let (reg, now) = registry();
    let req = signed(
        &key(1),
        &"0".repeat(32),
        now.load(Ordering::SeqCst),
        "00112233445566778899aabbccddeeff",
        "Approve",
        "[]",
    );
    assert_eq!(reg.authenticate(&req), Err(AuthError::UnknownDevice));
}

#[test]
fn a_device_that_was_not_paired_cannot_borrow_anothers_id() {
    let (reg, now) = registry();
    let device = pair(&reg, "phone", Role::Full, &key(1));
    let req = signed(
        &key(9),
        &device.id,
        now.load(Ordering::SeqCst),
        "00112233445566778899aabbccddeeff",
        "Approve",
        "[]",
    );
    assert_eq!(reg.authenticate(&req), Err(AuthError::BadSignature));
}

#[test]
fn changing_anything_that_was_signed_breaks_the_signature() {
    let (reg, now) = registry();
    let phone = key(1);
    let device = pair(&reg, "phone", Role::Full, &phone);
    let ts = now.load(Ordering::SeqCst);
    let good = signed(
        &phone,
        &device.id,
        ts,
        "00112233445566778899aabbccddeeff",
        "Approve",
        r#"["a1"]"#,
    );

    let mut other_args = good.clone();
    other_args.args_json = r#"["a2"]"#.into();
    assert_eq!(reg.authenticate(&other_args), Err(AuthError::BadSignature));
    let mut other_method = good.clone();
    other_method.method = "Deny".into();
    assert_eq!(reg.authenticate(&other_method), Err(AuthError::BadSignature));
    let mut other_time = good.clone();
    other_time.ts_ms += 1;
    assert_eq!(reg.authenticate(&other_time), Err(AuthError::BadSignature));
    let mut other_nonce = good.clone();
    other_nonce.nonce = "ffeeddccbbaa99887766554433221100".into();
    assert_eq!(reg.authenticate(&other_nonce), Err(AuthError::BadSignature));
    let mut junk = good.clone();
    junk.signature_hex = "not hex".into();
    assert!(matches!(reg.authenticate(&junk), Err(AuthError::BadRequest(_))));
    assert!(reg.authenticate(&good).is_ok(), "the untouched call is fine");
}

#[test]
fn the_same_call_cannot_be_sent_twice() {
    let (reg, now) = registry();
    let phone = key(1);
    let device = pair(&reg, "phone", Role::Full, &phone);
    let req = signed(
        &phone,
        &device.id,
        now.load(Ordering::SeqCst),
        "00112233445566778899aabbccddeeff",
        "EngageKillSwitch",
        r#"["x"]"#,
    );
    assert!(reg.authenticate(&req).is_ok());
    assert_eq!(
        reg.authenticate(&req),
        Err(AuthError::Replay),
        "a recorded call replayed later is refused"
    );
    let next = signed(
        &phone,
        &device.id,
        now.load(Ordering::SeqCst),
        "aabbccddeeff00112233445566778899",
        "EngageKillSwitch",
        r#"["x"]"#,
    );
    assert!(reg.authenticate(&next).is_ok(), "a new nonce is a new call");
}

#[test]
fn a_call_with_an_old_or_future_time_is_refused() {
    let (reg, now) = registry();
    let phone = key(1);
    let device = pair(&reg, "phone", Role::Full, &phone);
    let t = now.load(Ordering::SeqCst);
    for (offset, ok) in [
        (-59_000, true),
        (59_000, true),
        (-61_000, false),
        (61_000, false),
        (-3_600_000, false),
    ] {
        let nonce = format!("{:032x}", (offset + 4_000_000) as u128);
        let req = signed(&phone, &device.id, t + offset, &nonce, "GetUsage", "[]");
        let result = reg.authenticate(&req);
        if ok {
            assert!(result.is_ok(), "{offset}: {result:?}");
        } else {
            assert_eq!(result, Err(AuthError::Stale), "{offset}");
        }
    }
}

#[test]
fn the_replay_memory_does_not_grow_for_ever() {
    let (reg, now) = registry();
    let phone = key(1);
    let device = pair(&reg, "phone", Role::Full, &phone);
    for i in 0..300u128 {
        let nonce = format!("{i:032x}");
        let req = signed(&phone, &device.id, now.load(Ordering::SeqCst), &nonce, "GetUsage", "[]");
        assert!(reg.authenticate(&req).is_ok());
    }
    assert_eq!(reg.remembered_nonces(), 300);
    now.fetch_add(200_000, Ordering::SeqCst);
    let req = signed(
        &phone,
        &device.id,
        now.load(Ordering::SeqCst),
        &format!("{:032x}", 999u128),
        "GetUsage",
        "[]",
    );
    assert!(reg.authenticate(&req).is_ok());
    assert_eq!(
        reg.remembered_nonces(),
        1,
        "calls older than the window are forgotten: they would be refused as stale anyway"
    );
}

#[test]
fn a_nonce_that_is_not_a_nonce_is_refused() {
    let (reg, now) = registry();
    let phone = key(1);
    let device = pair(&reg, "phone", Role::Full, &phone);
    for bad in ["", "short", &"a".repeat(65), "has space in it 00112233445566"] {
        let req = signed(&phone, &device.id, now.load(Ordering::SeqCst), bad, "GetUsage", "[]");
        assert!(
            matches!(reg.authenticate(&req), Err(AuthError::BadRequest(_))),
            "{bad:?}"
        );
    }
}

// ---- revoking, listing, keeping

#[test]
fn a_revoked_device_is_refused_at_once_and_stays_listed() {
    let (reg, now) = registry();
    let phone = key(1);
    let device = pair(&reg, "phone", Role::Full, &phone);
    let req = signed(
        &phone,
        &device.id,
        now.load(Ordering::SeqCst),
        "00112233445566778899aabbccddeeff",
        "GetUsage",
        "[]",
    );
    assert!(reg.authenticate(&req).is_ok());
    assert!(reg.revoke(&device.id).is_ok());
    let again = signed(
        &phone,
        &device.id,
        now.load(Ordering::SeqCst),
        "aabbccddeeff00112233445566778899",
        "GetUsage",
        "[]",
    );
    assert_eq!(reg.authenticate(&again), Err(AuthError::Revoked));
    let listed = reg.list();
    assert_eq!(listed.len(), 1);
    assert!(
        listed[0].revoked_at.is_some(),
        "the record stays so the audit log still makes sense"
    );
    assert!(reg.revoke("nope").is_err());
}

#[test]
fn a_revoked_devices_key_can_be_paired_again_as_a_new_device() {
    let (reg, _) = registry();
    let phone = key(1);
    let old = pair(&reg, "phone", Role::Full, &phone);
    reg.revoke(&old.id).unwrap();
    let new = pair(&reg, "phone again", Role::Full, &phone);
    assert_ne!(new.id, old.id);
    assert_eq!(reg.list().len(), 2);
}

#[test]
fn devices_survive_a_restart_with_their_role_revocation_and_keys() {
    let path = scratch("persist");
    let (a, b) = (key(1), key(2));
    {
        let (reg, warning) = DeviceRegistry::open(path.clone());
        assert!(warning.is_none());
        let phone = pair(&reg, "phone", Role::Full, &a);
        let watch = pair(&reg, "watch", Role::Approver, &b);
        reg.revoke(&watch.id).unwrap();
        assert_ne!(phone.id, watch.id);
    }
    let (reg, warning) = DeviceRegistry::open(path.clone());
    assert!(warning.is_none());
    let devices = reg.list();
    assert_eq!(devices.len(), 2);
    assert_eq!((devices[0].name.as_str(), devices[0].role), ("phone", Role::Full));
    assert!(devices[0].revoked_at.is_none());
    assert_eq!(devices[1].role, Role::Approver);
    assert!(devices[1].revoked_at.is_some());
    // the phone still authenticates with its own key after the restart
    let now = devices[0].created_at * 1000;
    let reg = reg.with_clock(Arc::new(move || now));
    let req = signed(
        &a,
        &devices[0].id,
        now,
        "00112233445566778899aabbccddeeff",
        "GetUsage",
        "[]",
    );
    assert!(reg.authenticate(&req).is_ok());
    let text = fs::read_to_string(path).unwrap();
    assert!(
        !text.contains("private") && !text.contains("secret"),
        "only public keys are stored"
    );
}

#[test]
fn a_damaged_device_file_is_set_aside_and_no_device_is_trusted() {
    let path = scratch("damaged");
    fs::write(&path, "{ not json").unwrap();
    let (reg, warning) = DeviceRegistry::open(path.clone());
    assert!(warning.unwrap().contains("devices"));
    assert!(reg.list().is_empty(), "when in doubt nobody is paired");
    assert!(path.with_file_name("devices.json.bad").exists());
}

#[test]
fn an_active_pairing_is_not_written_to_disk() {
    let path = scratch("code-not-saved");
    let (reg, _) = DeviceRegistry::open(path.clone());
    let offer = reg.start_pairing("phone", Role::Full).unwrap();
    let text = fs::read_to_string(&path).unwrap_or_default();
    assert!(!text.contains(&offer.code), "the one-time code lives in memory only");
}

#[test]
fn the_message_that_is_signed_names_the_protocol_version_and_every_field() {
    let req = SignedRequest {
        device_id: "d".into(),
        ts_ms: 5,
        nonce: "n".into(),
        method: "Approve".into(),
        args_json: r#"["a"]"#.into(),
        signature_hex: String::new(),
    };
    assert_eq!(req.message(), b"nisse-v1\nd\n5\nn\nApprove\n[\"a\"]".to_vec());
}
