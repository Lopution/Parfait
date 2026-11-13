use flutter_rust_bridge::for_generated::anyhow;
use flutter_rust_bridge::{frb, DartFnFuture};
use futures_util::StreamExt;
use reqwest::header::{HeaderName, HeaderValue};
use reqwest::{Method, Response, Url, Version};
use std::collections::HashMap;
use std::error::Error;
use std::str::FromStr;
use tokio_util::sync::CancellationToken;

use crate::api::client::{ClientSettings, RequestClient};
use crate::api::error::RhttpError;
use crate::api::{error, stream};
use crate::frb_generated::{RustAutoOpaque, StreamSink};

pub struct HttpMethod {
    pub method: String,
}

impl HttpMethod {
    fn to_method(&self) -> Method {
        Method::from_bytes(self.method.as_bytes()).unwrap()
    }
}

pub enum HttpHeaders {
    Map(HashMap<String, String>),
    List(Vec<(String, String)>),
}

pub enum HttpBody {
    Text(String),
    Bytes(Vec<u8>),
    BytesStream,
    Form(HashMap<String, String>),
    Multipart(MultipartPayload),
}

pub struct MultipartPayload {
    pub parts: Vec<(String, MultipartItem)>,
    // https://github.com/seanmonstar/reqwest/issues/2374
    // pub boundary: Option<String>,
}

pub struct MultipartItem {
    pub value: MultipartValue,
    pub file_name: Option<String>,
    pub content_type: Option<String>,
}

pub enum MultipartValue {
    Text(String),
    Bytes(Vec<u8>),
    File(String),
}

#[derive(Clone, Copy)]
pub enum HttpVersionPref {
    Http10,
    Http11,
    Http2,
    Http3,
    All,
}

#[derive(Clone, Copy)]
pub enum HttpExpectBody {
    Text,
    Bytes,
}

pub enum HttpVersion {
    Http09,
    Http10,
    Http11,
    Http2,
    Http3,
    Other,
}

impl HttpVersion {
    fn from_version(version: Version) -> HttpVersion {
        match version {
            Version::HTTP_09 => HttpVersion::Http09,
            Version::HTTP_10 => HttpVersion::Http10,
            Version::HTTP_11 => HttpVersion::Http11,
            Version::HTTP_2 => HttpVersion::Http2,
            Version::HTTP_3 => HttpVersion::Http3,
            _ => HttpVersion::Other,
        }
    }
}

pub struct HttpResponse {
    pub remote_ip: Option<String>,
    pub headers: Vec<(String, String)>,
    pub version: HttpVersion,
    pub status_code: u16,
    pub body: HttpResponseBody,
}

#[derive(Clone, Debug)]
pub enum HttpResponseBody {
    Text(String),
    Bytes(Vec<u8>),
    Stream,
}

// It must be async so that frb provides an async context.
pub async fn register_client(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    register_client_internal(settings)
}

#[frb(sync)]
pub fn register_client_sync(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    register_client_internal(settings)
}

fn register_client_internal(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    let client = RequestClient::new(settings)?;
    Ok(client)
}

pub fn cancel_running_requests(client: &RequestClient) {
    client.cancel_token.cancel();
}

pub async fn make_http_request(
    client: Option<RustAutoOpaque<RequestClient>>,
    settings: Option<ClientSettings>,
    method: HttpMethod,
    url: String,
    query: Option<Vec<(String, String)>>,
    headers: Option<HttpHeaders>,
    body: Option<HttpBody>,
    body_stream: Option<stream::Dart2RustStreamReceiver>,
    expect_body: HttpExpectBody,
    on_cancel_token: impl Fn(CancellationToken) -> DartFnFuture<()>,
    cancelable: bool,
) -> Result<HttpResponse, RhttpError> {
    let cancel_tokens = build_cancel_tokens(client.clone());

    if cancelable {
        on_cancel_token(cancel_tokens.request_cancel_token.clone()).await;
    }

    tokio::select! {
        _ = cancel_tokens.request_cancel_token.cancelled() => Err(RhttpError::RhttpCancelError),
        _ = cancel_tokens.client_cancel_token.cancelled() => Err(RhttpError::RhttpCancelError),
        response = make_http_request_inner(
            client,
            settings,
            method,
            url.to_owned(),
            query,
            headers,
            body,
            body_stream,
            expect_body,
        ) => response,
    }
}

