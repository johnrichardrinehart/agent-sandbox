use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;

const HEALTH_RESPONSE: &[u8] =
    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}";
const NOT_FOUND_RESPONSE: &[u8] =
    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

fn response_for(request_line: &str) -> &'static [u8] {
    if request_line == "GET /healthz HTTP/1.1" {
        HEALTH_RESPONSE
    } else {
        NOT_FOUND_RESPONSE
    }
}

fn handle_connection(mut stream: TcpStream) -> io::Result<()> {
    let mut request_line = String::new();
    BufReader::new(stream.try_clone()?).read_line(&mut request_line)?;
    stream.write_all(response_for(request_line.trim_end()))?;
    stream.flush()
}

fn main() -> io::Result<()> {
    let address = env::var("AGENT_SANDBOX_LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let listener = TcpListener::bind(&address)?;
    eprintln!("agent-sandbox listening on {address}");

    for connection in listener.incoming() {
        match connection {
            Ok(stream) => {
                thread::spawn(move || {
                    if let Err(error) = handle_connection(stream) {
                        eprintln!("request failed: {error}");
                    }
                });
            }
            Err(error) => eprintln!("connection failed: {error}"),
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{HEALTH_RESPONSE, NOT_FOUND_RESPONSE, response_for};

    #[test]
    fn health_endpoint_is_available() {
        assert_eq!(response_for("GET /healthz HTTP/1.1"), HEALTH_RESPONSE);
    }

    #[test]
    fn unknown_endpoint_is_not_found() {
        assert_eq!(response_for("GET /missing HTTP/1.1"), NOT_FOUND_RESPONSE);
    }
}
