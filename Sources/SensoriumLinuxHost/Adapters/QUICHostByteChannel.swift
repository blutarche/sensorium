#if os(Linux)
import SensoriumHost

/// A viewer's QUIC stream is the byte channel a shared host session runs on,
/// exactly as the macOS host's Network.framework connection is.
extension OpenSSLQUICServerChannel: HostByteChannel {}
#endif