struct RequestCancelTokens {
    request_cancel_token: CancellationToken,
    client_cancel_token: CancellationToken,
}

fn build_cancel_tokens(client: Option<RustAutoOpaque<RequestClient>>) -> RequestCancelTokens {
    let client_cancel_token = match client {
        Some(client) => Some(client.try_read().unwrap().cancel_token.clone()),
        None => None,
    }
    .unwrap_or_else(|| CancellationToken::new());

    RequestCancelTokens {
        request_cancel_token: CancellationToken::new(),
        client_cancel_token,
    }
}

async fn make_http_request_inner(
    client: Option<RustAutoOpaque<RequestClient>>,
    settings: Option<ClientSettings>,
    method: HttpMethod,
    url: String,
    query: Option<Vec<(String, String)>>,
    headers: Option<HttpHeaders>,
    body: Option<HttpBody>,
    body_stream: Option<stream::Dart2RustStreamReceiver>,
    expect_body: HttpExpectBody,
) -> Result<HttpResponse, RhttpError> {
    let response = make_http_request_helper(
        client,
        settings,
        method,
        url,
        query,
        headers,
        body,
        body_stream,
        Some(expect_body),
    )
    .await?;

    Ok(HttpResponse {
        remote_ip: extract_ip(&response),
        headers: header_to_vec(response.headers()),
        version: HttpVersion::from_version(response.version()),
        status_code: response.status().as_u16(),
        body: match expect_body {
            HttpExpectBody::Text => HttpResponseBody::Text(
                response
                    .text()
                    .await
                    .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
            ),
            HttpExpectBody::Bytes => HttpResponseBody::Bytes(
                response
                    .bytes()
                    .await
                    .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?
                    .to_vec(),
            ),
        },
    })
}

pub async fn make_http_request_receive_stream(
    client: Option<RustAutoOpaque<RequestClient>>,
    settings: Option<ClientSettings>,
    method: HttpMethod,
    url: String,
    query: Option<Vec<(String, String)>>,
    headers: Option<HttpHeaders>,
    body: Option<HttpBody>,
    body_stream: Option<stream::Dart2RustStreamReceiver>,
    stream_sink: StreamSink<Vec<u8>>,
    on_response: impl Fn(HttpResponse) -> DartFnFuture<()>,
    on_error: impl Fn(RhttpError) -> DartFnFuture<()>,
    on_cancel_token: impl Fn(CancellationToken) -> DartFnFuture<()>,
    cancelable: bool,
) {
    let cancel_tokens = build_cancel_tokens(client.clone());

    if cancelable {
        on_cancel_token(cancel_tokens.request_cancel_token.clone()).await;
    }

    tokio::select! {
        _ = cancel_tokens.request_cancel_token.cancelled() => {
            let _ = stream_sink.add_error(anyhow::anyhow!(error::STREAM_CANCEL_ERROR));
            on_error(RhttpError::RhttpCancelError).await;
        },
        _ = cancel_tokens.client_cancel_token.cancelled() => {
            let _ = stream_sink.add_error(anyhow::anyhow!(error::STREAM_CANCEL_ERROR));
            on_error(RhttpError::RhttpCancelError).await;
        },
        _ = make_http_request_receive_stream_inner(
            client,
            settings,
            method,
            url.to_owned(),
            query,
            headers,
            body,
            body_stream,
            stream_sink.clone(),
            on_response,
            &on_error,
        ) => {},
    }
}

async fn make_http_request_receive_stream_inner(
    client: Option<RustAutoOpaque<RequestClient>>,
    settings: Option<ClientSettings>,
    method: HttpMethod,
    url: String,
    query: Option<Vec<(String, String)>>,
    headers: Option<HttpHeaders>,
    body: Option<HttpBody>,
    body_stream: Option<stream::Dart2RustStreamReceiver>,
    stream_sink: StreamSink<Vec<u8>>,
    on_response: impl Fn(HttpResponse) -> DartFnFuture<()>,
    on_error: &impl Fn(RhttpError) -> DartFnFuture<()>,
) {
    let response = make_http_request_helper(
        client,
        settings,
        method,
        url,
        query,
        headers,
        body,
        body_stream,
        None,
    )
    .await;

    let response: Response = match response {
        Ok(res) => res,
        Err(e) => {
            on_error(e.clone()).await;
            return;
        }
    };

    let http_response = HttpResponse {
        remote_ip: extract_ip(&response),
        headers: header_to_vec(response.headers()),
        version: HttpVersion::from_version(response.version()),
        status_code: response.status().as_u16(),
        body: HttpResponseBody::Stream,
    };

    on_response(http_response).await;

    let mut stream = response.bytes_stream();

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.inspect_err(|e| {
            let _ = stream_sink.add_error(anyhow::anyhow!(e.to_string()));
        });

        if chunk.is_err() {
            return;
        }

        let result = stream_sink.add(chunk.unwrap().to_vec()).inspect_err(|e| {
            let _ = stream_sink.add_error(anyhow::anyhow!(e.to_string()));
        });

        if result.is_err() {
            return;
        }
    }
}

