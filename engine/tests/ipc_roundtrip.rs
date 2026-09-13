//! Drives the real IPC server over a loopback socket. Exercises the transport, envelope framing,
//! versioning, and dispatch — without requiring Ollama (Health reports engine liveness; the LLM
//! runtime status is informational).

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

use notely_engine::config::Config;
use notely_engine::ipc::protocol::{
    Request, RequestEnvelope, RequestId, Response, ResponseEnvelope, PROTOCOL_VERSION,
};
use notely_engine::ipc::Server;
use notely_engine::Engine;

fn test_config() -> Config {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    Config {
        data_dir: std::env::temp_dir().join(format!("notely-ipc-test-{nanos}")),
        ..Default::default()
    }
}

async fn send_request(stream: &mut TcpStream, request: Request) -> ResponseEnvelope {
    let env = RequestEnvelope {
        protocol_version: PROTOCOL_VERSION,
        request_id: RequestId("req-1".into()),
        request,
    };
    let mut line = serde_json::to_string(&env).unwrap();
    line.push('\n');
    stream.write_all(line.as_bytes()).await.unwrap();

    let mut reader = BufReader::new(stream);
    let mut resp_line = String::new();
    reader.read_line(&mut resp_line).await.unwrap();
    serde_json::from_str(&resp_line).unwrap()
}

#[tokio::test]
async fn health_and_error_paths_over_the_socket() {
    let engine = Arc::new(Engine::new(test_config()).expect("engine builds"));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let server = Server::new(engine);
    let handle = tokio::spawn(async move {
        server
            .serve(listener, async {
                let _ = shutdown_rx.await;
            })
            .await
            .unwrap();
    });

    // Health: engine is up; response is well-formed and version-tagged.
    let mut stream = TcpStream::connect(addr).await.unwrap();
    let resp = send_request(&mut stream, Request::Health).await;
    assert_eq!(resp.protocol_version, PROTOCOL_VERSION);
    assert_eq!(resp.request_id, RequestId("req-1".into()));
    match resp.response {
        Response::Health(info) => {
            assert!(info.engine_ok);
            assert_eq!(info.protocol_version, PROTOCOL_VERSION);
        }
        other => panic!("expected Health, got {other:?}"),
    }

    // Unknown meeting: a clean error, not a hang or crash.
    let resp = send_request(
        &mut stream,
        Request::GetMeeting {
            meeting_id: notely_engine::domain::MeetingId("nope".into()),
        },
    )
    .await;
    assert!(matches!(resp.response, Response::Error { .. }));

    // Search: the new v2 request/response serializes across the wire. An empty vault path yields
    // an empty result set (not an error), proving the variant round-trips end to end.
    let resp = send_request(
        &mut stream,
        Request::Search {
            query: "anything".into(),
            vault_path: std::env::temp_dir()
                .join("notely-does-not-exist")
                .to_string_lossy()
                .to_string(),
            limit: Some(5),
        },
    )
    .await;
    match resp.response {
        Response::SearchResults(hits) => assert!(hits.is_empty()),
        other => panic!("expected SearchResults, got {other:?}"),
    }

    shutdown_tx.send(()).ok();
    handle.await.unwrap();
}
