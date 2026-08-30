//! 真实 ECH 握手验证（本机网络 = 墙内，2026-08-30）:
//!
//! 背景: 探测页此前报告 `ech: ok`, 但主路径（真 config + ECH）失败。
//! Python 全套 TLS 矩阵已确认: 104.18.10.118 + SNI=cloudflare-ech.com
//! 普通 ClientHello 握手成功（0.5s），而同一 IP + SNI=app-api.pixiv.net
//! 被 RST(0.3s)。封锁维度有依赖：IP × SNI 组合。
//!
//! 本测试回答最后一个问题：带 ECH 扩展的 ClientHello
//! (outer SNI=cloudflare-ech.com, inner=app-api.pixiv.net) 是否也通过？
//!
//! 运行: cargo test --test ech_live_handshake -- --ignored --nocapture

use rustls::client::EchMode;
use rustls::pki_types::{CertificateDer, ServerName};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::{Duration, Instant};

const FRONT_IP: &str = "104.18.10.118";
const OUTER_SNI: &str = "cloudflare-ech.com";
const INNER_SNI: &str = "app-api.pixiv.net";

/// 真实获取（2026-08-30, Cloudflare DoH / type 65）:
/// 71-byte ECHConfigList, public_name=cloudflare-ech.com,
/// ipv4hint=104.18.10.118,104.18.11.118
const ECH_CONFIG_HEX: &str = "0045fe0d0041fe0020002063dd941a6b3991e110ca81b46415b0c30970bb93fab6cc15f0a46acddaa1bf2d0004000100010012636c6f7564666c6172652d6563682e636f6d0000";

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

fn root_store() -> rustls::RootCertStore {
    let mut roots = rustls::RootCertStore::empty();
    for cert in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
        roots
            .add(CertificateDer::from(cert.as_ref().to_vec()))
            .unwrap();
    }
    roots
}

fn run(ech: bool) -> Result<String, String> {
    let addr: SocketAddr = format!("{FRONT_IP}:443").parse().unwrap();
    let mut tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(5))
        .map_err(|e| format!("tcp connect: {e}"))?;
    tcp.set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    tcp.set_write_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| format!("set_write_timeout: {e}"))?;

    let inner_sni: ServerName<'static> =
        ServerName::try_from(INNER_SNI.to_string()).map_err(|e| format!("sni: {e:?}"))?;
    let outer_sni: ServerName<'static> =
        ServerName::try_from(OUTER_SNI.to_string()).map_err(|e| format!("sni: {e:?}"))?;

    // ECH: rustls 用 inner ServerName 构建连接, 从 ECHConfig 的
    // public_name 取 outer SNI 写进 ClientHello。
    // 无 ECH: 直接用 SNI=outer（与 Python 矩阵相同的对照路径）。
    let server_name = if ech { inner_sni.clone() } else { outer_sni.clone() };

    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());

    let mut cfg = if ech {
        let ech_cfg = rustls::client::EchConfig::new(
            rustls::pki_types::EchConfigListBytes::from(hex_to_bytes(ECH_CONFIG_HEX)),
            rustls::crypto::aws_lc_rs::hpke::ALL_SUPPORTED_SUITES,
        )
        .map_err(|e| format!("ech config parse: {e:?}"))?;
        // with_ech 在 WantsVersions 阶段调用, 隐式固定 TLS 1.3。
        rustls::ClientConfig::builder_with_provider(provider)
            .with_ech(EchMode::from(ech_cfg))
            .map_err(|e| format!("with_ech (echo mode): {e:?}"))?
            .with_root_certificates(Arc::new(root_store()))
            .with_no_client_auth()
    } else {
        rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("safe protocol versions")
            .with_root_certificates(Arc::new(root_store()))
            .with_no_client_auth()
    };
    cfg.alpn_protocols = vec![b"http/1.1".to_vec()];

    let mut conn = rustls::ClientConnection::new(Arc::new(cfg), server_name)
        .map_err(|e| format!("client connection: {e}"))?;

    let mut tls = rustls::Stream::new(&mut conn, &mut tcp);
    let start = Instant::now();
    let req = format!(
        "GET /v1/illust/prime HTTP/1.1\r\nHost: {INNER_SNI}\r\nUser-Agent: rustls-ech-probe\r\nConnection: close\r\n\r\n"
    );
    tls.write_all(req.as_bytes())
        .map_err(|e| format!("write(handshake, {start:?}): {e}"))?;
    let mut buf = [0u8; 4096];
    let n = tls
        .read(&mut buf)
        .map_err(|e| format!("read(handshake, {:?}): {e}", start.elapsed()))?;
    let elapsed = start.elapsed();
    let head = String::from_utf8_lossy(&buf[..n.min(160)]).to_string();
    Ok(format!("OK in {elapsed:?}, first bytes: {head:?}"))
}

#[test]
#[ignore]
fn real_ech_handshake_against_front() {
    println!("--- plain ClientHello / SNI={OUTER_SNI}（对照） ---");
    match run(false) {
        Ok(msg) => println!("plain: {msg}"),
        Err(e) => println!("plain: FAIL {e}"),
    }
    println!("--- ECH ClientHello / inner SNI={INNER_SNI} ---");
    match run(true) {
        Ok(msg) => println!("ECH: {msg}"),
        Err(e) => println!("ECH: FAIL {e}"),
    }
    println!(
        "结论: ECH 成功 => 探测页 echAvailable 可信; \
         ECH 失败 => ECH 路径在本网络不可用（GFW 识别 ECH 扩展或 ECH 握手失败）。"
    );
}
