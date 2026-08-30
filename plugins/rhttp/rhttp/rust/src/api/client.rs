use crate::api::error::RhttpError;
use crate::api::http::HttpVersionPref;
use crate::utils::socket_addr::SocketAddrDigester;
use chrono::Duration;
use flutter_rust_bridge::{frb, DartFnFuture};
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::{tls, Certificate};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::str::FromStr;
use std::sync::Arc;
pub use tokio_util::sync::CancellationToken;

pub struct ClientSettings {
    pub cookie_settings: Option<CookieSettings>,
    pub http_version_pref: HttpVersionPref,
    pub timeout_settings: Option<TimeoutSettings>,
    pub throw_on_status_code: bool,
    pub proxy_settings: Option<ProxySettings>,
    pub redirect_settings: Option<RedirectSettings>,
    pub tls_settings: Option<TlsSettings>,
    pub dns_settings: Option<DnsSettings>,
    pub user_agent: Option<String>,
}

pub struct CookieSettings {
    pub store_cookies: bool,
}

pub enum ProxySettings {
    NoProxy,
    CustomProxyList(Vec<CustomProxy>),
}

pub struct CustomProxy {
    pub url: String,
    pub condition: ProxyCondition,
}

pub enum ProxyCondition {
    Http,
    Https,
    All,
}

pub enum RedirectSettings {
    NoRedirect,
    LimitedRedirects(i32),
}

pub struct TimeoutSettings {
    pub timeout: Option<Duration>,
    pub connect_timeout: Option<Duration>,
    pub keep_alive_timeout: Option<Duration>,
    pub keep_alive_ping: Option<Duration>,
}

pub struct TlsSettings {
    pub root_cert_source: RootCertSource,
    pub trusted_root_certificates: Vec<Vec<u8>>,
    pub verify_certificates: bool,
    pub client_certificate: Option<ClientCertificate>,
    pub min_tls_version: Option<TlsVersion>,
    pub max_tls_version: Option<TlsVersion>,
    pub sni: bool,
    /// ECH config list bytes (from the `ech` SvcParam of an HTTPS RR), as
    /// produced by the Dart `DohResolver`. When set, the TLS client is
    /// created with rustls `EchMode::Enable` and injected via reqwest
    /// `tls_backend_preconfigured`.
    ///
    /// This is the ONLY functional fork change vs upstream: passing
    /// `None` yields behavior identical to upstream 0.18.0.
    pub ech_config_list: Option<Vec<u8>>,
}

pub enum RootCertSource {
    Platform,
    Webpki,
    None,
}

pub enum DnsSettings {
    StaticDns(StaticDnsSettings),
    DynamicDns(DynamicDnsSettings),
}

pub struct StaticDnsSettings {
    pub overrides: HashMap<String, Vec<String>>,
    pub fallback: Option<String>,
}

pub struct DynamicDnsSettings {
    /// A function that takes a hostname and returns a future that resolves to an IP address.
    resolver: Arc<dyn Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync>,
}

pub struct ClientCertificate {
    pub certificate: Vec<u8>,
    pub private_key: Vec<u8>,
}

pub enum TlsVersion {
    Tls1_2,
    Tls1_3,
}

impl Default for ClientSettings {
    fn default() -> Self {
        ClientSettings {
            cookie_settings: None,
            http_version_pref: HttpVersionPref::All,
            timeout_settings: None,
            throw_on_status_code: true,
            proxy_settings: None,
            redirect_settings: None,
            tls_settings: None,
            dns_settings: None,
            user_agent: None,
        }
    }
}

#[derive(Clone)]
pub struct RequestClient {
    pub(crate) client: reqwest::Client,
    pub(crate) http_version_pref: HttpVersionPref,
    pub(crate) throw_on_status_code: bool,

    /// A token that can be used to cancel all requests made by this client.
    pub(crate) cancel_token: CancellationToken,
}

impl RequestClient {
    pub(crate) fn new_default() -> Self {
        create_client(ClientSettings::default()).unwrap()
    }

