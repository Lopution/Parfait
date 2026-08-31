//! 用 rhttp 同款 reqwest+rustls 栈复现「主路径」ECH 请求。
//!
//! 与 ech_live_handshake.rs 的区别：
//! - 走 reqwest (rhttp 的传输层) + rustls-preconfigured tls (rhttp 的
//!   tls_backend_preconfigured 路径)
//! - http2 优先 ALPN (rhttp settingsFor: HttpVersionPref.http2)
//! - DNS override: app-api.pixiv.net -> front IP (rhttp DnsSettings.static)
//!
//! 回答: 网络可达(上一个实验已证明)但主路径失败 —— 是 http2/ALPN、
//! reqwest 层的问题, 还是别的问题？

use std::sync::Arc;
use std::time::Duration;

const FRONT_IP: &str = "104.18.10.118";
const ECH_CONFIG_HEX: &str = "0045fe0d0041fe0020002063dd941a6b3991e110ca81b46415b0c30970bb93fab6cc15f0a46acddaa1bf2d0004000100010012636c6f7564666c6172652d6563682e636f6d0000";

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

fn tls_config() -> rustls::ClientConfig {
    let ech_cfg = rustls::client::EchConfig::new(
        rustls::pki_types::EchConfigListBytes::from(hex_to_bytes(ECH_CONFIG_HEX)),
        rustls::crypto::aws_lc_rs::hpke::ALL_SUPPORTED_SUITES,
    )
    .expect("ech config");
    let mut roots = rustls::RootCertStore::empty();
    for cert in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
        roots
            .add(rustls::pki_types::CertificateDer::from(cert.as_ref().to_vec()))
            .unwrap();
    }
    let mut c = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_ech(rustls::client::EchMode::from(ech_cfg))
    .expect("with_ech")
    .with_root_certificates(Arc::new(roots))
    .with_no_client_auth();
    c.alpn_protocols = vec![b"h2".to_vec()];
    c
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::builder()
        .use_preconfigured_tls(tls_config())
        // rhttp DnsSettings.static(overrides: {destinationHost: [front]})
        .resolve("app-api.pixiv.net", format!("{FRONT_IP}:443").parse()?)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(12))
        .build()?;

    println!("[http2-preferred] GET https://app-api.pixiv.net/v1/illust/prime");
    let resp = client
        .get("https://app-api.pixiv.net/v1/illust/prime")
        .header("user-agent", "reqwest-ech-probe")
        .send()
        .await;
    match resp {
        Ok(r) => {
            println!(
                "OK: status={} http_version={:?} server?",
                r.status(),
                r.version()
            );
            let body = r.text().await;
            println!("body(preview): {:?}", &body.unwrap_or_default()[..200.min(200)]);
        }
        Err(e) => {
            println!("FAIL: {e}");
            let mut src = Some(&e as &dyn std::error::Error);
            while let Some(s) = src {
                println!("  caused by: {s}");
                src = s.source();
            }
        }
    }
    Ok(())
}