/// This function is used to make an HTTP request without any response handling.
async fn make_http_request_helper(
    client: Option<RustAutoOpaque<RequestClient>>,
    settings: Option<ClientSettings>,
    method: HttpMethod,
    url: String,
    query: Option<Vec<(String, String)>>,
    headers: Option<HttpHeaders>,
    body: Option<HttpBody>,
    body_stream: Option<stream::Dart2RustStreamReceiver>,
    expect_body: Option<HttpExpectBody>,
) -> Result<Response, RhttpError> {
    let client: RequestClient = match client {
        Some(client) => client.try_read().unwrap().clone(),
        None => match settings {
            Some(settings) => RequestClient::new(settings)
                .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
            None => RequestClient::new_default(),
        },
    };

    let request = {
        let mut request = client.client.request(
            method.to_method(),
            Url::parse(&url).map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
        );

        request = match client.http_version_pref {
            HttpVersionPref::Http10 => request.version(Version::HTTP_10),
            HttpVersionPref::Http11 => request.version(Version::HTTP_11),
            HttpVersionPref::Http2 => request.version(Version::HTTP_2),
            HttpVersionPref::Http3 => request.version(Version::HTTP_3),
            HttpVersionPref::All => request,
        };

        if let Some(query) = query {
            request = request.query(&query);
        }

        match headers {
            Some(HttpHeaders::Map(map)) => {
                for (k, v) in map {
                    let header_name = HeaderName::from_str(&k)
                        .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;
                    let header_value = HeaderValue::from_str(&v)
                        .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;
                    request = request.header(header_name, header_value);
                }
            }
            Some(HttpHeaders::List(list)) => {
                for (k, v) in list {
                    let header_name = HeaderName::from_str(&k)
                        .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;
                    let header_value = HeaderValue::from_str(&v)
                        .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;
                    request = request.header(header_name, header_value);
                }
            }
            None => (),
        };

        request = match body {
            Some(HttpBody::Text(text)) => request.body(text),
            Some(HttpBody::Bytes(bytes)) => request.body(bytes),
            Some(HttpBody::BytesStream) => {
                let stream = body_stream
                    .expect("body_stream should exist for HttpBody::BytesStream")
                    .receiver
                    .map(|v| Ok::<Vec<u8>, RhttpError>(v));

                let body = reqwest::Body::wrap_stream(stream);
                request.body(body)
            }
            Some(HttpBody::Form(_)) => {
                return Err(RhttpError::RhttpUnknownError(
                    "form body is not supported".to_string(),
                ));
            }
            Some(HttpBody::Multipart(_)) => {
                return Err(RhttpError::RhttpUnknownError(
                    "multipart body is not supported".to_string(),
                ));
            }
            None => request,
        };

        request
            .build()
            .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?
    };

    let response = client
        .client
        .execute(request)
        .await
        .map_err(|e| map_reqwest_error(&e))?;

    if client.throw_on_status_code {
        let status = response.status();
        if status.is_client_error() || status.is_server_error() {
            return Err(RhttpError::RhttpStatusCodeError(
                response.status().as_u16(),
                header_to_vec(response.headers()),
                match expect_body {
                    Some(HttpExpectBody::Text) => HttpResponseBody::Text(
                        response
                            .text()
                            .await
                            .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
                    ),
                    Some(HttpExpectBody::Bytes) => HttpResponseBody::Bytes(
                        response
                            .bytes()
                            .await
                            .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?
                            .to_vec(),
                    ),
                    _ => HttpResponseBody::Stream,
                },
            ));
        }
    }

    Ok(response)
}