    pub(crate) fn new(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
        create_client(settings)
    }
}

fn create_client(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    let client: reqwest::Client = {
        let mut client = reqwest::Client::builder();
        if let Some(proxy_settings) = settings.proxy_settings {
            match proxy_settings {
                ProxySettings::NoProxy => client = client.no_proxy(),
                ProxySettings::CustomProxyList(proxies) => {
                    for proxy in proxies {
                        let proxy = match proxy.condition {
                            ProxyCondition::Http => reqwest::Proxy::http(&proxy.url),
                            ProxyCondition::Https => reqwest::Proxy::https(&proxy.url),
                            ProxyCondition::All => reqwest::Proxy::all(&proxy.url),
                        }
                        .map_err(|e| {
                            RhttpError::RhttpUnknownError(format!("Error creating proxy: {e:?}"))
                        })?;
                        client = client.proxy(proxy);
                    }
                }
            }
        }

        if let Some(cookie_settings) = settings.cookie_settings {
            client = client.cookie_store(cookie_settings.store_cookies);
        }

        if let Some(redirect_settings) = settings.redirect_settings {
            client = match redirect_settings {
                RedirectSettings::NoRedirect => client.redirect(reqwest::redirect::Policy::none()),
                RedirectSettings::LimitedRedirects(max_redirects) => {
                    client.redirect(reqwest::redirect::Policy::limited(max_redirects as usize))
                }
            };
        }

        if let Some(timeout_settings) = settings.timeout_settings {
            if let Some(timeout) = timeout_settings.timeout {
                client = client.timeout(
                    timeout
                        .to_std()
                        .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
                );
            }
            if let Some(timeout) = timeout_settings.connect_timeout {
                client = client.connect_timeout(
                    timeout
                        .to_std()
                        .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
                );
            }

            if let Some(keep_alive_timeout) = timeout_settings.keep_alive_timeout {
                let timeout = keep_alive_timeout
                    .to_std()
                    .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;
                if timeout.as_millis() > 0 {
                    client = client.tcp_keepalive(timeout);
                    client = client.http2_keep_alive_while_idle(true);
                    client = client.http2_keep_alive_timeout(timeout);
                }
            }

            if let Some(keep_alive_ping) = timeout_settings.keep_alive_ping {
                client = client.http2_keep_alive_interval(
                    keep_alive_ping
                        .to_std()
                        .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
                );
            }
        }

        if let Some(tls_settings) = settings.tls_settings {
            if let Some(ech_config_list) = tls_settings.ech_config_list.as_ref() {
                client = client.tls_backend_preconfigured(build_ech_tls_config(
                    &tls_settings,
                    settings.http_version_pref,
                    ech_config_list,
                )?);
            } else {
                // Caller-supplied custom roots (PEM), always layered on top.
                let custom_certs = tls_settings
                    .trusted_root_certificates
                    .iter()
                    .map(|cert| {
                        Certificate::from_pem(cert).map_err(|e| {
                            RhttpError::RhttpUnknownError(format!(
                                "Error adding trusted certificate: {e:?}"
                            ))
                        })
                    })
                    .collect::<Result<Vec<Certificate>, RhttpError>>()?;

                match tls_settings.root_cert_source {
                    RootCertSource::Platform => {
                        // Add custom certs if not empty, otherwise, keep platform verifier as is
                        if !custom_certs.is_empty() {
                            client = client.tls_certs_merge(custom_certs);
                        }
                    }
                    RootCertSource::Webpki => {
                        let mut certs = custom_certs;
                        certs.extend(webpki_root_certs()?);
                        client = client.tls_certs_only(certs);
                    }
                    RootCertSource::None => {
                        client = client.tls_certs_only(custom_certs);
                    }
                }

                if !tls_settings.verify_certificates {
                    client = client.danger_accept_invalid_certs(true);
                }

                if let Some(client_certificate) = tls_settings.client_certificate {
                    let identity = &[
                        client_certificate.certificate.as_slice(),
                        "\n".as_bytes(),
                        client_certificate.private_key.as_slice(),
                    ]
                    .concat();

                    client = client.identity(
                        reqwest::Identity::from_pem(identity)
                            .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?,
                    );
                }

                if let Some(min_tls_version) = tls_settings.min_tls_version {
                    client = client.min_tls_version(match min_tls_version {
                        TlsVersion::Tls1_2 => tls::Version::TLS_1_2,
                        TlsVersion::Tls1_3 => tls::Version::TLS_1_3,
                    });
                }

                if let Some(max_tls_version) = tls_settings.max_tls_version {
                    client = client.max_tls_version(match max_tls_version {
                        TlsVersion::Tls1_2 => tls::Version::TLS_1_2,
                        TlsVersion::Tls1_3 => tls::Version::TLS_1_3,
                    });
                }

                client = client.tls_sni(tls_settings.sni);
            }
        } else {
            // No TLS settings supplied: respect the default root cert source (Webpki).
            client = client.tls_certs_only(webpki_root_certs()?);
        }

        client = match settings.http_version_pref {
            HttpVersionPref::Http10 | HttpVersionPref::Http11 => client.http1_only(),
            HttpVersionPref::Http2 => client.http2_prior_knowledge(),
            HttpVersionPref::Http3 => client.http3_prior_knowledge(),
            HttpVersionPref::All => client,
        };

        if let Some(dns_settings) = settings.dns_settings {
            match dns_settings {
                DnsSettings::StaticDns(settings) => {
                    if let Some(fallback) = settings.fallback {
                        client = client.dns_resolver(Arc::new(StaticResolver {
                            address: SocketAddr::from_str(fallback.digest_ip().as_str())
                                .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?,
                        }));
                    }

                    for dns_override in settings.overrides {
                        let (hostname, ip) = dns_override;
                        let hostname = hostname.as_str();
                        let mut err: Option<String> = None;
                        let ip = ip
                            .into_iter()
                            .map(|ip| {
                                let ip_digested = ip.digest_ip();
                                SocketAddr::from_str(ip_digested.as_str()).map_err(|e| {
                                    err = Some(format!("Invalid IP address: {ip_digested}. {e:?}"));
                                    RhttpError::RhttpUnknownError(e.to_string())
                                })
                            })
                            .filter_map(Result::ok)
                            .collect::<Vec<SocketAddr>>();

                        if let Some(error) = err {
                            return Err(RhttpError::RhttpUnknownError(error));
                        }

                        client = client.resolve_to_addrs(hostname, ip.as_slice());
                    }
                }
                DnsSettings::DynamicDns(settings) => {
                    client = client.dns_resolver(Arc::new(DynamicResolver {
                        resolver: settings.resolver,
                    }));
                }
            }
        }

        if let Some(user_agent) = settings.user_agent {
            client = client.user_agent(user_agent);
        }

        client
            .build()
            .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?
    };

    Ok(RequestClient {
        client,
        http_version_pref: settings.http_version_pref,
        throw_on_status_code: settings.throw_on_status_code,
        cancel_token: CancellationToken::new(),
    })
}

/// The webpki (Mozilla) root certificates bundled with the crate.
fn webpki_root_certs() -> Result<Vec<Certificate>, RhttpError> {
    webpki_root_certs::TLS_SERVER_ROOT_CERTS
        .iter()
        .map(|der| {
            Certificate::from_der(der.as_ref()).map_err(|e| {
                RhttpError::RhttpUnknownError(format!("Error adding webpki root: {e:?}"))
            })
        })
        .collect()
}

/// Builds a rustls client config with ECH (`EchMode::Enable`) from the
/// caller-supplied ECH config list bytes (as emitted by the `ech` SvcParam
/// of an HTTPS RR). This is the fork's single functional change.
///
/// Notes (mirroring the rustls behavior):
/// - ECH requires TLS 1.3 and SNI enabled; both are validated here.
/// - Certificate chain + hostname verification stays ON when
///   `verify_certificates` is true; ECH only encrypts the real SNI in the
///   ClientHello, it never disables verification.
/// - `RootCertSource::Platform` uses rustls-platform-verifier; Webpki uses
///   the bundled Mozilla roots.
fn build_ech_tls_config(
    tls_settings: &TlsSettings,
    http_version_pref: HttpVersionPref,
    ech_config_list: &[u8],
) -> Result<rustls::ClientConfig, RhttpError> {
    if !tls_settings.sni {
        return Err(RhttpError::RhttpUnknownError(
            "ECH requires SNI to be enabled".to_string(),
        ));
    }
    if matches!(tls_settings.max_tls_version, Some(TlsVersion::Tls1_2)) {
        return Err(RhttpError::RhttpUnknownError(
            "ECH requires TLS 1.3".to_string(),
        ));
    }

    let provider = rustls::crypto::CryptoProvider::get_default()
        .cloned()
        .unwrap_or_else(|| Arc::new(rustls::crypto::aws_lc_rs::default_provider()));

    // Diagnostics (visible in `flutter run` / logcat as `[rust]` lines are
    // not compiled into release; included in debug APKs only via cfg!). The
    // payload length + first bytes pin down Dart→Rust transfer corruption
    // (e.g. Uint8List vs List<int> widening) vs. a genuinely invalid config.
    if cfg!(debug_assertions) {
        let preview: Vec<String> = ech_config_list
            .iter()
            .take(8)
            .map(|b| format!("{b:02x}"))
            .collect();
        eprintln!(
            "[ech] config_list len={} first={}",
            ech_config_list.len(),
            preview.join(" ")
        );
    }

    let ech_config = rustls::client::EchConfig::new(
        rustls::pki_types::EchConfigListBytes::from(ech_config_list.to_vec()),
        rustls::crypto::aws_lc_rs::hpke::ALL_SUPPORTED_SUITES,
    )
    .map_err(|e| RhttpError::RhttpUnknownError(format!(
        "Invalid ECH config (len={}): {e:?}",
        ech_config_list.len()
    )))?;

    let builder = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_ech(rustls::client::EchMode::from(ech_config))
        .map_err(|e| RhttpError::RhttpUnknownError(format!("Invalid ECH setup: {e:?}")))?;

    let mut tls = if !tls_settings.verify_certificates {
        // Explicitly requested insecure mode: accept any certificate. Only
        // reachable through the Dart-side `insecureNoSni` tier gate.
        builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerifier))
            .with_no_client_auth()
    } else {
        let verifier_builder = match tls_settings.root_cert_source {
            RootCertSource::Webpki => builder.with_root_certificates(build_root_store(
                true,
                &tls_settings.trusted_root_certificates,
            )?),
            RootCertSource::None => builder.with_root_certificates(build_root_store(
                false,
                &tls_settings.trusted_root_certificates,
            )?),
            RootCertSource::Platform => {
                let verifier = rustls_platform_verifier::Verifier::new(provider.clone())
                    .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?;
                builder.dangerous().with_custom_certificate_verifier(Arc::new(verifier))
            }
        };

        if let Some(client_certificate) = tls_settings.client_certificate.as_ref() {
            let cert_chain = collect_pem_certificates(&client_certificate.certificate)?;
            let private_key = parse_private_key(&client_certificate.private_key)?;
            verifier_builder
                .with_client_auth_cert(cert_chain, private_key)
                .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?
        } else {
            verifier_builder.with_no_client_auth()
        }
    };

    tls.enable_sni = true;
    tls.alpn_protocols = match http_version_pref {
        HttpVersionPref::Http10 | HttpVersionPref::Http11 => vec!["http/1.1".into()],
        HttpVersionPref::Http2 => vec!["h2".into()],
        HttpVersionPref::Http3 => Vec::new(),
        HttpVersionPref::All => vec!["h2".into(), "http/1.1".into()],
    };

    Ok(tls)
}