fn header_to_vec(headers: &reqwest::header::HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .filter_map(|(k, v)| match v.to_str() {
            Ok(v_str) => Some((k.as_str().to_string(), v_str.to_string())),
            Err(_) => None,
        })
        .collect()
}

pub fn cancel_request(token: &CancellationToken) {
    token.cancel();
}

fn extract_ip(response: &Response) -> Option<String> {
    response.remote_addr().map(|addr| addr.ip().to_string())
}

/// Walks the error source chain (including `std::io::Error` custom payloads)
/// to match typed `rustls` certificate verification failures rather than
/// relying on `Debug` formatting substrings.
fn is_cert_error(err: &(dyn Error + 'static)) -> bool {
    let mut current: Option<&(dyn Error + 'static)> = Some(err);
    while let Some(node) = current {
        if let Some(tls_err) = node.downcast_ref::<rustls::Error>() {
            if matches!(
                tls_err,
                rustls::Error::InvalidCertificate(_)
                    | rustls::Error::NoCertificatesPresented
                    | rustls::Error::InvalidCertRevocationList(_)
            ) {
                return true;
            }
        }
        if let Some(io_err) = node.downcast_ref::<std::io::Error>() {
            if let Some(inner) = io_err.get_ref() {
                if is_cert_error(inner) {
                    return true;
                }
            }
        }
        current = node.source();
    }
    false
}

fn map_reqwest_error(err: &reqwest::Error) -> RhttpError {
    if err.is_redirect() {
        return RhttpError::RhttpRedirectError;
    }
    if err.is_timeout() {
        return RhttpError::RhttpTimeoutError;
    }
    // Format `source()` when present because it preserves the underlying TLS or
    // transport cause rather than reqwest's generic send-error wrapper.
    let inner = err.source();
    let detail = match inner {
        Some(inner) => format!("{inner:?}"),
        None => format!("{err:?}"),
    };
    if is_cert_error(err) {
        RhttpError::RhttpInvalidCertificateError(detail)
    } else if err.is_connect() {
        RhttpError::RhttpConnectionError(detail)
    } else {
        RhttpError::RhttpUnknownError(detail)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::pki_types::CertificateDer;
    use rustls::sign::{CertifiedKey, SingleCertAndKey};
    use rustls::{
        CertRevocationListError, CertificateError, ClientConfig, Error as TlsError, OtherError,
        RootCertStore, ServerConfig, ServerConnection, SignatureAlgorithm, SignatureScheme,
    };
    use std::fmt;
    use std::io;
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::time::Duration;

    #[derive(Debug)]
    struct WrappedError {
        label: &'static str,
        source: Box<dyn Error + Send + Sync>,
    }

    impl fmt::Display for WrappedError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "{}", self.label)
        }
    }

    impl Error for WrappedError {
        fn source(&self) -> Option<&(dyn Error + 'static)> {
            Some(&*self.source)
        }
    }

    #[derive(Debug)]
    struct OpaqueMessageError(&'static str);

    impl fmt::Display for OpaqueMessageError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(self.0)
        }
    }

    impl Error for OpaqueMessageError {}

    #[derive(Debug)]
    struct DummySigner(SignatureScheme);

    impl rustls::sign::Signer for DummySigner {
        fn sign(&self, _message: &[u8]) -> Result<Vec<u8>, TlsError> {
            Ok(vec![0; 64])
        }

        fn scheme(&self) -> SignatureScheme {
            self.0
        }
    }

    #[derive(Debug)]
    struct DummySigningKey;

    impl rustls::sign::SigningKey for DummySigningKey {
        fn choose_scheme(
            &self,
            offered: &[SignatureScheme],
        ) -> Option<Box<dyn rustls::sign::Signer>> {
            offered
                .iter()
                .copied()
                .find(|s| {
                    matches!(
                        s,
                        SignatureScheme::ECDSA_NISTP256_SHA256
                            | SignatureScheme::ECDSA_NISTP384_SHA384
                    )
                })
                .or_else(|| offered.first().copied())
                .map(|s| Box::new(DummySigner(s)) as Box<dyn rustls::sign::Signer>)
        }

        fn algorithm(&self) -> SignatureAlgorithm {
            SignatureAlgorithm::ECDSA
        }
    }

    #[test]
    fn recognizes_rustls_certificate_variants_through_nested_sources() {
        let cases = [
            TlsError::InvalidCertificate(CertificateError::UnknownIssuer),
            TlsError::InvalidCertificate(CertificateError::NotValidForName),
            TlsError::InvalidCertificate(CertificateError::Expired),
            TlsError::InvalidCertificate(CertificateError::Revoked),
            TlsError::InvalidCertificate(CertificateError::InvalidPurpose),
            TlsError::InvalidCertificate(CertificateError::BadSignature),
            TlsError::InvalidCertificate(CertificateError::Other(OtherError(Arc::new(
                OpaqueMessageError("verifier rejected cert"),
            )))),
            TlsError::NoCertificatesPresented,
            TlsError::InvalidCertRevocationList(CertRevocationListError::BadSignature),
        ];

        for tls_err in cases {
            let io_wrapped = io::Error::new(io::ErrorKind::InvalidData, tls_err.clone());
            let outer = WrappedError {
                label: "tls connect failed",
                source: Box::new(io_wrapped),
            };
            assert!(
                is_cert_error(&outer),
                "expected cert error classification for {tls_err:?}"
            );
        }
    }

    #[test]
    fn rejects_non_certificate_errors_and_spoofed_debug_text() {
        let spoofed_text = WrappedError {
            label: "custom proxy failure",
            source: Box::new(io::Error::other(OpaqueMessageError(
                "InvalidCertificate literal in plain message",
            ))),
        };
        assert!(
            !is_cert_error(&spoofed_text),
            "plain non-rustls error text must not trigger cert error classification"
        );

        let non_cert_tls_errors = [
            TlsError::DecryptError,
            TlsError::InappropriateHandshakeMessage {
                expect_types: vec![],
                got_type: rustls::HandshakeType::Finished,
            },
            TlsError::InvalidMessage(rustls::InvalidMessage::InvalidContentType),
        ];
        for tls_err in non_cert_tls_errors {
            let io_wrapped = io::Error::new(io::ErrorKind::InvalidData, tls_err.clone());
            assert!(
                !is_cert_error(&io_wrapped),
                "non-certificate rustls error must not match: {tls_err:?}"
            );
        }

        let plain_reset = io::Error::new(io::ErrorKind::ConnectionReset, "connection reset");
        assert!(!is_cert_error(&plain_reset));
    }

    #[tokio::test]
    async fn reqwest_tls_untrusted_cert_maps_to_invalid_certificate_error() {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let public_der = CertificateDer::from(
            webpki_root_certs::TLS_SERVER_ROOT_CERTS[0]
                .as_ref()
                .to_vec(),
        );
        let certified_key = CertifiedKey::new(vec![public_der], Arc::new(DummySigningKey));
        let server_cfg = Arc::new(
            ServerConfig::builder_with_provider(provider.clone())
                .with_safe_default_protocol_versions()
                .expect("default protocol versions")
                .with_no_client_auth()
                .with_cert_resolver(Arc::new(SingleCertAndKey::from(certified_key))),
        );

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let addr = listener.local_addr().expect("local addr");
        let server_handle = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                if let Ok(mut conn) = ServerConnection::new(server_cfg) {
                    let _ = conn.complete_io(&mut stream);
                }
            }
        });

        let client_tls = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("client protocol versions")
            .with_root_certificates(RootCertStore::empty())
            .with_no_client_auth();
        let client = reqwest::Client::builder()
            .tls_backend_preconfigured(client_tls)
            .timeout(Duration::from_secs(5))
            .build()
            .expect("build reqwest client");

        let err = client
            .get(format!("https://{addr}/"))
            .send()
            .await
            .expect_err("untrusted loopback TLS server must fail handshake");
        let _ = server_handle.join();

        assert!(
            matches!(
                map_reqwest_error(&err),
                RhttpError::RhttpInvalidCertificateError(_)
            ),
            "expected RhttpInvalidCertificateError, got {:?}",
            map_reqwest_error(&err)
        );
    }

    #[tokio::test]
    async fn reqwest_tcp_connection_refused_maps_to_connection_error() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        let addr = listener.local_addr().expect("local addr");
        drop(listener);

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("build reqwest client");

        let err = client
            .get(format!("http://{addr}/"))
            .send()
            .await
            .expect_err("closed loopback port must fail to connect");

        assert!(
            matches!(map_reqwest_error(&err), RhttpError::RhttpConnectionError(_)),
            "expected RhttpConnectionError, got {:?}",
            map_reqwest_error(&err)
        );
    }
}