/// Builds a [`rustls::RootCertStore`], optionally seeded with the bundled
/// webpki roots, then augmented with the caller-supplied PEM roots.
fn build_root_store(
    include_webpki: bool,
    trusted_root_certificates: &[Vec<u8>],
) -> Result<rustls::RootCertStore, RhttpError> {
    let mut root_store = rustls::RootCertStore::empty();

    if include_webpki {
        for cert in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
            root_store
                .add(cert.clone())
                .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?;
        }
    }

    for cert in collect_pem_certificates_many(trusted_root_certificates)? {
        root_store
            .add(cert)
            .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?;
    }
    Ok(root_store)
}

/// Parses PEM certificate bundles into DER certificates.
fn collect_pem_certificates_many(
    bundles: &[Vec<u8>],
) -> Result<Vec<rustls::pki_types::CertificateDer<'static>>, RhttpError> {
    let mut certificates = Vec::new();
    for bundle in bundles {
        certificates.extend(collect_pem_certificates(bundle)?);
    }
    Ok(certificates)
}

fn collect_pem_certificates(
    certificate_pem: &[u8],
) -> Result<Vec<rustls::pki_types::CertificateDer<'static>>, RhttpError> {
    use rustls::pki_types::pem::PemObject;
    let certificates = rustls::pki_types::CertificateDer::pem_slice_iter(certificate_pem)
        .map(|result| {
            result
                .map(|cert| cert.into_owned())
                .map_err(|_| RhttpError::RhttpUnknownError("Invalid PEM certificate".to_string()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(certificates)
}

fn parse_private_key(
    private_key: &[u8],
) -> Result<rustls::pki_types::PrivateKeyDer<'static>, RhttpError> {
    use rustls::pki_types::pem::PemObject;
    rustls::pki_types::PrivateKeyDer::from_pem_slice(private_key)
        .or_else(|_| {
            rustls::pki_types::PrivateKeyDer::try_from(private_key)
                .map(|key| key.clone_key())
                .map_err(|_| "Invalid private key".to_string())
        })
        .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))
}

/// A certificate verifier that accepts everything. Used ONLY when the caller
/// explicitly sets `verify_certificates = false` (the `insecureNoSni`
/// fallback tier). Never enabled by default.
#[derive(Debug)]
struct NoVerifier;

impl rustls::client::danger::ServerCertVerifier for NoVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _certificate: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _certificate: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![]
    }
}

struct StaticResolver {
    address: SocketAddr,
}

impl Resolve for StaticResolver {
    fn resolve(&self, _: Name) -> Resolving {
        let addrs: Addrs = Box::new(vec![self.address].clone().into_iter());
        Box::pin(futures_util::future::ready(Ok(addrs)))
    }
}

struct DynamicResolver {
    resolver: Arc<dyn Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync>,
}

impl Resolve for DynamicResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let resolver = self.resolver.clone();
        Box::pin(async move {
            let ip = resolver(name.as_str().to_owned()).await;
            let ip = ip
                .into_iter()
                .map(|ip| {
                    let ip_digested = ip.digest_ip();
                    SocketAddr::from_str(ip_digested.as_str()).map_err(|e| {
                        RhttpError::RhttpUnknownError(format!(
                            "Invalid IP address: {ip_digested}. {e:?}"
                        ))
                    })
                })
                .filter_map(Result::ok)
                .collect::<Vec<SocketAddr>>();

            let addrs: Addrs = Box::new(ip.into_iter());

            Ok(addrs)
        })
    }
}

#[frb(sync)]
pub fn create_static_resolver_sync(settings: StaticDnsSettings) -> DnsSettings {
    DnsSettings::StaticDns(settings)
}

#[frb(sync)]
pub fn create_dynamic_resolver_sync(
    resolver: impl Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync,
) -> DnsSettings {
    DnsSettings::DynamicDns(DynamicDnsSettings {
        resolver: Arc::new(resolver),
    })
}
